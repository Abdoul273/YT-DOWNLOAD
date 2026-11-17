/// Analyse des formats YouTube et construction de la sélection yt-dlp.
///
/// YouTube propose plusieurs pistes audio par vidéo (doublages humains ou IA).
/// yt-dlp prend par défaut la piste « originale » ; ici on choisit la piste
/// dans la langue voulue, en premier (lue par défaut), et on garde la VO en
/// deuxième piste si demandé. Portage de nexus/formats.py.
library;

import 'langues.dart' as langues;

const hauteurs = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144];
const libelles = {4320: '8K', 2160: '4K', 1440: '2K', 1080: 'FHD', 720: 'HD'};

typedef Json = Map<String, dynamic>;

bool _aucun(dynamic v) => v == null || v == 'none';
bool estAudio(Json f) => !_aucun(f['acodec']) && _aucun(f['vcodec']);
bool estVideo(Json f) => !_aucun(f['vcodec']);
int taille(Json f) => ((f['filesize'] ?? f['filesize_approx'] ?? 0) as num).toInt();

List<Json> _formats(Json info) => ((info['formats'] as List?) ?? []).cast<Json>();

class Piste {
  final String code, nom, drapeau, genre;
  final bool originale;
  const Piste(this.code, this.nom, this.drapeau, this.genre, this.originale);
}

List<Piste> pistesAudio(Json info) {
  final pistes = <String, Map<String, dynamic>>{};
  for (final f in _formats(info)) {
    final code = f['language'] as String?;
    if (!estAudio(f) || code == null || code.isEmpty) continue;
    final note = ((f['format_note'] ?? '') as String).toLowerCase();
    final p = pistes.putIfAbsent(code, () => {'originale': false, 'ia': false, 'doublee': false});
    if (note.contains('original') || ((f['language_preference'] ?? -1) as num) >= 10) p['originale'] = true;
    if (note.contains('dubbed-auto')) {
      p['ia'] = true;
    } else if (note.contains('dubbed')) {
      p['doublee'] = true;
    }
  }
  if (pistes.length == 1) pistes.values.first['originale'] = true;
  final res = [
    for (final e in pistes.entries)
      Piste(
        e.key,
        langues.nom(e.key),
        langues.drapeau(e.key),
        e.value['originale'] ? 'originale' : (e.value['ia'] ? 'doublage IA' : 'doublage'),
        e.value['originale'],
      )
  ];
  int rang(Piste p) => (p.originale ? 0 : 2) + (langues.memeLangue(p.code, 'fr') ? 0 : 1);
  res.sort((a, b) {
    final r = rang(a).compareTo(rang(b));
    return r != 0 ? r : a.nom.compareTo(b.nom);
  });
  return res;
}

String? langueOriginale(Json info, [List<Piste>? pistes]) {
  for (final p in pistes ?? pistesAudio(info)) {
    if (p.originale) return p.code;
  }
  return info['language'] as String?;
}

/// Code de la piste correspondant à la langue voulue (fr → fr, fr-FR, fr-CA…).
String? trouverPiste(List<Piste> pistes, String? voulue) {
  if (voulue == null || voulue.isEmpty || voulue == 'original') return null;
  for (final p in pistes) {
    if (p.code.toLowerCase() == voulue.toLowerCase()) return p.code;
  }
  for (final p in pistes) {
    if (langues.memeLangue(p.code, voulue)) return p.code;
  }
  return null;
}

class Qualite {
  final int hauteur, fps, taille;
  final bool hdr;
  const Qualite(this.hauteur, this.fps, this.hdr, this.taille);
  String get libelle => '${hauteur}p${fps > 30 ? fps : ''}';
  String get badge => libelles[hauteur] ?? '';
}

/// Résolutions disponibles avec taille estimée (vidéo + audio choisi).
(List<Qualite>, int) qualites(Json info, [String? piste]) {
  final formats = _formats(info);
  final audio = formats.where((f) => estAudio(f) && (piste == null || f['language'] == piste)).toList();
  int maxi(Iterable<int> v) => v.fold(0, (a, b) => a > b ? a : b);
  var tailleAudio = maxi(audio.where((f) => f['ext'] == 'm4a').map(taille));
  if (tailleAudio == 0) tailleAudio = maxi(audio.map(taille));
  final parHauteur = <int, List<dynamic>>{}; // [fps, hdr, taille]
  for (final f in formats) {
    final hf = (f['height'] as num?)?.toInt();
    if (!estVideo(f) || hf == null || hf == 0) continue;
    final w = (f['width'] as num?)?.toInt() ?? hf;
    var h = hf < w ? hf : w; // vidéos verticales
    h = hauteurs.firstWhere((x) => h >= x * 0.9, orElse: () => h);
    final q = parHauteur.putIfAbsent(h, () => [0, false, 0]);
    final fps = ((f['fps'] ?? 0) as num).toInt();
    if (fps > q[0]) q[0] = fps;
    q[1] = q[1] || ((f['dynamic_range'] ?? 'SDR') != 'SDR');
    if (taille(f) > q[2]) q[2] = taille(f);
  }
  final cles = parHauteur.keys.toList()..sort((a, b) => b.compareTo(a));
  return (
    [
      for (final h in cles)
        Qualite(h, parHauteur[h]![0], parHauteur[h]![1],
            parHauteur[h]![2] > 0 ? parHauteur[h]![2] + tailleAudio : 0)
    ],
    tailleAudio
  );
}

/// Pistes à télécharger : (piste voulue trouvée, originale, garder la VO).
(String?, String?, bool) planAudio(Json info, String langue, bool garderVo) {
  final pistes = pistesAudio(info);
  final originale = langueOriginale(info, pistes);
  final trouvee = trouverPiste(pistes, langue);
  if (langue == 'original' || (trouvee != null && originale != null && trouvee == originale)) {
    return (null, originale, false);
  }
  return (trouvee, originale, trouvee != null && originale != null && garderVo);
}

/// Chaîne de sélection de formats yt-dlp, avec replis sûrs.
String selecteur(Json opts, String? piste, String? originale, bool deuxPistes) {
  final audioVoulu = piste != null
      ? 'ba[language=$piste]'
      : (originale != null ? 'ba[language=$originale]' : 'ba');
  if (opts['type'] == 'audio') return '$audioVoulu/ba/b';
  final h = '${opts['qualite'] ?? 'best'}';
  final numerique = int.tryParse(h) != null;
  final video = numerique ? 'bv*[height<=$h]' : 'bv*';
  return [
    if (deuxPistes) '$video+$audioVoulu+ba[language=$originale]',
    '$video+$audioVoulu',
    '$video+ba',
    numerique ? 'b[height<=$h]/b' : 'b',
  ].join('/');
}

/// Préférences de tri : formats compatibles avec le conteneur choisi.
List<String> tri(Json opts) {
  final conteneur = opts['conteneur'] ?? 'mp4';
  if (opts['type'] == 'audio') {
    return [(opts['format_audio'] == 'm4a' || opts['format_audio'] == 'mp3') ? 'ext:m4a' : 'acodec:opus'];
  }
  // Prête à publier : H.264 + AAC d'abord (seul couple accepté partout : TikTok, Reels, YouTube…),
  // la résolution ensuite. YouTube sert l'H.264 jusqu'en 1080p, le plafond de TikTok.
  if (opts['compatible'] == true) return ['vcodec:h264', 'res', 'fps', 'acodec:aac', 'ext:mp4:m4a'];
  if (conteneur == 'mp4') return ['res', 'fps', 'ext:mp4:m4a'];
  if (conteneur == 'webm') return ['res', 'fps', 'ext:webm:webm'];
  return ['res', 'fps'];
}

/// Codecs acceptés par TikTok, Instagram, Facebook, YouTube… (vidéo H.264, audio AAC).
/// Codec inconnu → considéré incompatible : mieux vaut convertir que voir l'envoi refusé.
bool videoPubliable(String? v) =>
    v == 'none' || v != null && (v.startsWith('avc1') || v.startsWith('avc3') || v == 'h264' || v == 'avc');
bool audioPubliable(String? a) => a == 'none' || a != null && (a.startsWith('mp4a') || a == 'aac');

/// Réencodage ffmpeg (libx264 est fourni par youtubedl-android) : H.264 High 8 bits 4:2:0,
/// plus grand côté ramené à 1920 px sans jamais agrandir. AAC stéréo 48 kHz.
const argsVideoPubliable = '-c:v libx264 -preset veryfast -crf 20 -profile:v high -level:v 4.2 -pix_fmt yuv420p '
    '-vf "scale=w=\'min(1920,iw)\':h=\'min(1920,ih)\':force_original_aspect_ratio=decrease:force_divisible_by=2"';
const argsAudioPubliable = '-c:a aac -b:a 192k -ar 48000 -ac 2';

class SousTitres {
  final List<String> manuels;
  final bool auto, autoFr;
  const SousTitres(this.manuels, this.auto, this.autoFr);
}

SousTitres sousTitresDispo(Json info) {
  final manuels = ((info['subtitles'] as Map?) ?? {}).keys.cast<String>().where((c) => c != 'live_chat').toList()
    ..sort();
  final auto = ((info['automatic_captions'] as Map?) ?? {}).keys.cast<String>();
  return SousTitres(manuels, auto.isNotEmpty, auto.any((c) => langues.memeLangue(c, 'fr')));
}

class SelectionFormats {
  final String selecteurExact;
  final List<(String, int, String)> parties;
  final List<(String?, String?)> codecs;
  const SelectionFormats(this.selecteurExact, this.parties, this.codecs);
}

int _hauteurFormat(Json f) {
  final hf = (f['height'] as num?)?.toInt() ?? 0;
  final w = (f['width'] as num?)?.toInt() ?? hf;
  if (hf <= 0) return 0;
  return w > 0 && hf > w ? w : hf;
}

bool _estHlsOuDash(Json f) {
  final p = '${f['protocol'] ?? ''}';
  return p.startsWith('m3u8') || p.contains('dash');
}

String _libellePartie(int? hauteur, String? code, bool video) => video
    ? 'Vidéo ${hauteur != null && hauteur > 0 ? '${hauteur}p' : ''}'.trim()
    : (code != null && code.isNotEmpty && code != 'NA' ? 'Audio ${langues.drapeau(code)} ${langues.nom(code)}' : 'Audio');

/// Résout en Dart les formats correspondant à [selecteur] et [tri] sans lancer de sous-processus `-sim`.
/// Retourne `null` si `info['formats']` est vide ou si aucun format direct exploitable n'est trouvé.
SelectionFormats? resoudreFormatsSelection(
  Json info,
  Json opts,
  String? piste,
  String? originale,
  bool deuxPistes,
) {
  final tous = _formats(info).where((f) => f['format_id'] != null).toList();
  if (tous.isEmpty) return null;

  final selRepli = selecteur(opts, piste, originale, deuxPistes);
  final conteneur = (opts['conteneur'] ?? 'mp4') as String;
  final compatible = opts['compatible'] == true;
  final estModeAudio = opts['type'] == 'audio';
  final formatAudio = '${opts['format_audio'] ?? 'mp3'}';
  final veulentM4a = estModeAudio ? (formatAudio == 'm4a' || formatAudio == 'mp3') : (compatible || conteneur == 'mp4');
  final veulentOpus = estModeAudio && !veulentM4a;

  final bruts = tous.where((f) => !_estHlsOuDash(f)).toList();
  final pool = bruts.isNotEmpty ? bruts : tous;

  int scoreAudio(Json f, {String? codeVise}) {
    var s = 0;
    final code = f['language'] as String?;
    if (codeVise != null) {
      if (code == codeVise) {
        s += 100000;
      } else if (code != null && langues.memeLangue(code, codeVise)) {
        s += 50000;
      }
    }
    final ac = '${f['acodec'] ?? ''}'.toLowerCase();
    final ext = '${f['ext'] ?? ''}'.toLowerCase();
    if (compatible && (ac.startsWith('mp4a') || ac == 'aac')) s += 4000;
    if (veulentM4a && (ext == 'm4a' || ac.startsWith('mp4a') || ac == 'aac')) s += 2000;
    if (veulentOpus && (ac.contains('opus') || ext == 'webm')) s += 2000;
    if (!estModeAudio && conteneur == 'webm' && (ext == 'webm' || ac.contains('opus'))) s += 1500;
    if ((f['preference'] as num?)?.toInt() != null && (f['preference'] as num).toInt() < 0) s -= 500; // évite DRC si normal dispo
    final abr = ((f['abr'] ?? f['tbr'] ?? 0) as num).round();
    return s + abr;
  }

  Json? choisirAudio(String? codeVise) {
    final candidats = pool.where(estAudio).where((f) {
      if (codeVise == null) return true;
      final l = f['language'] as String?;
      return l == codeVise || (l != null && langues.memeLangue(l, codeVise));
    }).toList();
    if (candidats.isEmpty) return null;
    candidats.sort((a, b) => scoreAudio(b, codeVise: codeVise).compareTo(scoreAudio(a, codeVise: codeVise)));
    return candidats.first;
  }

  SelectionFormats depuisListe(List<Json> choisis) {
    final idStr = choisis.map((f) => '${f['format_id']}').join('+');
    return SelectionFormats(
      '$idStr/$selRepli',
      [
        for (final f in choisis)
          (
            '${f['format_id']}',
            taille(f),
            _libellePartie((f['height'] as num?)?.toInt(), f['language'] as String?, estVideo(f)),
          ),
      ],
      [for (final f in choisis) (f['vcodec'] as String?, f['acodec'] as String?)],
    );
  }

  final audioPrincipal = choisirAudio(piste ?? originale) ?? choisirAudio(null);

  if (estModeAudio) {
    if (audioPrincipal != null) return depuisListe([audioPrincipal]);
    final mux = pool.where((f) => estAudio(f) || !_aucun(f['acodec'])).toList();
    if (mux.isEmpty) return null;
    mux.sort((a, b) => scoreAudio(b).compareTo(scoreAudio(a)));
    return depuisListe([mux.first]);
  }

  final maxH = int.tryParse('${opts['qualite'] ?? 'best'}');
  final videos = pool.where((f) {
    if (!estVideo(f) || _aucun(f['vcodec'])) return false;
    // Préférer vidéo seule pour bv+ba quand un flux audio séparé existe
    if (!_aucun(f['acodec'])) return false;
    final h = _hauteurFormat(f);
    if (h <= 0) return false;
    return maxH == null || h <= maxH;
  }).toList();

  int scoreVideo(Json f) {
    final h = _hauteurFormat(f);
    final fps = ((f['fps'] ?? 0) as num).toInt();
    final vc = '${f['vcodec'] ?? ''}'.toLowerCase();
    final ext = '${f['ext'] ?? ''}'.toLowerCase();
    final vbr = ((f['vbr'] ?? f['tbr'] ?? 0) as num).toInt();
    final h264 = videoPubliable(f['vcodec'] as String?);
    var s = 0;
    if (compatible) {
      if (h264) s += 100000000;
      if (ext == 'mp4') s += 10000;
    } else if (conteneur == 'mp4' && (ext == 'mp4' || h264 || vc.startsWith('av01'))) {
      s += (ext == 'mp4' ? 20000 : 0) + (h264 ? 5000 : 0);
    } else if (conteneur == 'webm' && (ext == 'webm' || vc.startsWith('vp'))) {
      s += 20000;
    }
    return s + h * 100000 + fps * 100 + (vbr ~/ 10);
  }

  if (videos.isNotEmpty && audioPrincipal != null) {
    videos.sort((a, b) => scoreVideo(b).compareTo(scoreVideo(a)));
    final v = videos.first;
    final audioVo = deuxPistes && originale != null && piste != null && originale != piste ? choisirAudio(originale) : null;
    final choisis = [v, audioPrincipal, if (audioVo != null && audioVo['format_id'] != audioPrincipal['format_id']) audioVo];
    return depuisListe(choisis);
  }

  // Repli : flux déjà multiplexé (ex. format 18 en secours mobile ou vidéo sans flux séparés)
  final muxes = pool.where((f) => estVideo(f) && !_aucun(f['acodec'])).where((f) {
    final h = _hauteurFormat(f);
    return maxH == null || h == 0 || h <= maxH;
  }).toList();
  if (muxes.isNotEmpty) {
    muxes.sort((a, b) => scoreVideo(b).compareTo(scoreVideo(a)));
    return depuisListe([muxes.first]);
  }
  return null;
}
