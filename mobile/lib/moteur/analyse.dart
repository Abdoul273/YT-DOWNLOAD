/// Récupération des infos (vidéo, playlist, chaîne, recherche) via yt-dlp -J.
/// Portage de nexus/analyse.py.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'erreurs.dart' as erreurs;
import 'formats.dart';
import 'langues.dart' as langues;
import 'natif.dart';
import 'reglages.dart';

const dureeCache = Duration(minutes: 30); // les liens YouTube expirent après ~6 h
final _cache = <String, (DateTime, Json)>{};
var _compteur = 0;

class ErreurAnalyse implements Exception {
  final String message;
  final bool passagere;
  ErreurAnalyse(this.message, [this.passagere = false]);
  @override
  String toString() => message;
}

Future<Json> _extraire(String url, List<String> extra) async {
  final r = await Natif.executer('analyse-${_compteur++}', [
    '-J', '--no-warnings', '--ignore-config',
    '--socket-timeout', '20', '--extractor-retries', '3',
    // date de publication dans les recherches/playlists
    '--extractor-args', 'youtubetab:approximate_date',
    ...reglages.argsAuth(), ...extra, url,
  ]);
  final debut = r.sortie.indexOf('{');
  if (debut >= 0) {
    try {
      return (jsonDecode(r.sortie.substring(debut)) as Map).cast<String, dynamic>();
    } catch (_) {}
  }
  final (message, passagere) = erreurs.analyser(r.erreur.isNotEmpty ? r.erreur : r.sortie, r.code);
  throw ErreurAnalyse(message, passagere);
}

/// Infos complètes d'une vidéo (avec formats), mises en cache.
Future<Json> infoComplete(String url, {bool frais = false}) async {
  final ent = _cache[url];
  if (ent != null && !frais && DateTime.now().difference(ent.$1) < dureeCache) return ent.$2;
  final info = await _extraire(url, ['--no-playlist']);
  final e = (DateTime.now(), info);
  _cache[url] = e;
  if (info['webpage_url'] is String) _cache[info['webpage_url']] = e;
  while (_cache.length > 48) {
    final plusVieux = _cache.entries.reduce((a, b) => a.value.$1.isBefore(b.value.$1) ? a : b).key;
    _cache.remove(plusVieux);
  }
  return info;
}

/// Retourne les infos déjà présentes en mémoire sans lancer de requête réseau.
Json? infoEnCache(String url) {
  final ent = _cache[url];
  if (ent == null || DateTime.now().difference(ent.$1) >= dureeCache) return null;
  return ent.$2;
}

void oublier(String url) => _cache.remove(url);

String? miniature(Json e) {
  if (e['thumbnail'] is String) return e['thumbnail'];
  final thumbs = ((e['thumbnails'] as List?) ?? []).cast<Map>().where((t) => t['url'] != null).toList();
  if (thumbs.isNotEmpty) {
    final moyennes = thumbs.where((t) => ((t['width'] ?? 0) as num) >= 300 && ((t['width'] ?? 0) as num) <= 720);
    return (moyennes.isNotEmpty ? moyennes.last : thumbs.last)['url'];
  }
  if (e['ie_key'] == 'Youtube' || '${e['url']}'.contains('youtube')) {
    return 'https://i.ytimg.com/vi/${e['id']}/mqdefault.jpg';
  }
  return null;
}

int? _ts(String? uploadDate) {
  if (uploadDate == null || uploadDate.length != 8) return null;
  final d = DateTime.tryParse('${uploadDate.substring(0, 4)}-${uploadDate.substring(4, 6)}-${uploadDate.substring(6)}T12:00:00');
  return d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
}

/// Une vidéo d'une liste (recherche, playlist, chaîne).
class Entree {
  final String? id, url, miniature, chaine, chaineId, chaineUrl;
  final String titre;
  final int? duree, vues, date;
  final bool direct;
  Entree(this.id, this.titre, this.url, this.duree, this.miniature, this.chaine, this.vues, this.date, this.direct,
      {this.chaineId, this.chaineUrl});

  Json versJson() => {
        'id': id, 'titre': titre, 'url': url, 'duree': duree, 'miniature': miniature, 'chaine': chaine,
        'vues': vues, 'date': date, 'direct': direct, 'chaine_id': chaineId,
        if (chaineUrl != null) 'chaine_url': chaineUrl,
      };
  factory Entree.depuis(Map d) => Entree(d['id'], d['titre'] ?? 'Sans titre', d['url'], d['duree'], d['miniature'],
      d['chaine'], d['vues'], d['date'], d['direct'] == true,
      chaineId: d['chaine_id'], chaineUrl: d['chaine_url']);
}

Entree _entree(Json e) {
  var url = (e['url'] ?? e['webpage_url']) as String?;
  final u = url ?? '';
  final youtube = e['ie_key'] == 'Youtube' || u.contains('youtube.com/watch') || u.contains('youtu.be/');
  if (url != null && !url.startsWith('http') && youtube) url = 'https://www.youtube.com/watch?v=${e['id']}';
  final mini = youtube && e['id'] != null ? 'https://i.ytimg.com/vi/${e['id']}/mqdefault.jpg' : miniature(e);
  return Entree(
    e['id'] as String?, (e['title'] ?? 'Sans titre') as String, url, (e['duration'] as num?)?.toInt(), mini,
    (e['channel'] ?? e['uploader']) as String?, (e['view_count'] as num?)?.toInt(),
    ((e['timestamp'] ?? e['release_timestamp']) as num?)?.toInt() ?? _ts(e['upload_date'] as String?),
    e['live_status'] == 'is_live',
    chaineId: e['channel_id'] as String?,
    chaineUrl: (e['channel_url'] ?? e['uploader_url']) as String?,
  );
}

/// Résultat d'exploration d'une chaîne YouTube (Vidéos, Shorts ou Directs).
class InfosChaine {
  final String titre;
  final String url;
  final String? avatar;
  final int? abonnes;
  final List<Entree> entrees;
  const InfosChaine({
    required this.titre,
    required this.url,
    this.avatar,
    this.abonnes,
    required this.entrees,
  });
}

String _racineChaine(String url) {
  var u = url.trim().split('?').first.replaceFirst(RegExp(r'/+$'), '');
  u = u.replaceFirst(RegExp(r'/(videos|shorts|streams|playlists|featured|community)$'), '');
  return u;
}

/// Charge les vidéos d'une chaîne YouTube depuis son lien, son ID ou une vidéo de secours.
Future<InfosChaine> explorerChaine({
  String? chaineUrl,
  String? chaineId,
  String? nomChaine,
  String? videoUrlSecours,
  String section = 'videos',
  int max = 30,
}) async {
  var base = (chaineUrl ?? '').trim();
  if (base.isEmpty && chaineId != null && chaineId.isNotEmpty) {
    base = 'https://www.youtube.com/channel/$chaineId';
  }
  String? resolvedId = chaineId;
  if (base.isEmpty && videoUrlSecours != null && videoUrlSecours.isNotEmpty) {
    final info = await infoComplete(videoUrlSecours);
    base = ((info['channel_url'] ?? info['uploader_url']) as String?) ?? '';
    resolvedId ??= info['channel_id'] as String?;
    if (base.isEmpty && resolvedId != null && resolvedId.isNotEmpty) {
      base = 'https://www.youtube.com/channel/$resolvedId';
    }
  }
  if (base.isEmpty) throw ErreurAnalyse('Chaîne introuvable pour cette vidéo.');
  final racine = _racineChaine(normaliserUrl(base));
  final cible = '$racine/$section';
  final brut = await _extraire(cible, ['--flat-playlist', '--playlist-end', '$max']);
  final titreBrut = ((brut['channel'] ?? brut['uploader'] ?? brut['title'] ?? nomChaine ?? 'Chaîne') as String)
      .replaceFirst(RegExp(r'\s*-\s*(Videos|Shorts|Live|Streams)$', caseSensitive: false), '')
      .trim();
  final nomFinal = titreBrut.isEmpty ? (nomChaine ?? 'Chaîne') : titreBrut;
  final chId = (brut['channel_id'] as String?) ?? resolvedId;
  final entrees = <Entree>[
    for (final item in ((brut['entries'] as List?) ?? []).whereType<Map>())
      if (item['id'] != null && item['ie_key'] != 'YoutubeTab')
        (() {
          final e = _entree(item.cast<String, dynamic>());
          if ((e.chaine != null && e.chaine!.isNotEmpty) && (e.chaineId != null || chId == null)) return e;
          return Entree(
            e.id, e.titre, e.url, e.duree, e.miniature,
            e.chaine ?? nomFinal, e.vues, e.date, e.direct,
            chaineId: e.chaineId ?? chId,
            chaineUrl: e.chaineUrl ?? racine,
          );
        })(),
  ];
  return InfosChaine(
    titre: nomFinal,
    url: cible,
    avatar: miniature(brut) ?? (entrees.isNotEmpty ? entrees.first.miniature : null),
    abonnes: (brut['channel_follower_count'] as num?)?.toInt(),
    entrees: entrees,
  );
}

/// Vidéos d'une liste (mix, chaîne, page) sans les détails, limitées à [max].
Future<List<Entree>> listeVideos(String url, {int max = 25}) async {
  final brut = await _extraire(url, ['--flat-playlist', '--playlist-end', '$max']);
  return [
    for (final e in ((brut['entries'] as List?) ?? []).whereType<Map>())
      if (e['id'] != null && e['ie_key'] != 'YoutubeTab') _entree(e.cast<String, dynamic>())
  ];
}

String normaliserUrl(String url) {
  url = url.trim();
  if (url.isNotEmpty && !RegExp(r'^[a-z]+://', caseSensitive: false).hasMatch(url)) url = 'https://$url';
  final p = Uri.tryParse(url);
  if (p == null) return url;
  final hote = p.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '').replaceFirst(RegExp(r'^m\.'), '');
  // Chaîne YouTube sans onglet → onglet Vidéos
  if (hote == 'youtube.com' && RegExp(r'^/(@[^/]+|channel/[^/]+|c/[^/]+|user/[^/]+)/?$').hasMatch(p.path)) {
    url = '${url.split('?').first.replaceFirst(RegExp(r'/+$'), '')}/videos';
  }
  return url;
}

/// Lien de la playlist si une vidéo est ouverte depuis une playlist.
String? playlistAssociee(String url) {
  final q = Uri.tryParse(url)?.queryParameters ?? {};
  final l = q['list'];
  if (q.containsKey('v') && l != null && !l.startsWith('RD') && !l.startsWith('UL')) {
    return 'https://www.youtube.com/playlist?list=$l';
  }
  return null;
}

/// Résumé d'une vidéo pour l'écran de choix des options.
class ResumeVideo {
  final Json info;
  final String url, titre;
  final String? chaine, miniature, originale, pisteVoulue, playlist, date;
  final int? duree, vues;
  final bool direct;
  final int chapitres;
  final List<Piste> pistes;
  final SousTitres sousTitres;
  ResumeVideo(this.info, this.url, this.titre, this.chaine, this.miniature, this.originale, this.pisteVoulue,
      this.playlist, this.date, this.duree, this.vues, this.direct, this.chapitres, this.pistes, this.sousTitres);

  String? get originaleNom => originale == null ? null : langues.nom(originale);
  (List<Qualite>, int) qualitesPour(String? piste) => qualites(info, piste ?? originale);
}

ResumeVideo resumeVideo(Json info) {
  final pistes = pistesAudio(info);
  return ResumeVideo(
    info,
    (info['webpage_url'] ?? info['original_url'] ?? '') as String,
    (info['title'] ?? 'Sans titre') as String,
    (info['channel'] ?? info['uploader']) as String?,
    miniature(info),
    langueOriginale(info, pistes),
    trouverPiste(pistes, reglages['langue_audio']),
    playlistAssociee((info['original_url'] ?? '') as String),
    info['upload_date'] as String?,
    (info['duration'] as num?)?.toInt(),
    (info['view_count'] as num?)?.toInt(),
    info['live_status'] == 'is_live',
    ((info['chapters'] as List?) ?? []).length,
    pistes,
    sousTitresDispo(info),
  );
}

class Playlist {
  final String url, titre;
  final String? chaine, miniature;
  final List<Entree> entrees;
  Playlist(this.url, this.titre, this.chaine, this.miniature, this.entrees);
}

/// Analyse un lien : renvoie un [ResumeVideo] ou une [Playlist].
Future<Object> analyser(String lien) async {
  final url = normaliserUrl(lien);
  if (!url.startsWith('http')) throw ErreurAnalyse('Lien invalide.');
  if (playlistAssociee(url) == null &&
      (url.contains('/watch') || url.contains('/shorts/') || url.contains('youtu.be/'))) {
    return resumeVideo(await infoComplete(url));
  }
  final brut = await _extraire(url, ['--flat-playlist']);
  if (brut['_type'] == 'playlist' || brut['_type'] == 'multi_video' || brut['entries'] != null) {
    final entrees = [
      for (final e in ((brut['entries'] as List?) ?? []).whereType<Map>())
        if (e['id'] != null) _entree(e.cast<String, dynamic>())
    ];
    // Chaîne : les entrées peuvent être des onglets (Vidéos, Shorts…)
    bool onglet(Entree e) {
      final u = (e.url ?? '').replaceFirst(RegExp(r'/+$'), '');
      return u.contains('/playlist') || u.endsWith('/videos') || u.endsWith('/shorts') || u.endsWith('/streams');
    }

    if (entrees.isNotEmpty && entrees.every(onglet)) return analyser(entrees.first.url!);
    return Playlist(url, (brut['title'] ?? 'Playlist') as String, (brut['channel'] ?? brut['uploader']) as String?,
        miniature(brut) ?? (entrees.isNotEmpty ? entrees.first.miniature : null), entrees);
  }
  _cache[url] = (DateTime.now(), brut);
  return resumeVideo(brut);
}

// Filtres de recherche YouTube (paramètre « sp », protobuf encodé en base64)
const tris = {'pertinence': 0, 'note': 1, 'date': 2, 'vues': 3};
const dates = {'heure': (1, 3600), 'jour': (2, 86400), 'semaine': (3, 7 * 86400), 'mois': (4, 31 * 86400), 'annee': (5, 366 * 86400)};
const durees = {'courte': 1, 'longue': 2, 'moyenne': 3};

class Filtres {
  String tri = 'pertinence';
  String? date, duree;
  bool hd = false, k4 = false, sousTitres = false;
  bool get actifs => date != null || duree != null || hd || k4 || sousTitres;
}

String _paramSp(Filtres f) {
  final filtre = <int>[];
  if (f.date != null) filtre.addAll([0x08, dates[f.date]!.$1]);
  filtre.addAll([0x10, 1]); // vidéos seulement
  if (f.duree != null) filtre.addAll([0x18, durees[f.duree]!]);
  if (f.hd) filtre.addAll([0x20, 1]);
  if (f.sousTitres) filtre.addAll([0x28, 1]);
  if (f.k4) filtre.addAll([0x70, 1]);
  final tri = tris[f.tri] ?? 0;
  return base64Encode([if (tri != 0) ...[0x08, tri], 0x12, filtre.length, ...filtre]);
}

Future<List<Entree>> rechercher(String requete, Filtres f, {int nombre = 30}) async {
  final Json brut;
  if (f.tri == 'pertinence' && !f.actifs) {
    brut = await _extraire('ytsearch$nombre:$requete', ['--flat-playlist']);
  } else {
    final url = Uri.https('www.youtube.com', '/results', {'search_query': requete, 'sp': _paramSp(f)}).toString();
    brut = await _extraire(url, ['--flat-playlist', '--playlist-end', '$nombre']);
  }
  var res = [
    for (final e in ((brut['entries'] as List?) ?? []).whereType<Map>())
      if (e['id'] != null) _entree(e.cast<String, dynamic>())
  ];
  // YouTube glisse parfois des vidéos hors période : on les écarte (date approximative → marge)
  if (f.date != null) {
    final limite = DateTime.now().millisecondsSinceEpoch ~/ 1000 - (dates[f.date]!.$2 * 1.5).round() - 3600;
    res = res.where((e) => e.date == null || e.date! >= limite).toList();
  }
  if (f.tri == 'vues') res.sort((a, b) => (b.vues ?? 0).compareTo(a.vues ?? 0));
  if (f.tri == 'date') res.sort((a, b) => (b.date ?? 0).compareTo(a.date ?? 0));
  return res;
}

/// Source vidéo directement lisible en streaming (HLS adaptatif, variante HLS ciblée ou MP4 multiplexé).
class SourceApercu {
  final String id;
  final String libelle;
  final int hauteur;
  final int fps;
  final String? codec;
  final int? debitKbps;
  final String url;
  final Map<String, String> entetes;
  final bool hls;
  final bool adaptatif;
  final String? m3u8Filtre;

  const SourceApercu({
    required this.id,
    required this.libelle,
    required this.url,
    this.hauteur = 0,
    this.fps = 0,
    this.codec,
    this.debitKbps,
    this.entetes = const {},
    this.hls = false,
    this.adaptatif = false,
    this.m3u8Filtre,
  });

  /// Retourne l'URL jouable (publie localement le manifeste filtré si besoin).
  Future<String> urlExecutable() async {
    if (m3u8Filtre == null) return url;
    return _ServeurHlsLocal.publier(m3u8Filtre!);
  }
}

class _ServeurHlsLocal {
  static HttpServer? _serveur;
  static Future<HttpServer>? _demarrage;
  static final _contenus = <String, String>{};
  static var _seq = 0;

  static Future<HttpServer> _obtenir() {
    if (_serveur != null) return Future.value(_serveur);
    return _demarrage ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((s) {
      _serveur = s;
      s.listen((req) {
        final cle = req.uri.pathSegments.isNotEmpty ? req.uri.pathSegments.last.replaceFirst('.m3u8', '') : '';
        final corps = _contenus[cle];
        if (corps == null) {
          req.response
            ..statusCode = HttpStatus.notFound
            ..close();
          return;
        }
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.set('Content-Type', 'application/vnd.apple.mpegurl; charset=utf-8')
          ..write(corps)
          ..close();
      });
      return s;
    });
  }

  static Future<String> publier(String m3u8) async {
    final s = await _obtenir();
    final cle = 'v${++_seq}';
    _contenus[cle] = m3u8;
    while (_contenus.length > 16) {
      _contenus.remove(_contenus.keys.first);
    }
    return 'http://127.0.0.1:${s.port}/flux/$cle.m3u8';
  }
}

String _nomCodec(String? vcodec) {
  final c = (vcodec ?? '').toLowerCase();
  if (c.contains('avc1') || c.contains('avc3') || c.contains('h264')) return 'H.264';
  if (c.contains('hev1') || c.contains('hvc1') || c.contains('h265')) return 'HEVC';
  if (c.contains('vp09') || c.contains('vp9')) return 'VP9';
  if (c.contains('av01') || c.contains('av1')) return 'AV1';
  return '';
}

String _libelleResolution(int hauteur, {int fps = 0, String? suffixe}) {
  if (hauteur <= 0) return suffixe ?? 'Auto';
  final base = switch (hauteur) {
    >= 2160 => '4K',
    >= 1440 => '2K',
    _ => '${hauteur}p',
  };
  final fp = fps > 30 ? '$fps' : '';
  final extra = suffixe != null && suffixe.isNotEmpty ? ' · $suffixe' : '';
  return '$base$fp$extra';
}

int _normaliserHauteur(int w, int h) {
  final petit = math.min(w, h);
  if (petit <= 0) return 0;
  return hauteurs.firstWhere((x) => petit >= x * 0.9, orElse: () => petit);
}

final _regAttrM3u8 = RegExp(r'([A-Z0-9-]+)=("([^"]*)"|[^,]*)');

Map<String, String> _attrsM3u8(String ligne) {
  final res = <String, String>{};
  final idx = ligne.indexOf(':');
  if (idx < 0) return res;
  for (final m in _regAttrM3u8.allMatches(ligne.substring(idx + 1))) {
    final cle = m.group(1)!;
    final val = m.group(3) ?? m.group(2) ?? '';
    res[cle] = val;
  }
  return res;
}

String _resoudreMediaUri(String ligne, Uri baseUri) {
  return ligne.replaceFirstMapped(RegExp(r'URI="([^"]+)"'), (m) {
    final brute = m.group(1)!;
    final abs = baseUri.resolve(brute).toString();
    return 'URI="$abs"';
  });
}

/// Analyse un manifeste HLS maître (`#EXTM3U`) et extrait chaque résolution jouable
/// avec ses pistes audio associées préservées (`#EXT-X-MEDIA`).
@visibleForTesting
List<SourceApercu> analyserM3u8Maitre(String contenu, Uri baseUri, Map<String, String> entetes) {
  final lignes = const LineSplitter().convert(contenu);
  if (!lignes.any((l) => l.trim() == '#EXTM3U')) return const [];

  final entetesGlobal = <String>[];
  final medias = <({String? groupId, String? type, String ligne})>[];
  final candidats = <({int hauteur, int fps, int bw, bool avc, String codec, String m3u8, String url})>[];

  for (var i = 0; i < lignes.length; i++) {
    final l = lignes[i].trim();
    if (l.isEmpty) continue;
    if (l == '#EXT-X-INDEPENDENT-SEGMENTS' || l.startsWith('#EXT-X-VERSION:')) {
      entetesGlobal.add(l);
      continue;
    }
    if (l.startsWith('#EXT-X-MEDIA:')) {
      final a = _attrsM3u8(l);
      medias.add((groupId: a['GROUP-ID'], type: a['TYPE'], ligne: _resoudreMediaUri(l, baseUri)));
      continue;
    }
    if (l.startsWith('#EXT-X-STREAM-INF:')) {
      String? urlLigne;
      var j = i + 1;
      while (j < lignes.length) {
        final suiv = lignes[j].trim();
        if (suiv.isEmpty) {
          j++;
          continue;
        }
        if (!suiv.startsWith('#')) urlLigne = baseUri.resolve(suiv).toString();
        break;
      }
      if (urlLigne == null) continue;
      i = j;

      final attrs = _attrsM3u8(l);
      final resStr = attrs['RESOLUTION'] ?? '';
      final dims = resStr.split('x');
      if (dims.length != 2) continue;
      final w = int.tryParse(dims[0]) ?? 0;
      final h = int.tryParse(dims[1]) ?? 0;
      final hauteur = _normaliserHauteur(w, h);
      if (hauteur <= 0) continue;

      final fpsNum = double.tryParse(attrs['FRAME-RATE'] ?? '') ?? 30;
      final fps = fpsNum.round();
      final bw = int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
      final codecs = attrs['CODECS'] ?? '';
      final avc = codecs.toLowerCase().contains('avc1') || codecs.toLowerCase().contains('avc3');
      final audioGrp = attrs['AUDIO'];
      final subsGrp = attrs['SUBTITLES'];

      final buf = StringBuffer('#EXTM3U\n');
      for (final hg in entetesGlobal) {
        buf.writeln(hg);
      }
      for (final m in medias) {
        final keepAudio = m.type == 'AUDIO' && (audioGrp == null || m.groupId == audioGrp);
        final keepSub = m.type == 'SUBTITLES' && subsGrp != null && m.groupId == subsGrp;
        if (keepAudio || keepSub || (m.type != 'AUDIO' && m.type != 'SUBTITLES')) {
          buf.writeln(m.ligne);
        }
      }
      buf.writeln(l);
      buf.writeln(urlLigne);

      candidats.add((
        hauteur: hauteur,
        fps: fps,
        bw: bw,
        avc: avc,
        codec: _nomCodec(codecs),
        m3u8: buf.toString(),
        url: urlLigne,
      ));
    }
  }

  // Garder la meilleure variante par palier (H.264 prioritaire pour compatibilité matérielle).
  final parCle = <String, ({int hauteur, int fps, int bw, bool avc, String codec, String m3u8, String url})>{};
  for (final c in candidats) {
    final fpsCle = c.fps > 30 ? c.fps : 30;
    final cle = '${c.hauteur}p$fpsCle';
    final existant = parCle[cle];
    if (existant == null ||
        (c.avc && !existant.avc) ||
        (c.avc == existant.avc && c.bw > existant.bw)) {
      parCle[cle] = c;
    }
  }

  final liste = parCle.values.toList()
    ..sort((a, b) {
      final r = b.hauteur.compareTo(a.hauteur);
      if (r != 0) return r;
      return b.fps.compareTo(a.fps);
    });

  return [
    for (final c in liste)
      SourceApercu(
        id: 'hls:${c.hauteur}${c.fps > 30 ? 'p${c.fps}' : ''}',
        libelle: _libelleResolution(c.hauteur, fps: c.fps),
        hauteur: c.hauteur,
        fps: c.fps,
        codec: c.codec.isEmpty ? 'HLS' : c.codec,
        debitKbps: c.bw > 0 ? (c.bw / 1000).round() : null,
        url: c.url,
        entetes: entetes,
        hls: true,
        m3u8Filtre: c.m3u8,
      ),
  ];
}

/// Flux lisibles directement pour l'aperçu, du meilleur au moins bon :
/// 1. le manifeste HLS maître (adaptatif, jusqu'à 1080p+, son inclus) ;
/// 2. un format vidéo+audio progressif (souvent le 360p n°18 ou 720p) ;
/// 3. une variante HLS déjà multiplexée.
/// Liste vide si rien n'est lisible sans fusion.
List<SourceApercu> sourcesApercu(Json info) {
  final formats = ((info['formats'] as List?) ?? []).whereType<Map>().where((f) => f['url'] is String).toList();
  bool avecSon(Map f) => f['acodec'] != null && f['acodec'] != 'none';
  bool avecImage(Map f) => f['vcodec'] != null && f['vcodec'] != 'none';
  bool estHls(Map f) => '${f['protocol']}'.startsWith('m3u8');
  int hauteur(Map f) {
    final w = ((f['width'] ?? 0) as num).toInt();
    final h = ((f['height'] ?? 0) as num).toInt();
    return w > 0 && h > 0 ? _normaliserHauteur(w, h) : h;
  }

  Map<String, String> entetes(Map f) =>
      ((f['http_headers'] ?? info['http_headers'] ?? {}) as Map).map((k, v) => MapEntry('$k', '$v'));

  final res = <SourceApercu>[];
  final vus = <String>{};
  void ajouter(SourceApercu src) {
    if (vus.add(src.url)) res.add(src);
  }

  // 1. Manifeste maître (préférence aux variantes H.264, décodées partout)
  final variantes = formats.where((f) => estHls(f) && f['manifest_url'] is String).toList()
    ..sort((a, b) {
      int score(Map f) => ('${f['vcodec']}'.startsWith('avc1') ? 1 : 0);
      return score(b).compareTo(score(a));
    });
  for (final f in variantes) {
    ajouter(SourceApercu(
      id: 'auto',
      libelle: 'Auto (adaptatif)',
      url: f['manifest_url'] as String,
      entetes: entetes(f),
      hls: true,
      adaptatif: true,
      codec: 'HLS',
    ));
  }
  if (info['manifest_url'] is String && '${info['manifest_url']}'.contains('m3u8')) {
    ajouter(SourceApercu(
      id: 'auto',
      libelle: 'Auto (adaptatif)',
      url: info['manifest_url'] as String,
      entetes: entetes(info),
      hls: true,
      adaptatif: true,
      codec: 'HLS',
    ));
  }

  // 2. Progressif vidéo+audio, 3. variante HLS multiplexée
  for (final hls in [false, true]) {
    final muxes = formats
        .where((f) => avecSon(f) && avecImage(f) && hauteur(f) <= 2160)
        .where((f) => estHls(f) == hls && !'${f['protocol']}'.contains('dash'))
        .toList()
      ..sort((a, b) => hauteur(b).compareTo(hauteur(a)));
    for (final f in muxes.take(4)) {
      final h = hauteur(f);
      final fps = ((f['fps'] ?? 0) as num).round();
      final codec = _nomCodec(f['vcodec'] as String?);
      ajouter(SourceApercu(
        id: '${hls ? 'hls_mux' : 'mux'}:${h}p${fps > 30 ? fps : ''}',
        libelle: h > 0 ? _libelleResolution(h, fps: fps) : (hls ? 'Flux HLS' : 'Flux MP4'),
        hauteur: h,
        fps: fps,
        codec: codec.isEmpty ? (hls ? 'HLS' : 'MP4') : codec,
        debitKbps: ((f['tbr'] as num?)?.round()),
        url: f['url'] as String,
        entetes: entetes(f),
        hls: hls,
      ));
    }
  }
  return res;
}

/// Construit la liste complète des qualités sélectionnables en streaming (Auto adaptatif + résolutions HLS + MP4 directs).
Future<List<SourceApercu>> resoudreQualitesStreaming(
  Json info, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final base = sourcesApercu(info);
  if (base.isEmpty) return const [];

  final maitre = base.where((s) => s.adaptatif).firstOrNull;
  var variantesHls = <SourceApercu>[];
  if (maitre != null) {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse(maitre.url);
      final req = await client.getUrl(uri).timeout(timeout);
      maitre.entetes.forEach(req.headers.set);
      final rep = await req.close().timeout(timeout);
      if (rep.statusCode >= 200 && rep.statusCode < 300) {
        final contenu = await rep.transform(utf8.decoder).join().timeout(timeout);
        variantesHls = analyserM3u8Maitre(contenu, uri, maitre.entetes);
      }
    } catch (_) {
      // On garde simplement les sources de base si la récupération échoue
    } finally {
      client.close(force: true);
    }
  }

  final resultat = <SourceApercu>[];
  final clesVues = <String>{};
  void pousser(SourceApercu s) {
    final cle = s.adaptatif ? 'auto' : '${s.hauteur}p${s.fps > 30 ? s.fps : 30}';
    if (clesVues.add(cle)) resultat.add(s);
  }

  if (maitre != null) pousser(maitre);
  final fixes = <SourceApercu>[
    ...variantesHls,
    for (final s in base)
      if (!s.adaptatif) s,
  ]..sort((a, b) {
      final r = b.hauteur.compareTo(a.hauteur);
      if (r != 0) return r;
      final fp = b.fps.compareTo(a.fps);
      if (fp != 0) return fp;
      // Préférence HLS maître (audio préservé / seek multi-piste) puis progressif MP4
      return (b.m3u8Filtre != null ? 1 : 0).compareTo(a.m3u8Filtre != null ? 1 : 0);
    });
  for (final s in fixes) {
    pousser(s);
  }
  return resultat;
}

/// Piste de sous-titres disponible en streaming pour une vidéo YouTube.
class PisteSousTitreStream {
  final String id;
  final String code;
  final String label;
  final String url;
  final bool vtt;
  final bool auto;

  const PisteSousTitreStream({
    required this.id,
    required this.code,
    required this.label,
    required this.url,
    required this.vtt,
    required this.auto,
  });
}

/// Liste ordonnée des pistes de sous-titres diffusables directement en streaming.
List<PisteSousTitreStream> sousTitresStreaming(Json info) {
  final res = <PisteSousTitreStream>[];
  final origin = langueOriginale(info);
  final pref = reglages['langue_audio'] as String?;

  ({String url, bool vtt})? choisirUrl(dynamic liste) {
    if (liste is! List) return null;
    String? vttUrl, srtUrl;
    for (final item in liste) {
      if (item is! Map) continue;
      final u = item['url'] as String?;
      final ext = '${item['ext'] ?? ''}'.toLowerCase();
      if (u == null || u.isEmpty) continue;
      if (ext == 'vtt' && vttUrl == null) vttUrl = u;
      if (ext == 'srt' && srtUrl == null) srtUrl = u;
    }
    if (vttUrl != null) return (url: vttUrl, vtt: true);
    if (srtUrl != null) return (url: srtUrl, vtt: false);
    return null;
  }

  int scoreLangue(String code) {
    if (pref != null && pref != 'original' && langues.memeLangue(code, pref)) return 0;
    if (langues.memeLangue(code, 'fr')) return 1;
    if (origin != null && langues.memeLangue(code, origin)) return 2;
    if (langues.memeLangue(code, 'en')) return 3;
    return 4;
  }

  final manuelsMap = ((info['subtitles'] as Map?) ?? const {});
  final manuels = <({int score, PisteSousTitreStream piste})>[];
  for (final entry in manuelsMap.entries) {
    final code = '${entry.key}';
    if (code == 'live_chat') continue;
    final trouve = choisirUrl(entry.value);
    if (trouve == null) continue;
    manuels.add((
      score: scoreLangue(code),
      piste: PisteSousTitreStream(
        id: 'st:$code',
        code: code,
        label: '${langues.drapeau(code)} ${langues.nom(code)}',
        url: trouve.url,
        vtt: trouve.vtt,
        auto: false,
      ),
    ));
  }
  manuels.sort((a, b) {
    final r = a.score.compareTo(b.score);
    return r != 0 ? r : a.piste.label.compareTo(b.piste.label);
  });
  for (final m in manuels) {
    res.add(m.piste);
  }

  // Pour les sous-titres automatiques (~150 traductions YouTube), on garde les langues utiles.
  final autoMap = ((info['automatic_captions'] as Map?) ?? const {});
  const languesAutoUtiles = {'fr', 'en', 'es', 'de', 'ar', 'pt', 'it', 'ja', 'ko', 'nl', 'ru', 'zh-Hans'};
  final autos = <({int score, PisteSousTitreStream piste})>[];
  for (final entry in autoMap.entries) {
    final code = '${entry.key}';
    if (code == 'live_chat') continue;
    final origTagged = code.endsWith('-orig');
    final baseCode = origTagged ? code.substring(0, code.length - 5) : code;
    final utile = origTagged ||
        languesAutoUtiles.any((l) => langues.memeLangue(baseCode, l)) ||
        (pref != null && pref != 'original' && langues.memeLangue(baseCode, pref)) ||
        (origin != null && langues.memeLangue(baseCode, origin));
    if (!utile) continue;
    final trouve = choisirUrl(entry.value);
    if (trouve == null) continue;
    autos.add((
      score: scoreLangue(baseCode) + (origTagged ? 0 : 1),
      piste: PisteSousTitreStream(
        id: 'auto:$code',
        code: baseCode,
        label: '${langues.drapeau(baseCode)} ${langues.nom(baseCode)} · auto',
        url: trouve.url,
        vtt: trouve.vtt,
        auto: true,
      ),
    ));
  }
  autos.sort((a, b) {
    final r = a.score.compareTo(b.score);
    return r != 0 ? r : a.piste.label.compareTo(b.piste.label);
  });
  for (final a in autos) {
    res.add(a.piste);
  }

  return res;
}

/// Infos de secours pour l'aperçu : clients YouTube qui exposent le HLS et le format 18
/// quand l'extraction par défaut n'a rien donné de lisible.
Future<Json> infoApercuSecours(String url) =>
    _extraire(url, ['--no-playlist', '--extractor-args', 'youtube:player_client=default,android_vr,mweb']);
