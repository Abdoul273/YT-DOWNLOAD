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
  if (conteneur == 'mp4') return ['res', 'fps', 'ext:mp4:m4a'];
  if (conteneur == 'webm') return ['res', 'fps', 'ext:webm:webm'];
  return ['res', 'fps'];
}

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
