/// Moteur de paroles synchronisées et karaoké mot-à-mot (inspiré d'Onde et Aura) :
/// 1. Sous-titres synchronisés YouTube (.srt / .vtt) et fichiers .lrc locaux attachés au titre ;
/// 2. Recherche automatique multi-sources en ligne : LRCLIB + NetEase Cloud Music (YRC / KRC mot-à-mot) ;
/// 3. Nettoyage intelligent des titres YouTube (clips, VEVO, feat., parenthèses) et notation par durée ;
/// 4. Découpage syllabique/phonétique de secours quand seuls les temps de début/fin de phrase sont connus ;
/// 5. Cache JSON persistant par morceau, calage temporel fin (offset) et recherche manuelle interactive.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:video_player/video_player.dart' show SubRipCaptionFile, WebVTTCaptionFile, ClosedCaptionFile;

import 'analyse.dart' as analyse;
import 'langues.dart' as langues;
import 'natif.dart';
import 'taches.dart';

/// Un mot (ou fragment) horodaté à l'intérieur d'une ligne de paroles.
class MotParole {
  final Duration debut;
  final Duration fin;
  final String texte;

  const MotParole({
    required this.debut,
    required this.fin,
    required this.texte,
  });

  Map<String, dynamic> versJson() => {
        'd': debut.inMilliseconds,
        'f': fin.inMilliseconds,
        't': texte,
      };

  factory MotParole.depuisJson(Map m) => MotParole(
        debut: Duration(milliseconds: (m['d'] as num?)?.toInt() ?? 0),
        fin: Duration(milliseconds: (m['f'] as num?)?.toInt() ?? 0),
        texte: (m['t'] as String?) ?? '',
      );
}

/// Une ligne de paroles (synchronisée ou non), avec ses mots horodatés pour le karaoké.
class LigneParole {
  final Duration debut;
  final Duration fin;
  final String texte;
  final List<MotParole> mots;
  final bool estPause;

  const LigneParole(
    this.debut,
    this.fin,
    this.texte, {
    this.mots = const [],
    this.estPause = false,
  });

  Map<String, dynamic> versJson() => {
        'd': debut.inMilliseconds,
        'f': fin.inMilliseconds,
        't': texte,
        if (mots.isNotEmpty) 'm': [for (final m in mots) m.versJson()],
        if (estPause) 'p': true,
      };

  factory LigneParole.depuisJson(Map m) => LigneParole(
        Duration(milliseconds: (m['d'] as num?)?.toInt() ?? 0),
        Duration(milliseconds: (m['f'] as num?)?.toInt() ?? 0),
        (m['t'] as String?) ?? '',
        mots: [
          for (final x in (m['m'] as List?) ?? const [])
            if (x is Map) MotParole.depuisJson(x),
        ],
        estPause: m['p'] == true,
      );
}

/// Résultat complet de paroles pour un morceau.
class DonneesParoles {
  final String source; // ex. "Sous-titres YouTube (FR)", "NetEase · Mot-à-mot", "LRCLIB"
  final String idSource; // ex. "srt:0", "netease:123", "lrclib:456"
  final List<LigneParole> lignes;
  final String texteBrut;
  final bool synchro;
  final bool motAMot; // vrai si les repères mot-à-mot proviennent de la source (YRC/KRC/LRC enrichi)
  final bool instrumental;
  final bool approximatif;

  const DonneesParoles({
    required this.source,
    this.idSource = '',
    this.lignes = const [],
    this.texteBrut = '',
    this.synchro = false,
    this.motAMot = false,
    this.instrumental = false,
    this.approximatif = false,
  });

  bool get vide => lignes.isEmpty && texteBrut.trim().isEmpty && !instrumental;

  Map<String, dynamic> versJson() => {
        'version': 2,
        'source': source,
        'id_source': idSource,
        'lignes': [for (final l in lignes) l.versJson()],
        'texte': texteBrut,
        'synchro': synchro,
        'mot_a_mot': motAMot,
        'instrumental': instrumental,
        'approximatif': approximatif,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };

  factory DonneesParoles.depuisJson(Map d) => DonneesParoles(
        source: (d['source'] as String?) ?? 'Cache',
        idSource: (d['id_source'] as String?) ?? '',
        lignes: [
          for (final l in (d['lignes'] as List?) ?? const [])
            if (l is Map) LigneParole.depuisJson(l),
        ],
        texteBrut: (d['texte'] as String?) ?? '',
        synchro: d['synchro'] == true,
        motAMot: d['mot_a_mot'] == true,
        instrumental: d['instrumental'] == true,
        approximatif: d['approximatif'] == true,
      );
}

/// Candidat trouvé lors d'une recherche manuelle sur LRCLIB / NetEase.
class CandidatParoles {
  final String id; // "lrclib:123" ou "netease:456"
  final String source; // "LRCLIB" ou "NetEase"
  final String titre;
  final String artiste;
  final String album;
  final double duree;
  final bool synchro;
  final bool motAMot;
  final bool instrumental;
  final String extrait;
  final String? syncedLyrics;
  final String? plainLyrics;

  const CandidatParoles({
    required this.id,
    required this.source,
    required this.titre,
    required this.artiste,
    this.album = '',
    this.duree = 0,
    this.synchro = false,
    this.motAMot = false,
    this.instrumental = false,
    this.extrait = '',
    this.syncedLyrics,
    this.plainLyrics,
  });
}

// ── Expressions régulières (identiques à Onde) ──────────────────────────

final _regLigneLrc = RegExp(r'^\s*((?:\[\d{1,3}:\d{1,2}(?:[.:,]\d{1,3})?\])+)(.*)$');
final _regStamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:,](\d{1,3}))?\]');
final _regMot = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:,](\d{1,3}))?>');
final _regOffset = RegExp(r'\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);
final _regCredits = RegExp(
  r'^\s*(?:作词|作曲|编曲|制作|混音|母带|录音|和声|监制|出品|词|曲|written by|composed by|produced by|lyrics by|lyricist|mixed by|mastered by|paroles\s*:|musique\s*:)\s*[:：]?',
  caseSensitive: false,
);
final _regVoyelles = RegExp(r'[aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüýÿœ]+', caseSensitive: false);
final _regCjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
final _regParasites = RegExp(
  r'\s*[\(\[【](?:official\s*(?:music\s*)?(?:video|audio|lyric\s*video|visualizer)|clip\s*officiel|vid[eé]o\s*officielle|audio\s*officiel|paroles|lyrics?\s*(?:video)?|visualizer|hd|hq|4k|8k|remastered|explicit|clean|prod\.?\s*by[^\)\]】]*|dir\.?\s*by[^\)\]】]*)[\)\]】]',
  caseSensitive: false,
);
final _regIdCrochet = RegExp(r'\s*\[[A-Za-z0-9_-]{11}\]\s*$');
final _regFeat = RegExp(r'\s*[\(\[]?\s*\b(?:feat|ft|featuring)\b\.?\s.*$', caseSensitive: false);
final _regChaine = RegExp(r'(?:\s*-\s*topic|vevo|\s*officiel(?:le)?|\s*official|\s*music|\s*tv)+$', caseSensitive: false);

const _marqueursVersion = [
  'live',
  'remix',
  'acoustic',
  'acoustique',
  'instrumental',
  'karaoke',
  'sped up',
  'slowed',
  'nightcore',
  'gospel',
  'cover',
  'freestyle',
];

const _motsVides = {'and', 'et', 'the', 'le', 'la', 'les', 'un', 'une', 'de', 'du', 'des', 'a'};

// ── Nettoyage de titres YouTube et variantes (Onde bibliotheque.py + paroles.py) ──

/// Extrait `(artiste, titre)` depuis un titre YouTube brut.
(String, String) nettoyerNomYoutube(String brut) {
  var s = brut.replaceFirst(_regIdCrochet, '').trim();
  s = s.replaceAll(_regParasites, ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  for (final sep in const [' - ', ' – ', ' — ', ' | ', ' // ']) {
    final idx = s.indexOf(sep);
    if (idx > 1 && idx < s.length - sep.length - 1) {
      final g = s.substring(0, idx).trim();
      final d = s.substring(idx + sep.length).trim();
      if (g.isNotEmpty && d.isNotEmpty) return (g, d);
    }
  }
  return ('', s);
}

String _propre(String? t) {
  if (t == null || t.isEmpty) return '';
  var s = t.replaceFirst(_regIdCrochet, '');
  s = s.replaceAll(_regParasites, ' ');
  s = s.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
  s = s.replaceAll(RegExp(r'\b(?:19|20)\d{2}\b|\b\d{2,3}[kp]\b', caseSensitive: false), ' ');
  s = s.replaceAll(_regFeat, '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[.\-–—|\s]+|[.\-–—|\s]+$'), '');
  return s;
}

String _artistePropre(String? a) {
  if (a == null || a.isEmpty) return '';
  var s = a.trim().replaceAll(_regChaine, '').trim();
  if (!s.contains(' ')) {
    s = s.replaceAllMapped(RegExp(r'(?<=[a-zà-ÿ])(?=[A-Z])'), (_) => ' ');
  }
  return s;
}

/// Génère les couples `(artiste, titre)` à tester, du plus précis au plus large.
List<(String, String)> variantesRecherche(Tache t) {
  final chaine = (t.chaine == null || t.chaine == 'Artiste inconnu') ? '' : t.chaine!;
  final vus = <String>{};
  final res = <(String, String)>[];

  void ajouter(String a, String titre) {
    a = a.trim();
    titre = titre.trim();
    if (titre.isEmpty) return;
    final cle = '${a.toLowerCase()}\u0000${titre.toLowerCase()}';
    if (vus.add(cle)) res.add((a, titre));
  }

  final (aNom, tNom) = nettoyerNomYoutube(t.titre);
  if (aNom.isNotEmpty) {
    ajouter(_artistePropre(aNom), _propre(tNom));
    ajouter(_artistePropre(aNom), tNom.trim());
  }
  if (chaine.isNotEmpty) {
    ajouter(_artistePropre(chaine), _propre(tNom.isNotEmpty ? tNom : t.titre));
    ajouter(chaine, t.titre);
  }
  final principal = _artistePropre(aNom.isNotEmpty ? aNom : chaine)
      .split(RegExp(r'\s+(?:x|&|feat\.?|ft\.?|avec)\s+|,', caseSensitive: false))
      .first
      .trim();
  if (principal.isNotEmpty) {
    ajouter(principal, _propre(tNom.isNotEmpty ? tNom : t.titre));
  }
  ajouter('', _propre(tNom.isNotEmpty ? tNom : t.titre));
  ajouter('', t.titre.replaceFirst(_regIdCrochet, '').trim());
  return res;
}

/// Proposition artiste/titre pré-remplie pour la boîte de recherche manuelle.
(String artiste, String titre) propositionRecherche(Tache t) {
  final v = variantesRecherche(t);
  for (final c in v) {
    if (c.$1.isNotEmpty && c.$2.isNotEmpty) return c;
  }
  return v.isNotEmpty ? v.first : (t.chaine ?? '', t.titre);
}

// ── Conversion YRC / KRC (NetEase mot-à-mot) et analyse LRC ─────────────

double _secondesMatch(RegExpMatch m) {
  final min = int.tryParse(m.group(1) ?? '0') ?? 0;
  final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
  final fracStr = m.group(3) ?? '0';
  final frac = (int.tryParse(fracStr) ?? 0) / pow(10, fracStr.length);
  return min * 60.0 + sec + frac;
}

String _formaterStamp(int ms) {
  final b = max(0, ms);
  final m = (b ~/ 60000).toString().padLeft(2, '0');
  final s = ((b ~/ 1000) % 60).toString().padLeft(2, '0');
  final mil = (b % 1000).toString().padLeft(3, '0');
  return '$m:$s.$mil';
}

/// Convertit le format karaoké mot-à-mot NetEase (`yrc`) en LRC enrichi `<mm:ss.xxx>`.
String? yrcVersLrc(String? yrc) {
  if (yrc == null || yrc.trim().isEmpty) return null;
  final sortie = <String>[];
  for (final brute in yrc.split('\n')) {
    final l = brute.trim();
    if (!l.startsWith('[') || l.startsWith('{"')) continue;
    final ferme = l.indexOf(']');
    if (ferme < 0) continue;
    final entete = l.substring(1, ferme).split(',');
    if (entete.length < 2) continue;
    final debutL = int.tryParse(entete[0].trim());
    final durL = int.tryParse(entete[1].trim());
    if (debutL == null || durL == null) continue;

    var reste = l.substring(ferme + 1);
    final motsL = <(int, int, String)>[];
    while (reste.contains('(')) {
      final i = reste.indexOf('(');
      final j = reste.indexOf(')', i);
      if (j < 0) break;
      final meta = reste.substring(i + 1, j).split(',');
      final apres = reste.substring(j + 1);
      final suiv = apres.indexOf('(');
      final mot = suiv >= 0 ? apres.substring(0, suiv) : apres;
      reste = suiv >= 0 ? apres.substring(suiv) : '';
      final debutM = int.tryParse(meta[0].trim());
      final durM = meta.length > 1 ? (int.tryParse(meta[1].trim()) ?? 0) : 0;
      if (debutM != null && mot.isNotEmpty) {
        motsL.add((debutM, max(40, durM), mot));
      }
    }
    if (motsL.isEmpty) continue;
    final textePropre = motsL.map((e) => e.$3).join().trim();
    if (textePropre.isEmpty || _regCredits.hasMatch(textePropre)) continue;

    final corps = StringBuffer();
    for (var idx = 0; idx < motsL.length; idx++) {
      final (dm, durM, mot) = motsL[idx];
      corps.write('<${_formaterStamp(dm)}>$mot');
      final finM = dm + durM;
      if (idx + 1 < motsL.length && motsL[idx + 1].$1 - finM >= 160) {
        corps.write('<${_formaterStamp(finM)}>');
      }
    }
    final dernier = motsL.last;
    final finLigne = dernier.$2 > 40 ? (dernier.$1 + dernier.$2) : max(debutL + durL, dernier.$1 + 200);
    corps.write('<${_formaterStamp(finLigne)}>');
    sortie.add('[${_formaterStamp(debutL)}]${corps.toString()}');
  }
  return sortie.isNotEmpty ? sortie.join('\n') : null;
}

/// Convertit le format karaoké NetEase (`klyric`) en LRC enrichi `<mm:ss.xxx>`.
String? klyricVersLrc(String? klyric) {
  if (klyric == null || klyric.trim().isEmpty) return null;
  final sortie = <String>[];
  final regMot = RegExp(r'<(\d+),(\d+)(?:,\d+)?>([^<]*)');
  for (final brute in klyric.split('\n')) {
    final l = brute.trim();
    if (!l.startsWith('[')) continue;
    final ferme = l.indexOf(']');
    if (ferme < 0) continue;
    final entete = l.substring(1, ferme).split(',');
    if (entete.length < 2) continue;
    final debutL = int.tryParse(entete[0].trim());
    final durL = int.tryParse(entete[1].trim());
    if (debutL == null || durL == null) continue;

    final motsL = <(int, int, String)>[];
    for (final m in regMot.allMatches(l.substring(ferme + 1))) {
      final offM = int.tryParse(m.group(1) ?? '0') ?? 0;
      final durM = int.tryParse(m.group(2) ?? '0') ?? 0;
      final mot = m.group(3) ?? '';
      if (mot.isNotEmpty) {
        motsL.add((debutL + offM, max(40, durM), mot));
      }
    }
    if (motsL.isEmpty) continue;
    final textePropre = motsL.map((e) => e.$3).join().trim();
    if (textePropre.isEmpty || _regCredits.hasMatch(textePropre)) continue;

    final corps = StringBuffer();
    for (var idx = 0; idx < motsL.length; idx++) {
      final (dm, durM, mot) = motsL[idx];
      corps.write('<${_formaterStamp(dm)}>$mot');
      final finM = dm + durM;
      if (idx + 1 < motsL.length && motsL[idx + 1].$1 - finM >= 160) {
        corps.write('<${_formaterStamp(finM)}>');
      }
    }
    final dernier = motsL.last;
    final finLigne = dernier.$2 > 40 ? (dernier.$1 + dernier.$2) : max(debutL + durL, dernier.$1 + 200);
    corps.write('<${_formaterStamp(finLigne)}>');
    sortie.add('[${_formaterStamp(debutL)}]${corps.toString()}');
  }
  return sortie.isNotEmpty ? sortie.join('\n') : null;
}

/// Poids phonétique d'un mot selon ses syllabes prononcées et sa ponctuation (Onde `_poids_phonetique`).
double _poidsPhonetique(String mot) {
  final net = mot.trim();
  if (net.isEmpty) return 0.0;
  final cjk = _regCjk.allMatches(net).length;
  final sansCjk = net.replaceAll(_regCjk, '');
  final groupes = _regVoyelles.allMatches(sansCjk).length;
  var n = (cjk + groupes).toDouble();
  final propre = sansCjk.replaceAll(RegExp(r'^[.,!?;:"\x27()\[\]{}\-–—…]+|[.,!?;:"\x27()\[\]{}\-–—…]+$'), '');
  if (groupes > 1 && RegExp(r'[^aeiouyàáâäèéêëìíîïòóôöùúûü]es?$', caseSensitive: false).hasMatch(propre)) {
    n = max(1.0, n - 0.6);
  }
  var poids = max(0.75, n) + min(propre.length, 12) * 0.055;
  if (RegExp(r'[,;:—–…]$').hasMatch(net)) {
    poids += 0.42;
  } else if (RegExp(r'[.!?]$').hasMatch(net)) {
    poids += 0.62;
  }
  return poids;
}

/// Découpe une ligne `[debut, fin]` en `MotParole` proportionnellement au poids syllabique
/// lorsque la source ne fournit que les horodatages de phrase (SRT, VTT ou LRC simple).
List<MotParole> decouperMotsPhonetiques(String texte, Duration debut, Duration fin) {
  final morceaux = RegExp(r'\S+\s*').allMatches(texte).map((m) => m.group(0)!).toList();
  if (morceaux.length <= 1) {
    return [MotParole(debut: debut, fin: fin > debut ? fin : debut + const Duration(seconds: 2), texte: texte)];
  }
  final dureeTotaleMs = max(250, (fin - debut).inMilliseconds);
  // On réserve une légère respiration en fin de phrase si l'écart jusqu'à la phrase suivante est long.
  final dureeChantMs = dureeTotaleMs > 4200 ? (dureeTotaleMs * 0.86).round() : dureeTotaleMs;
  final poids = [for (final m in morceaux) max(0.4, _poidsPhonetique(m))];
  final totalPoids = poids.fold(0.0, (a, b) => a + b);
  if (totalPoids <= 0) return const [];

  final res = <MotParole>[];
  var cumul = 0.0;
  for (var i = 0; i < morceaux.length; i++) {
    final dMs = debut.inMilliseconds + ((cumul / totalPoids) * dureeChantMs).round();
    cumul += poids[i];
    final fMs = debut.inMilliseconds + ((cumul / totalPoids) * dureeChantMs).round();
    res.add(MotParole(
      debut: Duration(milliseconds: dMs),
      fin: Duration(milliseconds: max(dMs + 40, fMs)),
      texte: morceaux[i],
    ));
  }
  return res;
}

/// Analyse un texte LRC (standard ou enrichi `<mm:ss.xxx>`) en liste de [LigneParole].
({List<LigneParole> lignes, bool motAMot}) analyserLrc(String? texte, {int? dureeTotaleSec}) {
  if (texte == null || texte.trim().isEmpty) return (lignes: const [], motAMot: false);
  final offsets = _regOffset.allMatches(texte).toList();
  final offsetSec = offsets.isNotEmpty ? (int.tryParse(offsets.last.group(1) ?? '0') ?? 0) / 1000.0 : 0.0;

  final brutes = <(double, String, List<(double, String)>)>[];
  for (final l in texte.split('\n')) {
    final m = _regLigneLrc.firstMatch(l);
    if (m == null) continue;
    final brutMots = m.group(2) ?? '';
    final contenu = brutMots.replaceAll(_regMot, '').trim();
    if (contenu.startsWith('{"') || _regCredits.hasMatch(contenu)) continue;

    final reperes = _regMot.allMatches(brutMots).toList();
    var mots = <(double, String)>[];
    if (reperes.isNotEmpty && brutMots.substring(0, reperes.first.start).trim().isEmpty) {
      for (var i = 0; i < reperes.length; i++) {
        final fin = i + 1 < reperes.length ? reperes[i + 1].start : brutMots.length;
        final mot = brutMots.substring(reperes[i].end, fin);
        mots.add((_secondesMatch(reperes[i]), mot));
      }
      for (var i = 0; i + 1 < mots.length; i++) {
        if (mots[i + 1].$1 < mots[i].$1) {
          mots = [];
          break;
        }
      }
    }

    final premierStamp = _regStamp.firstMatch(m.group(1)!);
    if (premierStamp == null) continue;
    final debut = _secondesMatch(premierStamp);
    for (final s in _regStamp.allMatches(m.group(1)!)) {
      final t = max(0.0, _secondesMatch(s) - offsetSec);
      final motsDecales = [
        for (final (a, mot) in mots) (max(0.0, a + t - (debut - offsetSec)), mot),
      ];
      brutes.add((t, contenu, motsDecales));
    }
  }

  brutes.sort((a, b) => a.$1.compareTo(b.$1));
  if (brutes.isEmpty) return (lignes: const [], motAMot: false);

  // Regrouper deux voix / traductions au même instant (comme Onde `preparerSynchro`).
  final groupes = <(double, List<String>, List<(double, String)>)>[];
  for (final (t, txt, mots) in brutes) {
    final propre = txt.trim();
    if (groupes.isNotEmpty && (groupes.last.$1 - t).abs() < 0.02) {
      if (propre.isNotEmpty && !groupes.last.$2.contains(propre)) {
        groupes.last.$2.add(propre);
      }
    } else {
      groupes.add((t, [if (propre.isNotEmpty) propre], mots));
    }
  }

  var nbRiches = 0;
  var nbChantees = 0;
  final resultat = <LigneParole>[];

  // Pause instrumentale d'intro si le chant commence après 4 s
  if (groupes.first.$1 >= 4.0) {
    resultat.add(LigneParole(
      Duration.zero,
      Duration(milliseconds: (groupes.first.$1 * 1000).round()),
      '♪',
      estPause: true,
    ));
  }

  for (var i = 0; i < groupes.length; i++) {
    final (t, textes, reperes) = groupes[i];
    final finSuiv = i + 1 < groupes.length
        ? groupes[i + 1].$1
        : (dureeTotaleSec != null && dureeTotaleSec > t ? dureeTotaleSec.toDouble() : t + 5.0);
    final txt = textes.where((s) => s.isNotEmpty).join(' / ');
    final debutDur = Duration(milliseconds: (t * 1000).round());
    final finDur = Duration(milliseconds: (max(t + 0.4, finSuiv) * 1000).round());

    if (txt.isEmpty || RegExp(r'^[♪♫·.\s]+$').hasMatch(txt)) {
      if (finSuiv - t >= 2.5) {
        resultat.add(LigneParole(debutDur, finDur, '♪', estPause: true));
      }
      continue;
    }

    nbChantees++;
    var finChant = finSuiv;
    if (reperes.isNotEmpty && reperes.last.$2.trim().isEmpty && reperes.last.$1 > t && reperes.last.$1 < finSuiv) {
      finChant = reperes.last.$1;
    }
    final finChantDur = Duration(milliseconds: (max(t + 0.25, finChant) * 1000).round());

    final motsPrets = <MotParole>[];
    if (reperes.isNotEmpty) {
      for (var k = 0; k < reperes.length; k++) {
        final (a, m) = reperes[k];
        if (m.isEmpty) continue;
        final suiv = k + 1 < reperes.length ? reperes[k + 1].$1 : finChant;
        motsPrets.add(MotParole(
          debut: Duration(milliseconds: (a * 1000).round()),
          fin: Duration(milliseconds: (max(a + 0.04, suiv) * 1000).round()),
          texte: m,
        ));
      }
    }

    if (motsPrets.length >= 2) {
      nbRiches++;
      resultat.add(LigneParole(debutDur, finChantDur, txt, mots: motsPrets));
    } else {
      final estimes = decouperMotsPhonetiques(txt, debutDur, finChantDur);
      resultat.add(LigneParole(debutDur, finChantDur, txt, mots: estimes));
    }

    if (finSuiv - finChant >= 4.0) {
      resultat.add(LigneParole(finChantDur, finDur, '♪', estPause: true));
    }
  }

  final aMotsSource = nbChantees > 0 && nbRiches >= max(2, nbChantees ~/ 3);
  return (lignes: resultat, motAMot: aMotsSource);
}

({int nbLignes, double dernierTemps, bool aMots}) _etendueLrc(String? texteLrc) {
  if (texteLrc == null || texteLrc.trim().isEmpty) return (nbLignes: 0, dernierTemps: 0.0, aMots: false);
  final r = analyserLrc(texteLrc);
  final chantees = r.lignes.where((l) => !l.estPause && l.texte.trim().isNotEmpty).toList();
  if (chantees.length < 2) return (nbLignes: 0, dernierTemps: 0.0, aMots: false);
  return (
    nbLignes: chantees.length,
    dernierTemps: chantees.last.debut.inMilliseconds / 1000.0,
    aMots: r.motAMot,
  );
}

// ── Lecture des sous-titres YouTube (.srt / .vtt) et .lrc locaux ─────────

String _codeLangueFichier(String nom) {
  final parties = nom.split('.');
  if (parties.length >= 3) {
    final cand = parties[parties.length - 2];
    if (cand.length >= 2 && cand.length <= 8 && !cand.contains(' ')) {
      return cand;
    }
  }
  return '';
}

/// Liste toutes les sources locales (.srt, .vtt, .lrc) attachées à une [Tache].
List<({String id, String label, FichierPublie fichier})> sourcesLocalesDisponibles(Tache t) {
  final st = t.fichiers
      .where((f) =>
          f.nom.toLowerCase().endsWith('.srt') ||
          f.nom.toLowerCase().endsWith('.vtt') ||
          f.nom.toLowerCase().endsWith('.lrc'))
      .toList();
  if (st.isEmpty) return const [];
  // Priorité : .lrc d'abord, puis français (.fr), puis VO
  st.sort((a, b) {
    final aLrc = a.nom.toLowerCase().endsWith('.lrc') ? 1 : 0;
    final bLrc = b.nom.toLowerCase().endsWith('.lrc') ? 1 : 0;
    if (aLrc != bLrc) return bLrc.compareTo(aLrc);
    final aFr = a.nom.contains('.fr') ? 1 : 0;
    final bFr = b.nom.contains('.fr') ? 1 : 0;
    return bFr.compareTo(aFr);
  });

  final res = <({String id, String label, FichierPublie fichier})>[];
  for (var i = 0; i < st.length; i++) {
    final f = st[i];
    final ext = f.nom.split('.').last.toUpperCase();
    final code = _codeLangueFichier(f.nom);
    final langLabel = code.isNotEmpty ? '${langues.drapeau(code)} ${langues.nom(code)}' : ext;
    final label = ext == 'LRC' ? 'Fichier .lrc ($langLabel)' : 'Sous-titres YouTube · $langLabel';
    res.add((id: 'local:${f.nom}', label: label, fichier: f));
  }
  return res;
}

/// Analyse un texte de sous-titres `.srt` ou `.vtt` (local ou streaming) en [DonneesParoles].
DonneesParoles? analyserSousTitresTexte(
  String texte, {
  required bool estVtt,
  String? labelSource,
  String idSource = 'st',
  int? dureeTotaleSec,
  bool autoYoutube = false,
}) {
  if (texte.trim().isEmpty) return null;
  try {
    // Si le .srt / .vtt contient déjà des balises LRC, utiliser analyserLrc
    if (_regLigneLrc.hasMatch(texte)) {
      final r = analyserLrc(texte, dureeTotaleSec: dureeTotaleSec);
      if (r.lignes.isNotEmpty) {
        return DonneesParoles(
          source: labelSource ?? 'Sous-titres YouTube',
          idSource: idSource,
          lignes: r.lignes,
          texteBrut: r.lignes.where((l) => !l.estPause).map((l) => l.texte).join('\n'),
          synchro: true,
          motAMot: r.motAMot,
        );
      }
    }

    final ClosedCaptionFile cap = estVtt ? WebVTTCaptionFile(texte) : SubRipCaptionFile(texte);
    final brutes = <(Duration, Duration, String)>[];
    String dernierSegment = '';
    for (final c in cap.captions) {
      final lignesNettoyees = c.text
          .split(RegExp(r'\r?\n'))
          .map((l) => l.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lignesNettoyees.isEmpty) continue;

      // YouTube auto VTT répète la ligne précédente en tête du bloc défilant suivant.
      if (autoYoutube && lignesNettoyees.length >= 2 && dernierSegment.endsWith(lignesNettoyees.first)) {
        lignesNettoyees.removeAt(0);
      }
      final propre = lignesNettoyees.join(' ').trim();
      if (propre.isEmpty) continue;

      if (brutes.isNotEmpty && (brutes.last.$3 == propre || (autoYoutube && c.end - c.start <= const Duration(milliseconds: 60) && brutes.last.$3.endsWith(propre)))) {
        final dern = brutes.removeLast();
        brutes.add((dern.$1, c.end > dern.$2 ? c.end : dern.$2, dern.$3));
        continue;
      }
      dernierSegment = lignesNettoyees.last;
      brutes.add((c.start, c.end, propre));
    }
    if (brutes.isEmpty) return null;

    final lignes = <LigneParole>[];
    if (brutes.first.$1.inMilliseconds >= 4000) {
      lignes.add(LigneParole(Duration.zero, brutes.first.$1, '♪', estPause: true));
    }
    for (var i = 0; i < brutes.length; i++) {
      final (deb, finCap, txt) = brutes[i];
      final suivDeb = i + 1 < brutes.length ? brutes[i + 1].$1 : finCap;
      // Corriger les chevauchements fréquents des sous-titres automatiques YouTube
      final fin = (suivDeb > deb && suivDeb < finCap) ? suivDeb : (finCap > deb ? finCap : deb + const Duration(seconds: 2));
      final mots = decouperMotsPhonetiques(txt, deb, fin);
      lignes.add(LigneParole(deb, fin, txt, mots: mots));
      if (suivDeb - fin >= const Duration(seconds: 4)) {
        lignes.add(LigneParole(fin, suivDeb, '♪', estPause: true));
      }
    }

    return DonneesParoles(
      source: labelSource ?? 'Sous-titres YouTube',
      idSource: idSource,
      lignes: lignes,
      texteBrut: brutes.map((b) => b.$3).join('\n'),
      synchro: true,
      motAMot: false,
    );
  } catch (_) {
    return null;
  }
}

/// Télécharge et analyse une piste de sous-titres en streaming (.vtt / .srt).
Future<DonneesParoles?> chargerSousTitresEnLigne(
  analyse.PisteSousTitreStream piste, {
  Map<String, String>? headers,
  int? dureeTotaleSec,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri.tryParse(piste.url);
    if (uri == null) return null;
    final req = await client.getUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    if (headers == null || !headers.containsKey('User-Agent')) {
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36');
    }
    final rep = await req.close().timeout(timeout);
    if (rep.statusCode < 200 || rep.statusCode >= 300) return null;
    final bytes = await rep.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(timeout);
    final texte = utf8.decode(bytes, allowMalformed: true);
    return analyserSousTitresTexte(
      texte,
      estVtt: piste.vtt,
      labelSource: piste.label,
      idSource: piste.id,
      dureeTotaleSec: dureeTotaleSec,
      autoYoutube: piste.auto,
    );
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Charge un fichier local `.srt`, `.vtt` ou `.lrc` en [DonneesParoles].
Future<DonneesParoles?> chargerFichierParolesLocal(
  FichierPublie f, {
  String? labelSource,
  int? dureeTotaleSec,
}) async {
  try {
    final texte = await Natif.lireTexte(f.uri) ?? '';
    if (texte.trim().isEmpty) return null;
    final nomBas = f.nom.toLowerCase();
    if (nomBas.endsWith('.lrc')) {
      final r = analyserLrc(texte, dureeTotaleSec: dureeTotaleSec);
      final propre = texte.replaceAll(_regMot, '').replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      return DonneesParoles(
        source: labelSource ?? 'Fichier .lrc',
        idSource: 'local:${f.nom}',
        lignes: r.lignes,
        texteBrut: propre,
        synchro: r.lignes.isNotEmpty,
        motAMot: r.motAMot,
      );
    }

    return analyserSousTitresTexte(
      texte,
      estVtt: nomBas.endsWith('.vtt'),
      labelSource: labelSource ?? 'Sous-titres YouTube',
      idSource: 'local:${f.nom}',
      dureeTotaleSec: dureeTotaleSec,
    );
  } catch (_) {
    return null;
  }
}

// ── Notation et correspondance des candidats (Onde `_noter_candidat`) ───

String _sansAccents(String s) {
  const map = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae',
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'œ': 'oe',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y',
  };
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i].toLowerCase();
    sb.write(map[ch] ?? ch);
  }
  return sb.toString();
}

List<String> _tokens(String? s) {
  if (s == null || s.isEmpty) return const [];
  final norm = _sansAccents(s).replaceAll(r'$', 's').replaceAll(RegExp(r"['’.]+"), '');
  return RegExp(r'[a-z0-9]+')
      .allMatches(norm)
      .map((m) => m.group(0)!)
      .where((w) => !_motsVides.contains(w))
      .toList();
}

Set<String> _marqueurs(Iterable<String?> textes) {
  final joint = _sansAccents(textes.whereType<String>().join(' '));
  final trouves = <String>{};
  for (final m in _marqueursVersion) {
    if (RegExp('\\b${RegExp.escape(m)}\\b').hasMatch(joint)) {
      trouves.add(m == 'acoustique' ? 'acoustic' : m);
    }
  }
  return trouves;
}

bool _memeMot(String a, String b) {
  if (a == b) return true;
  final la = a.length, lb = b.length;
  if (la >= 3 && lb >= 3 && (a.contains(b) || b.contains(a)) && (la - lb).abs() <= 2) {
    return true;
  }
  if (la >= 5 && lb >= 5 && (la - lb).abs() <= 1) {
    var diffs = (la - lb).abs();
    final m = min(la, lb);
    for (var i = 0; i < m; i++) {
      if (a[i] != b[i]) diffs++;
    }
    if (diffs <= 1) return true;
  }
  return false;
}

double _couverture(String aiguille, String botte) {
  final ta = _tokens(aiguille);
  if (ta.isEmpty) return 0.0;
  final tb = _tokens(botte);
  if (tb.isEmpty) return 0.0;
  final ok = ta.where((w) => tb.any((x) => _memeMot(w, x))).length;
  return ok / ta.length;
}

double _similariteArtiste(List<String> attendus, String candidat) {
  final candCompact = _tokens(candidat).join();
  if (candCompact.isEmpty) return 0.0;
  var meilleur = 0.0;
  for (final a in attendus) {
    if (a.isEmpty) continue;
    final ac = _tokens(a).join();
    if (ac.length >= 3 && (candCompact.contains(ac) || (ac.contains(candCompact) && candCompact.length >= 3))) {
      return 1.0;
    }
    meilleur = max(meilleur, max(_couverture(a, candidat), _couverture(candidat, a)));
  }
  return meilleur;
}

({double score, bool exact, double? ecart, bool deborde, int nbLignes, bool aMots})? _noterCandidat(
  Tache tache,
  List<(String, String)> varsP,
  CandidatParoles cand,
) {
  final verPiste = _marqueurs([tache.titre]);
  final verCand = _marqueurs([cand.titre, cand.album]);
  if (verPiste.length != verCand.length || !verPiste.containsAll(verCand)) {
    return null;
  }

  var titreCand = cand.titre;
  final artCand = cand.artiste;
  if (titreCand.contains(' - ')) {
    final idx = titreCand.indexOf(' - ');
    final g = titreCand.substring(0, idx);
    final d = titreCand.substring(idx + 3);
    if (_similariteArtiste([g], artCand) >= 0.9) titreCand = d;
  }
  final ct = _propre(titreCand).isNotEmpty ? _propre(titreCand) : titreCand.trim();
  if (ct.isEmpty) return null;

  final artistesPiste = [for (final (a, _) in varsP) if (a.isNotEmpty) a];
  final titresPiste = <String>{for (final (_, t) in varsP) if (t.isNotEmpty) t}.toList();
  final dureePiste = (tache.duree ?? 0).toDouble();
  var dureeCand = cand.duree;

  final etendue = _etendueLrc(cand.syncedLyrics);
  final deborde = dureePiste > 0 && etendue.dernierTemps > dureePiste + 4.5;
  if (deborde) {
    dureeCand = max(dureeCand, etendue.dernierTemps + 3.0);
  }

  final ecart = (dureePiste > 0 && dureeCand > 0) ? (dureeCand - dureePiste).abs() : null;
  final exact = ecart != null && ecart <= max(3.5, dureePiste * 0.025) && !deborde;

  double? meilleurBase;
  for (var idxT = 0; idxT < titresPiste.length; idxT++) {
    final tCherche = titresPiste[idxT];
    final covT = _couverture(tCherche, ct);
    final covRet = _couverture(ct, tCherche);
    final simA = artistesPiste.isNotEmpty ? _similariteArtiste(artistesPiste, artCand) : 0.0;
    final nbMotsT = _tokens(ct).length;

    double? base;
    if (artistesPiste.isNotEmpty) {
      if (covT >= 0.80 && covRet >= 0.68 && simA >= 0.60) {
        base = covT * 42.0 + covRet * 20.0 + simA * 32.0 - idxT * 1.5;
      } else if (covT >= 0.98 && covRet >= 0.98 && ecart != null && ecart <= 3.0 && nbMotsT >= 2) {
        base = 62.0 - idxT * 1.5;
      }
    } else {
      final tout = _couverture(tCherche, '$artCand $ct');
      final artDansQ = _couverture(artCand, tCherche) >= 0.90;
      if (tout >= 0.92 && covRet >= 0.88) {
        if (artDansQ && (ecart == null || ecart <= 25.0)) {
          base = 82.0;
        } else if (ecart != null && ecart <= 4.0 && (nbMotsT >= 2 || ecart <= 2.0)) {
          base = 58.0;
        }
      }
    }
    if (base != null && (meilleurBase == null || base > meilleurBase)) {
      meilleurBase = base;
    }
  }

  if (meilleurBase == null) return null;

  var penaliteEcart = min(ecart ?? 25.0, 120.0) * 0.35;
  if (deborde) penaliteEcart += 35.0;
  final bonusExact = exact ? 18.0 : 0.0;
  final bonusMots = ((cand.motAMot || etendue.aMots) && !deborde) ? 14.0 : 0.0;
  return (
    score: meilleurBase + bonusExact + bonusMots - penaliteEcart,
    exact: exact,
    ecart: ecart,
    deborde: deborde,
    nbLignes: etendue.nbLignes,
    aMots: cand.motAMot || etendue.aMots,
  );
}

// ── Requêtes HTTP vers LRCLIB et NetEase Cloud Music ────────────────────

Future<dynamic> _httpJson(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, 'YT-NEXUS/1.9 (Onde Lyrics Engine)');
    headers?.forEach(req.headers.set);
    final rep = await req.close().timeout(timeout);
    if (rep.statusCode < 200 || rep.statusCode >= 300) return null;
    final texte = await rep.transform(utf8.decoder).join().timeout(timeout);
    return jsonDecode(texte);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

const _headersNetease = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  'Referer': 'https://music.163.com/',
};

Future<List<CandidatParoles>> _lrclibGet(String artiste, String titre, int? duree) async {
  final params = <String, String>{
    'track_name': titre,
    'artist_name': artiste,
    if (duree != null && duree > 0) 'duration': '$duree',
  };
  final d = await _httpJson(Uri.https('lrclib.net', '/api/get', params));
  if (d is! Map) return const [];
  final c = _candidatDepuisLrclib(d, titreDefaut: titre, artisteDefaut: artiste);
  return c != null ? [c] : const [];
}

Future<List<CandidatParoles>> _lrclibSearch(Map<String, String> params) async {
  final d = await _httpJson(Uri.https('lrclib.net', '/api/search', params));
  if (d is! List) return const [];
  final res = <CandidatParoles>[];
  for (final item in d) {
    if (item is Map) {
      final c = _candidatDepuisLrclib(item);
      if (c != null) res.add(c);
    }
  }
  return res;
}

CandidatParoles? _candidatDepuisLrclib(Map r, {String titreDefaut = '', String artisteDefaut = ''}) {
  final syn = r['syncedLyrics'] as String?;
  final plain = r['plainLyrics'] as String?;
  final instr = r['instrumental'] == true;
  if ((syn == null || syn.trim().isEmpty) && (plain == null || plain.trim().isEmpty) && !instr) {
    return null;
  }
  final etendue = _etendueLrc(syn);
  final brut = (syn ?? plain ?? '')
      .replaceAll(_regMot, '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(3)
      .join(' / ');
  return CandidatParoles(
    id: 'lrclib:${r['id'] ?? 0}',
    source: 'LRCLIB',
    titre: (r['trackName'] as String?) ?? titreDefaut,
    artiste: (r['artistName'] as String?) ?? artisteDefaut,
    album: (r['albumName'] as String?) ?? '',
    duree: (r['duration'] as num?)?.toDouble() ?? 0.0,
    synchro: syn != null && syn.trim().isNotEmpty && etendue.nbLignes >= 2,
    motAMot: etendue.aMots,
    instrumental: instr,
    extrait: brut.length > 110 ? '${brut.substring(0, 110)}…' : brut,
    syncedLyrics: syn,
    plainLyrics: plain,
  );
}

Future<List<({int sid, String titre, String artiste, String album, double duree})>> _neteaseRechercher(
  String termes, {
  int limite = 6,
}) async {
  final uri = Uri.https('music.163.com', '/api/cloudsearch/pc', {
    's': termes,
    'type': '1',
    'limit': '$limite',
  });
  final d = await _httpJson(uri, headers: _headersNetease, timeout: const Duration(seconds: 5));
  if (d is! Map) return const [];
  final result = d['result'];
  if (result is! Map) return const [];
  final songs = result['songs'];
  if (songs is! List) return const [];
  final res = <({int sid, String titre, String artiste, String album, double duree})>[];
  for (final s in songs) {
    if (s is! Map) continue;
    final sid = (s['id'] as num?)?.toInt();
    final nom = (s['name'] as String?)?.trim() ?? '';
    if (sid == null || nom.isEmpty) continue;
    final ar = (s['ar'] as List?) ?? const [];
    final artistes = ar
        .whereType<Map>()
        .map((a) => (a['name'] as String?)?.trim() ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
    final al = s['al'];
    final album = al is Map ? ((al['name'] as String?) ?? '') : '';
    final duree = ((s['dt'] as num?)?.toDouble() ?? 0.0) / 1000.0;
    res.add((sid: sid, titre: nom, artiste: artistes, album: album, duree: duree));
  }
  return res;
}

Future<CandidatParoles?> _neteaseParoles(
  int sid, {
  String titre = '',
  String artiste = '',
  String album = '',
  double duree = 0.0,
}) async {
  final uri = Uri.parse(
    'https://music.163.com/api/song/lyric/v1?id=$sid&cp=false&lv=1&kv=1&tv=1&rv=1&yv=1&ytv=1&yrv=1',
  );
  final d = await _httpJson(uri, headers: _headersNetease, timeout: const Duration(seconds: 5));
  if (d is! Map) return null;
  if (d['nolyric'] == true || d['pureMusic'] == true) {
    return CandidatParoles(
      id: 'netease:$sid',
      source: 'NetEase',
      titre: titre,
      artiste: artiste,
      album: album,
      duree: duree,
      instrumental: true,
    );
  }
  final yrc = (d['yrc'] is Map) ? (d['yrc']['lyric'] as String?) : null;
  final krc = (d['klyric'] is Map) ? (d['klyric']['lyric'] as String?) : null;
  final lrc = ((d['lrc'] is Map) ? (d['lrc']['lyric'] as String?) : null)?.trim() ?? '';
  if (lrc.contains('纯音乐，请欣赏')) {
    return CandidatParoles(
      id: 'netease:$sid',
      source: 'NetEase',
      titre: titre,
      artiste: artiste,
      album: album,
      duree: duree,
      instrumental: true,
    );
  }
  final enrichi = yrcVersLrc(yrc) ?? klyricVersLrc(krc);
  final texteSynchro = enrichi ?? (_etendueLrc(lrc).nbLignes >= 3 ? lrc : null);
  final texteBrut = (texteSynchro ?? lrc)
      .replaceAll(_regMot, '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .trim();
  if (texteSynchro == null && texteBrut.isEmpty) return null;
  final extrait = texteBrut
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !_regCredits.hasMatch(l))
      .take(3)
      .join(' / ');
  return CandidatParoles(
    id: 'netease:$sid',
    source: 'NetEase',
    titre: titre,
    artiste: artiste,
    album: album,
    duree: duree,
    synchro: texteSynchro != null,
    motAMot: enrichi != null,
    extrait: extrait.length > 110 ? '${extrait.substring(0, 110)}…' : extrait,
    syncedLyrics: texteSynchro,
    plainLyrics: texteBrut.isNotEmpty ? texteBrut : null,
  );
}

DonneesParoles _donneesDepuisCandidat(CandidatParoles c, {int? dureeTotaleSec, bool approximatif = false}) {
  if (c.instrumental) {
    return DonneesParoles(
      source: c.source,
      idSource: c.id,
      instrumental: true,
    );
  }
  final r = analyserLrc(c.syncedLyrics, dureeTotaleSec: dureeTotaleSec);
  final brut = c.plainLyrics ??
      (c.syncedLyrics ?? '')
          .replaceAll(_regMot, '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .trim();
  final sourceLabel = c.motAMot || r.motAMot ? '${c.source} · Karaoké mot-à-mot' : c.source;
  return DonneesParoles(
    source: sourceLabel,
    idSource: c.id,
    lignes: r.lignes,
    texteBrut: brut,
    synchro: r.lignes.isNotEmpty,
    motAMot: c.motAMot || r.motAMot,
    approximatif: approximatif,
  );
}

// ── Cache disque et résolution complète (comme `onde/paroles.py`) ────────

Directory get _dossierParoles {
  final d = Directory('${Natif.dossierFichiers}/paroles');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

File _fichierCache(String idTache) => File('${_dossierParoles.path}/$idTache.json');

DonneesParoles? lireCacheParoles(String idTache, {bool ignorerVideAncien = true}) {
  final f = _fichierCache(idTache);
  if (!f.existsSync()) return null;
  try {
    final map = jsonDecode(f.readAsStringSync()) as Map;
    final res = DonneesParoles.depuisJson(map);
    if (res.vide && ignorerVideAncien) {
      final ts = (map['ts'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > 6 * 3600 * 1000) {
        return null;
      }
    }
    return res;
  } catch (_) {
    return null;
  }
}

void sauverCacheParoles(String idTache, DonneesParoles d) {
  try {
    _fichierCache(idTache).writeAsStringSync(jsonEncode(d.versJson()));
  } catch (_) {}
}

/// Recherche automatique multi-sources (LRCLIB + NetEase YRC/KRC) pour une [Tache].
Future<DonneesParoles?> chercherParolesAutoEnLigne(Tache t) async {
  final varsP = variantesRecherche(t);
  if (varsP.isEmpty) return null;

  final candidats = <CandidatParoles>[];
  final neteaseBruts = <({int sid, String titre, String artiste, String album, double duree})>[];
  final requetesVues = <String>{};
  final futures = <Future<void>>[];

  for (var idx = 0; idx < min(4, varsP.length); idx++) {
    final (a, titre) = varsP[idx];
    if (idx == 0 && a.isNotEmpty) {
      futures.add(_lrclibGet(a, titre, t.duree).then(candidats.addAll));
    }
    final termes = a.isNotEmpty ? '$a $titre'.trim() : titre;
    final cleQ = 'q:${termes.toLowerCase()}';
    if (requetesVues.add(cleQ)) {
      futures.add(_lrclibSearch({'q': termes}).then(candidats.addAll));
      futures.add(_neteaseRechercher(termes, limite: 6).then(neteaseBruts.addAll));
    }
    if (a.isNotEmpty) {
      final cleTa = 'ta:${a.toLowerCase()}:${titre.toLowerCase()}';
      if (requetesVues.add(cleTa)) {
        futures.add(_lrclibSearch({'track_name': titre, 'artist_name': a}).then(candidats.addAll));
      }
    }
  }

  await Future.wait(futures);

  // Pré-filtrer les meilleurs candidats NetEase et récupérer leurs paroles YRC/KRC
  final neNotes = <(double, ({int sid, String titre, String artiste, String album, double duree}))>[];
  final idsVus = <int>{};
  for (final c in neteaseBruts) {
    if (!idsVus.add(c.sid)) continue;
    final note = _noterCandidat(
      t,
      varsP,
      CandidatParoles(id: 'netease:${c.sid}', source: 'NetEase', titre: c.titre, artiste: c.artiste, album: c.album, duree: c.duree),
    );
    if (note != null) neNotes.add((note.score, c));
  }
  neNotes.sort((a, b) => b.$1.compareTo(a.$1));

  if (neNotes.isNotEmpty) {
    final lyrList = await Future.wait([
      for (final (_, c) in neNotes.take(3))
        _neteaseParoles(c.sid, titre: c.titre, artiste: c.artiste, album: c.album, duree: c.duree),
    ]);
    for (final lyr in lyrList) {
      if (lyr != null) candidats.add(lyr);
    }
  }

  // Noter tous les candidats
  final notes = <(({double score, bool exact, double? ecart, bool deborde, int nbLignes, bool aMots}), CandidatParoles)>[];
  for (final c in candidats) {
    final n = _noterCandidat(t, varsP, c);
    if (n != null) notes.add((n, c));
  }

  // 1. Synchronisé de durée exacte (avec priorité au mot-à-mot YRC/KRC)
  final synchroExacts = notes.where((x) => x.$1.nbLignes >= 3 && x.$1.exact).toList();
  if (synchroExacts.isNotEmpty) {
    synchroExacts.sort((a, b) {
      if (a.$1.aMots != b.$1.aMots) return b.$1.aMots ? 1 : -1;
      return b.$1.score.compareTo(a.$1.score);
    });
    return _donneesDepuisCandidat(synchroExacts.first.$2, dureeTotaleSec: t.duree, approximatif: false);
  }

  // 2. Synchronisé d'une version proche (écart <= 45 s)
  final dureePiste = (t.duree ?? 0).toDouble();
  final synchroApprox = notes.where((x) {
    final n = x.$1;
    final c = x.$2;
    if (n.nbLignes < 3) return false;
    if (n.ecart != null && n.ecart! > 45.0) return false;
    if (!n.deborde) return true;
    return n.ecart != null && n.ecart! <= 45.0 && (dureePiste <= 0 || c.duree <= dureePiste + 50.0);
  }).toList();

  if (synchroApprox.isNotEmpty) {
    synchroApprox.sort((a, b) {
      final sa = a.$1.score - (a.$1.ecart ?? 15.0) * 1.5;
      final sb = b.$1.score - (b.$1.ecart ?? 15.0) * 1.5;
      return sb.compareTo(sa);
    });
    return _donneesDepuisCandidat(synchroApprox.first.$2, dureeTotaleSec: t.duree, approximatif: true);
  }

  // 3. Texte non synchronisé en repli
  final textes = notes.where((x) => (x.$2.plainLyrics?.isNotEmpty ?? false) || (x.$2.syncedLyrics?.isNotEmpty ?? false)).toList();
  if (textes.isNotEmpty) {
    textes.sort((a, b) => b.$1.score.compareTo(a.$1.score));
    final meilleur = textes.first.$2;
    final brut = meilleur.plainLyrics ??
        (meilleur.syncedLyrics ?? '').replaceAll(_regMot, '').replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
    return DonneesParoles(
      source: '${meilleur.source} (texte)',
      idSource: meilleur.id,
      texteBrut: brut,
      synchro: false,
    );
  }

  // 4. Instrumental
  final instr = notes.where((x) => x.$2.instrumental).toList();
  if (instr.isNotEmpty) {
    return DonneesParoles(source: instr.first.$2.source, idSource: instr.first.$2.id, instrumental: true);
  }

  return null;
}

/// Recherche manuelle interactive sur LRCLIB + NetEase (comme la modale d'Onde).
Future<List<CandidatParoles>> chercherParolesManuellement(String requete, {int? duree}) async {
  final q = requete.trim();
  if (q.isEmpty) return const [];
  final resultats = <CandidatParoles>[];

  final fLrc = _lrclibSearch({'q': q}).then(resultats.addAll);
  final fNe = () async {
    final ne = await _neteaseRechercher(q, limite: 6);
    if (ne.isEmpty) return;
    final lyrs = await Future.wait([
      for (final c in ne.take(4))
        _neteaseParoles(c.sid, titre: c.titre, artiste: c.artiste, album: c.album, duree: c.duree),
    ]);
    for (final l in lyrs) {
      if (l != null) resultats.add(l);
    }
  }();

  await Future.wait([fLrc, fNe]);

  resultats.sort((a, b) {
    if (a.synchro != b.synchro) return b.synchro ? 1 : -1;
    if (duree != null && duree > 0) {
      final ea = (a.duree - duree).abs();
      final eb = (b.duree - duree).abs();
      final aProche = ea <= 4.0;
      final bProche = eb <= 4.0;
      if (aProche != bProche) return bProche ? 1 : -1;
      if (a.motAMot != b.motAMot) return b.motAMot ? 1 : -1;
      return ea.compareTo(eb);
    }
    if (a.motAMot != b.motAMot) return b.motAMot ? 1 : -1;
    return 0;
  });

  return resultats.take(25).toList();
}

/// Applique et met en cache un [CandidatParoles] choisi par l'utilisateur pour une [Tache].
Future<DonneesParoles?> choisirCandidatParoles(Tache t, CandidatParoles c) async {
  DonneesParoles res;
  if (c.syncedLyrics != null || c.plainLyrics != null || c.instrumental) {
    res = _donneesDepuisCandidat(c, dureeTotaleSec: t.duree);
  } else if (c.id.startsWith('netease:')) {
    final sid = int.tryParse(c.id.split(':').last) ?? 0;
    final complet = await _neteaseParoles(sid, titre: c.titre, artiste: c.artiste, album: c.album, duree: c.duree);
    if (complet == null) return null;
    res = _donneesDepuisCandidat(complet, dureeTotaleSec: t.duree);
  } else {
    final lid = c.id.replaceFirst('lrclib:', '');
    final d = await _httpJson(Uri.https('lrclib.net', '/api/get/$lid'));
    if (d is! Map) return null;
    final complet = _candidatDepuisLrclib(d, titreDefaut: c.titre, artisteDefaut: c.artiste);
    if (complet == null) return null;
    res = _donneesDepuisCandidat(complet, dureeTotaleSec: t.duree);
  }
  sauverCacheParoles(t.id, res);
  return res;
}

/// Importe un texte LRC ou texte libre collé par l'utilisateur.
DonneesParoles importerTexteParoles(Tache t, String texte) {
  final propre = texte.trim();
  final r = analyserLrc(propre, dureeTotaleSec: t.duree);
  final brut = propre.replaceAll(_regMot, '').replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
  final res = DonneesParoles(
    source: r.lignes.isNotEmpty ? 'LRC importé' : 'Texte importé',
    idSource: 'import',
    lignes: r.lignes,
    texteBrut: brut,
    synchro: r.lignes.isNotEmpty,
    motAMot: r.motAMot,
  );
  sauverCacheParoles(t.id, res);
  return res;
}
