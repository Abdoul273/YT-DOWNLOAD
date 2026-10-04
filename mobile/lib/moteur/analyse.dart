/// Récupération des infos (vidéo, playlist, chaîne, recherche) via yt-dlp -J.
/// Portage de nexus/analyse.py.
library;

import 'dart:convert';

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
  final String? id, url, miniature, chaine, chaineId;
  final String titre;
  final int? duree, vues, date;
  final bool direct;
  Entree(this.id, this.titre, this.url, this.duree, this.miniature, this.chaine, this.vues, this.date, this.direct,
      {this.chaineId});

  Json versJson() => {
        'id': id, 'titre': titre, 'url': url, 'duree': duree, 'miniature': miniature, 'chaine': chaine,
        'vues': vues, 'date': date, 'direct': direct, 'chaine_id': chaineId,
      };
  factory Entree.depuis(Map d) => Entree(d['id'], d['titre'] ?? 'Sans titre', d['url'], d['duree'], d['miniature'],
      d['chaine'], d['vues'], d['date'], d['direct'] == true,
      chaineId: d['chaine_id']);
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

/// Flux lisible directement pour l'aperçu : un format vidéo+audio (≤ 720p),
/// sinon le manifeste HLS. Renvoie null si rien n'est lisible sans fusion.
({String url, Map<String, String> entetes, bool hls})? sourceApercu(Json info) {
  final formats = ((info['formats'] as List?) ?? []).whereType<Map>().where((f) => f['url'] is String).toList();
  bool avecSon(Map f) => f['acodec'] != null && f['acodec'] != 'none';
  bool avecImage(Map f) => f['vcodec'] != null && f['vcodec'] != 'none';
  int hauteur(Map f) => ((f['height'] ?? 0) as num).toInt();
  Map<String, String> entetes(Map f) =>
      ((f['http_headers'] ?? info['http_headers'] ?? {}) as Map).map((k, v) => MapEntry('$k', '$v'));

  for (final hls in [false, true]) {
    final muxes = formats
        .where((f) => avecSon(f) && avecImage(f) && hauteur(f) <= 720)
        .where((f) => '${f['protocol']}'.startsWith('m3u8') == hls && !'${f['protocol']}'.contains('dash'))
        .toList()
      ..sort((a, b) => hauteur(b).compareTo(hauteur(a)));
    if (muxes.isNotEmpty) {
      final f = muxes.first;
      return (url: (hls ? (f['manifest_url'] ?? f['url']) : f['url']) as String, entetes: entetes(f), hls: hls);
    }
  }
  if (info['manifest_url'] is String && '${info['manifest_url']}'.contains('m3u8')) {
    return (url: info['manifest_url'] as String, entetes: entetes(info), hls: true);
  }
  return null;
}
