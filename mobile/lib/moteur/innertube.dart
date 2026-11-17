/// Client YouTube Innertube direct (rapide et sans vérification anti-robot).
///
/// Interroge directement les endpoints `/youtubei/v1/*` en HTTP/gzip avec un
/// `visitorData` frais et les clients mobiles/iOS/visionOS pour éviter :
/// - l'attente Python + QuickJS (10 à 30 s) à chaque analyse, recherche, chaîne ou playlist ;
/// - les blocages « Sign in to confirm you're not a bot » des clients web/TV sans cookies.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef Json = Map<String, dynamic>;

const _uaVisionOs =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const _uaWeb =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
const _uaAndroid = 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
const _uaIos = 'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X)';

Json _ctxVisionOs([String? visitor]) => {
      'client': {
        'clientName': 'VISIONOS',
        'clientVersion': '1.02',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
        'deviceModel': 'RealityDevice17,1',
        'hl': 'fr',
        'gl': 'FR',
        'visitorData': ?visitor,
      },
    };

Json _ctxWeb([String? visitor]) => {
      'client': {
        'clientName': 'WEB',
        'clientVersion': '2.20260708.00.00',
        'hl': 'fr',
        'gl': 'FR',
        'visitorData': ?visitor,
      },
    };

Json _ctxAndroid([String? visitor]) => {
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'androidSdkVersion': 30,
        'userAgent': _uaAndroid,
        'hl': 'fr',
        'gl': 'FR',
        'visitorData': ?visitor,
      },
    };

Json _ctxIos([String? visitor]) => {
      'client': {
        'clientName': 'IOS',
        'clientVersion': '21.26.4',
        'deviceMake': 'Apple',
        'deviceModel': 'iPhone16,2',
        'osName': 'iPhone',
        'osVersion': '18.5.22F76',
        'userAgent': _uaIos,
        'hl': 'fr',
        'gl': 'FR',
        'visitorData': ?visitor,
      },
    };

/// Surcharge d'origine pour les tests unitaires avec serveur HTTP local.
@visibleForTesting
Uri? baseUriTest;

/// Permet aux tests d'injecter un client HTTP ou de réinitialiser le cache visiteur.
@visibleForTesting
void reinitialiserEtatTest() {
  _visitorData = null;
  _visitorMaj = null;
  _visitorEnCours = null;
}

bool get disponible => baseUriTest != null || !Platform.environment.containsKey('FLUTTER_TEST');

HttpClient? _clientHttp;
HttpClient _http() => _clientHttp ??= (HttpClient()
  ..autoUncompress = true
  ..connectionTimeout = const Duration(seconds: 8)
  ..idleTimeout = const Duration(seconds: 15));

String? _visitorData;
DateTime? _visitorMaj;
Future<String?>? _visitorEnCours;
const _dureeVisiteur = Duration(minutes: 20);

Future<Json> _post(
  String chemin,
  Json corps, {
  Map<String, String> entetes = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  final base = baseUriTest ?? Uri.https('www.youtube.com');
  final uri = base.replace(path: chemin, queryParameters: {'prettyPrint': 'false'});
  final req = await _http().postUrl(uri).timeout(timeout);
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
  req.headers.set('Origin', 'https://www.youtube.com');
  req.headers.set('Referer', 'https://www.youtube.com/');
  req.headers.set(HttpHeaders.acceptLanguageHeader, 'fr-FR,fr;q=0.9,en;q=0.8');
  for (final e in entetes.entries) {
    req.headers.set(e.key, e.value);
  }
  req.add(utf8.encode(jsonEncode(corps)));
  final rep = await req.close().timeout(timeout);
  final texte = await utf8.decodeStream(rep).timeout(timeout);
  if (rep.statusCode >= 400) {
    throw HttpException('Innertube HTTP ${rep.statusCode}', uri: uri);
  }
  final decode = jsonDecode(texte);
  return decode is Map ? decode.cast<String, dynamic>() : <String, dynamic>{};
}

/// Obtient et met en cache un `visitorData` frais auprès d'Innertube.
Future<String?> visitorData({bool forcer = false}) async {
  if (!disponible) return null;
  if (!forcer &&
      _visitorData != null &&
      _visitorMaj != null &&
      DateTime.now().difference(_visitorMaj!) < _dureeVisiteur) {
    return _visitorData;
  }
  if (!forcer && _visitorEnCours != null) return _visitorEnCours;
  final futur = () async {
    try {
      final r = await _post(
        '/youtubei/v1/visitor_id',
        {'context': _ctxVisionOs()},
        entetes: {'User-Agent': _uaVisionOs},
        timeout: const Duration(seconds: 6),
      );
      final rc = r['responseContext'];
      final v = (rc is Map ? rc['visitorData'] : null) ?? r['visitorData'];
      if (v is String && v.isNotEmpty) {
        _visitorData = v;
        _visitorMaj = DateTime.now();
        return v;
      }
    } catch (_) {}
    return _visitorData;
  }();
  _visitorEnCours = futur;
  try {
    return await futur;
  } finally {
    if (identical(_visitorEnCours, futur)) _visitorEnCours = null;
  }
}

/// Préchauffe le `visitorData` en arrière-plan pour accélérer la première analyse.
void prechauffer() {
  if (disponible) unawaited(visitorData());
}

// ---------------------------------------------------------------------------
// Détection d'URL YouTube
// ---------------------------------------------------------------------------

final _regIdYoutube = RegExp(r'^[A-Za-z0-9_-]{11}$');

bool estHoteYoutube(String url) {
  final h = Uri.tryParse(url)?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ?? '';
  return h == 'youtube.com' ||
      h == 'm.youtube.com' ||
      h == 'music.youtube.com' ||
      h == 'youtube-nocookie.com' ||
      h == 'youtu.be';
}

String? extraireIdVideo(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return null;
  final h = u.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  String? candidat;
  if (h == 'youtu.be') {
    candidat = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
  } else if (h == 'youtube.com' || h == 'm.youtube.com' || h == 'music.youtube.com' || h == 'youtube-nocookie.com') {
    final segs = u.pathSegments;
    if (u.path == '/watch' || u.path == '/watch/') {
      candidat = u.queryParameters['v'];
    } else if (segs.length >= 2 && const {'shorts', 'live', 'embed', 'v'}.contains(segs.first)) {
      candidat = segs[1];
    }
  }
  return candidat != null && _regIdYoutube.hasMatch(candidat) ? candidat : null;
}

String? extrairePlaylistId(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !estHoteYoutube(url)) return null;
  final list = u.queryParameters['list'];
  return list != null && list.isNotEmpty ? list : null;
}

bool estChaineYoutube(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !estHoteYoutube(url)) return false;
  return RegExp(r'^/(@[^/]+|channel/[^/]+|c/[^/]+|user/[^/]+)(/(videos|shorts|streams|playlists|featured|live))?/?$')
      .hasMatch(u.path);
}

// ---------------------------------------------------------------------------
// Modèles et résultat d'extraction vidéo
// ---------------------------------------------------------------------------

class ResultatExtraction {
  final Json? info;
  final String? statut;
  final String? raison;
  final bool estBloqueRobot;
  final bool estAge;
  final bool estPourEnfants;
  final bool estPriveOuIndispo;

  const ResultatExtraction({
    this.info,
    this.statut,
    this.raison,
    this.estBloqueRobot = false,
    this.estAge = false,
    this.estPourEnfants = false,
    this.estPriveOuIndispo = false,
  });

  bool get ok => info != null;
}

ResultatExtraction _classerEchecPlayer(Json player) {
  final ps = (player['playabilityStatus'] as Map?)?.cast<String, dynamic>() ?? const {};
  final statut = '${ps['status'] ?? 'UNKNOWN'}';
  final raison = '${ps['reason'] ?? ''}'.trim();
  final r = raison.toLowerCase();
  final pc = player['playerConfig'] is Map ? jsonEncode(player['playerConfig']).toLowerCase() : '';
  final estAge = r.contains('age') || r.contains('âge') || r.contains('inappropriate') || statut == 'AGE_VERIFICATION_REQUIRED';
  final estRobot = !estAge &&
      (r.contains('not a bot') ||
          r.contains('robot') ||
          r.contains('confirm you') ||
          (statut == 'LOGIN_REQUIRED' && !r.contains('private') && !r.contains('privée')));
  final estEnfants = r.contains('kids') || r.contains('enfants') || pc.contains('forkids');
  final estPrive = r.contains('private') || r.contains('privée') || r.contains('unavailable') || r.contains('indisponible') || statut == 'ERROR';
  return ResultatExtraction(
    statut: statut,
    raison: raison,
    estBloqueRobot: estRobot,
    estAge: estAge,
    estPourEnfants: estEnfants,
    estPriveOuIndispo: estPrive,
  );
}

Future<Json> _appelPlayer(
  String videoId,
  Json ctx,
  Map<String, String> entetes, {
  Duration timeout = const Duration(seconds: 9),
}) {
  return _post(
    '/youtubei/v1/player',
    {
      'context': ctx,
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    },
    entetes: entetes,
    timeout: timeout,
  );
}

Future<Json?> _appelNext(String videoId, {String? playlistId, String? visitor, Duration timeout = const Duration(seconds: 3)}) async {
  try {
    return await _post(
      '/youtubei/v1/next',
      {
        'context': _ctxWeb(visitor),
        'videoId': videoId,
        'playlistId': ?playlistId,
      },
      entetes: {
        'User-Agent': _uaWeb,
        'X-Goog-Visitor-Id': ?visitor,
      },
      timeout: timeout,
    );
  } catch (_) {
    return null;
  }
}

/// Extrait une vidéo YouTube via `VISIONOS` + `visitorData` (et enrichit chapitres/date via `/next` en parallèle).
/// En dernier recours (si `autoriserSecoursMobile == true`), interroge `IOS` (HLS) et `ANDROID` (MP4 360p).
Future<ResultatExtraction> extraireVideo(String videoId, {bool autoriserSecoursMobile = false}) async {
  if (!disponible) return const ResultatExtraction();
  var vis = await visitorData();
  final nextFut = _appelNext(videoId, visitor: vis, timeout: const Duration(milliseconds: 2800));

  Future<Json> tenterVision(String? v) => _appelPlayer(
        videoId,
        _ctxVisionOs(v),
        {
          'User-Agent': _uaVisionOs,
          'X-Goog-Visitor-Id': ?v,
        },
      );

  Json player;
  try {
    player = await tenterVision(vis);
  } catch (e) {
    if (!autoriserSecoursMobile) return ResultatExtraction(raison: '$e');
    player = const {};
  }

  var echec = _classerEchecPlayer(player);
  if (player['playabilityStatus']?['status'] != 'OK' && echec.estBloqueRobot) {
    final nouveauVis = await visitorData(forcer: true);
    if (nouveauVis != null && nouveauVis != vis) {
      vis = nouveauVis;
      try {
        player = await tenterVision(vis);
      } catch (_) {}
      echec = _classerEchecPlayer(player);
    }
  }

  if (player['playabilityStatus']?['status'] == 'OK') {
    final next = await nextFut;
    final info = construireInfoDepuisPlayer(
      player,
      urlOrigine: 'https://www.youtube.com/watch?v=$videoId',
      uaClient: _uaVisionOs,
      nomClient: 'VISIONOS',
      nextData: next,
    );
    if (((info['formats'] as List?) ?? []).isNotEmpty) {
      return ResultatExtraction(info: info, statut: 'OK');
    }
  }

  if (autoriserSecoursMobile) {
    final secours = await extraireSecoursMobile(videoId, nextData: await nextFut, visitor: vis);
    if (secours != null) return ResultatExtraction(info: secours, statut: 'OK');
  }

  return echec;
}

/// Secours mobile direct (`ANDROID 20.10.38` + `IOS 21.26.4`) pour aperçu HLS et flux progressif sans cookies.
Future<Json?> extraireSecoursMobile(String videoId, {Json? nextData, String? visitor}) async {
  if (!disponible) return null;
  final vis = visitor ?? await visitorData();
  final nextFut = nextData != null ? Future.value(nextData) : _appelNext(videoId, visitor: vis);
  final iosFut = _appelPlayer(
    videoId,
    _ctxIos(vis),
    {'User-Agent': _uaIos, 'X-Goog-Visitor-Id': ?vis},
    timeout: const Duration(seconds: 7),
  ).then<Json?>((v) => v).catchError((_) => null);
  final androidFut = _appelPlayer(
    videoId,
    _ctxAndroid(vis),
    {'User-Agent': _uaAndroid, 'X-Goog-Visitor-Id': ?vis},
    timeout: const Duration(seconds: 7),
  ).then<Json?>((v) => v).catchError((_) => null);

  final results = await Future.wait([iosFut, androidFut, nextFut]);
  final ios = results[0];
  final android = results[1];
  final next = results[2];

  // Préférence à iOS s'il expose hlsManifestUrl + formats, ou Android pour format progressif 18
  final base = (android?['playabilityStatus']?['status'] == 'OK' ? android : null) ??
      (ios?['playabilityStatus']?['status'] == 'OK' ? ios : null);
  if (base == null) return null;

  final clientNom = identical(base, android) ? 'ANDROID' : 'IOS';
  final ua = identical(base, android) ? _uaAndroid : _uaIos;
  final info = construireInfoDepuisPlayer(
    base,
    urlOrigine: 'https://www.youtube.com/watch?v=$videoId',
    uaClient: ua,
    nomClient: clientNom,
    nextData: next,
    progressifsSeulementPourAdaptatifAndroid: identical(base, android),
  );
  // Fusionne le manifeste HLS iOS s'il manque côté Android
  final hlsIos = ios?['streamingData']?['hlsManifestUrl'];
  if (hlsIos is String && hlsIos.isNotEmpty && info['manifest_url'] == null) {
    info['manifest_url'] = hlsIos;
    final fmts = (info['formats'] as List).cast<Json>();
    fmts.add({
      'format_id': 'hls-ios',
      'url': hlsIos,
      'manifest_url': hlsIos,
      'protocol': 'm3u8_native',
      'ext': 'mp4',
      'vcodec': 'avc1',
      'acodec': 'mp4a.40.2',
      'http_headers': {'User-Agent': _uaIos},
    });
  }
  return ((info['formats'] as List?) ?? []).isEmpty ? null : info;
}

// ---------------------------------------------------------------------------
// Construction du info_dict compatible yt-dlp depuis /player (+ /next)
// ---------------------------------------------------------------------------

({String? vcodec, String? acodec, String ext, bool estAudio, bool estVideo}) _parserMime(String? mime) {
  final brute = mime ?? '';
  final estAudio = brute.startsWith('audio/');
  final estVideo = brute.startsWith('video/');
  final sousType = brute.split(';').first.split('/').last.trim().toLowerCase();
  var ext = switch (sousType) {
    'mp4' => estAudio ? 'm4a' : 'mp4',
    'webm' => 'webm',
    '3gpp' => '3gp',
    _ => estAudio ? 'm4a' : 'mp4',
  };
  String? vcodec;
  String? acodec;
  final m = RegExp(r'codecs="([^"]+)"').firstMatch(brute);
  if (m != null) {
    final parts = m.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (estAudio) {
      acodec = parts.isNotEmpty ? parts.first : null;
      vcodec = 'none';
    } else if (parts.length >= 2) {
      vcodec = parts[0];
      acodec = parts[1];
    } else if (parts.length == 1) {
      vcodec = parts[0];
      acodec = 'none';
    }
  } else {
    if (estAudio) {
      vcodec = 'none';
      acodec = ext == 'webm' ? 'opus' : 'mp4a.40.2';
    } else {
      vcodec = ext == 'webm' ? 'vp9' : 'avc1';
      acodec = 'none';
    }
  }
  return (vcodec: vcodec, acodec: acodec, ext: ext, estAudio: estAudio, estVideo: estVideo);
}

String _dynamicRange(Json f) {
  final label = '${f['qualityLabel'] ?? ''}'.toUpperCase();
  if (label.contains('HDR')) return 'HDR10';
  final tc = '${(f['colorInfo'] as Map?)?['transferCharacteristics'] ?? ''}';
  if (tc.contains('SMPTEST2084') || tc.contains('ARIB_STD_B67')) return 'HDR10';
  return 'SDR';
}

@visibleForTesting
Json construireInfoDepuisPlayer(
  Json player, {
  required String urlOrigine,
  String uaClient = _uaVisionOs,
  String nomClient = 'VISIONOS',
  Json? nextData,
  bool progressifsSeulementPourAdaptatifAndroid = false,
}) {
  final vd = (player['videoDetails'] as Map?)?.cast<String, dynamic>() ?? const {};
  final mf = ((player['microformat'] as Map?)?['playerMicroformatRenderer'] as Map?)?.cast<String, dynamic>() ?? const {};
  final sd = (player['streamingData'] as Map?)?.cast<String, dynamic>() ?? const {};
  final id = '${vd['videoId'] ?? extraireIdVideo(urlOrigine) ?? ''}';
  final entetes = {'User-Agent': uaClient};

  // Formats
  final formatsOut = <Json>[];
  final vusIds = <String>{};

  void ajouterFormat(Json f, {required bool muxed}) {
    final url = f['url'];
    if (url is! String || url.isEmpty) return;
    final mime = _parserMime(f['mimeType'] as String?);
    if (progressifsSeulementPourAdaptatifAndroid && !muxed) {
      // Sur Android 20 sans PO Token, les adaptatifs (>7 Mo) font 403 : garder seulement < 6 Mo (courts clips) + muxé 18.
      final len = int.tryParse('${f['contentLength'] ?? ''}') ?? 0;
      if (len > 6 * 1024 * 1024) return;
    }
    final itag = '${f['itag'] ?? ''}';
    final at = (f['audioTrack'] as Map?)?.cast<String, dynamic>();
    final trackId = at?['id'] as String?;
    final displayName = (at?['displayName'] as String?) ?? '';
    final isDrc = f['isDrc'] == true;
    final lang = trackId != null && trackId.contains('.') ? trackId.split('.').first : trackId;
    final isDefaultTrack = at?['audioIsDefault'] == true || displayName.toLowerCase().contains('original');
    final isAutoDub = displayName.toLowerCase().contains('auto') || (trackId?.endsWith('.7') ?? false);

    var fmtId = itag.isEmpty ? 'fmt-${formatsOut.length}' : itag;
    if (isDrc) fmtId += '-drc';
    if (trackId != null && trackId.isNotEmpty) fmtId += '-$trackId';
    if (!vusIds.add(fmtId)) fmtId = '$fmtId-${formatsOut.length}';

    final bitrate = ((f['bitrate'] ?? f['averageBitrate'] ?? 0) as num).toDouble();
    final kbps = bitrate > 0 ? bitrate / 1000.0 : null;
    final filesize = int.tryParse('${f['contentLength'] ?? ''}');
    String note = '${f['qualityLabel'] ?? ''}';
    if (mime.estAudio && at != null) {
      note = isDefaultTrack ? 'original' : (isAutoDub ? 'dubbed-auto' : 'dubbed');
      if (isDrc) note += ', DRC';
    } else if (isDrc) {
      note = note.isEmpty ? 'DRC' : '$note, DRC';
    }

    formatsOut.add({
      'format_id': fmtId,
      'url': url,
      'ext': mime.ext,
      'protocol': 'https',
      'vcodec': mime.vcodec ?? 'none',
      'acodec': mime.acodec ?? 'none',
      if (f['width'] != null) 'width': (f['width'] as num).toInt(),
      if (f['height'] != null) 'height': (f['height'] as num).toInt(),
      if (f['fps'] != null) 'fps': (f['fps'] as num).toInt(),
      if (filesize != null && filesize > 0) 'filesize': filesize,
      if (kbps != null) 'tbr': double.parse(kbps.toStringAsFixed(1)),
      if (mime.estAudio && kbps != null) 'abr': double.parse(kbps.toStringAsFixed(1)),
      if (mime.estVideo && kbps != null) 'vbr': double.parse(kbps.toStringAsFixed(1)),
      if (f['audioSampleRate'] != null) 'asr': int.tryParse('${f['audioSampleRate']}'),
      if (f['audioChannels'] != null) 'audio_channels': (f['audioChannels'] as num).toInt(),
      if (lang != null && lang.isNotEmpty) 'language': lang,
      if (at != null) 'language_preference': isDefaultTrack ? 10 : -1,
      if (note.isNotEmpty) 'format_note': note,
      if (mime.estVideo) 'dynamic_range': _dynamicRange(f),
      if (isDrc) 'preference': -1,
      'http_headers': entetes,
    });
  }

  for (final f in ((sd['formats'] as List?) ?? []).whereType<Map>()) {
    ajouterFormat(f.cast<String, dynamic>(), muxed: true);
  }
  for (final f in ((sd['adaptiveFormats'] as List?) ?? []).whereType<Map>()) {
    ajouterFormat(f.cast<String, dynamic>(), muxed: false);
  }

  final hls = sd['hlsManifestUrl'] as String?;

  // Sous-titres manuels + automatiques (+ traductions utiles)
  final caps = ((player['captions'] as Map?)?['playerCaptionsTracklistRenderer'] as Map?)?.cast<String, dynamic>() ?? const {};
  final subtitles = <String, List<Json>>{};
  final autoCaptions = <String, List<Json>>{};
  const languesAutoUtiles = {'fr', 'en', 'es', 'de', 'ar', 'pt', 'it', 'ja', 'ko', 'nl', 'ru', 'zh-Hans'};

  List<Json> entreeCaption(String baseUrl, String? name) {
    final sep = baseUrl.contains('?') ? '&' : '?';
    return [
      {'ext': 'vtt', 'url': '$baseUrl${sep}fmt=vtt', 'name': ?name},
      {'ext': 'srt', 'url': '$baseUrl${sep}fmt=srt', 'name': ?name},
      {'ext': 'srv3', 'url': '$baseUrl${sep}fmt=srv3', 'name': ?name},
    ];
  }

  String? baseUrlOrigPourTrad;
  for (final t in ((caps['captionTracks'] as List?) ?? []).whereType<Map>()) {
    final baseUrl = t['baseUrl'] as String?;
    final lang = t['languageCode'] as String?;
    if (baseUrl == null || lang == null || lang.isEmpty) continue;
    final vss = '${t['vssId'] ?? ''}';
    final estAsr = t['kind'] == 'asr' || vss.startsWith('a.');
    final nom = _texteRuns(t['name']);
    if (estAsr) {
      autoCaptions['$lang-orig'] = entreeCaption(baseUrl, nom);
      autoCaptions.putIfAbsent(lang, () => entreeCaption(baseUrl, nom));
      baseUrlOrigPourTrad ??= t['isTranslatable'] == true ? baseUrl : null;
    } else {
      subtitles[lang] = entreeCaption(baseUrl, nom);
      if (t['isTranslatable'] == true) baseUrlOrigPourTrad ??= baseUrl;
    }
  }
  if (baseUrlOrigPourTrad != null) {
    final trads = ((caps['translationLanguages'] as List?) ?? []).whereType<Map>();
    final dispo = {
      for (final tr in trads)
        if (tr['languageCode'] is String) tr['languageCode'] as String: _texteRuns(tr['languageName']),
    };
    for (final code in languesAutoUtiles) {
      if (!autoCaptions.containsKey(code) && dispo.containsKey(code)) {
        final sep = baseUrlOrigPourTrad.contains('?') ? '&' : '?';
        autoCaptions[code] = entreeCaption('$baseUrlOrigPourTrad${sep}tlang=$code', dispo[code]);
      }
    }
  }

  // Enrichissements depuis /next et microformat
  final description = (vd['shortDescription'] ?? mf['description']?['simpleText'] ?? '') as String;
  final chapitresNext = nextData != null ? _extraireChapitresNext(nextData) : const <Json>[];
  final dureeSec = int.tryParse('${vd['lengthSeconds'] ?? mf['lengthSeconds'] ?? ''}') ?? 0;
  final chapitres = chapitresNext.isNotEmpty
      ? chapitresNext
      : _extraireChapitresDescription(description, dureeSec);

  final infoNext = nextData != null ? _extraireMetaNext(nextData) : (dateUpload: null, chaineUrl: null, abonnes: null);
  var uploadDate = _formaterUploadDate(mf['publishDate'] as String? ?? mf['uploadDate'] as String?);
  uploadDate ??= infoNext.dateUpload;

  final channelId = (vd['channelId'] ?? mf['externalChannelId']) as String?;
  final chaineUrl = (mf['ownerProfileUrl'] as String?) ??
      infoNext.chaineUrl ??
      (channelId != null && channelId.isNotEmpty ? 'https://www.youtube.com/channel/$channelId' : null);

  final thumbs = ((vd['thumbnail'] as Map?)?['thumbnails'] as List?)
          ?.whereType<Map>()
          .map((t) => t.cast<String, dynamic>())
          .toList() ??
      const <Json>[];
  final thumbUrl = id.isNotEmpty
      ? 'https://i.ytimg.com/vi/$id/hqdefault.jpg'
      : (thumbs.isNotEmpty ? thumbs.last['url'] as String? : null);

  final isLive = vd['isLive'] == true || mf['liveBroadcastDetails']?['isLiveNow'] == true;
  final ageRating = player['playerConfig']?['mediaCommonConfig']?['mediaUstreamerRequestConfig'] != null &&
      '${player['playabilityStatus']?['desktopLegacyAgeGateReason'] ?? ''}' == '1';

  return {
    'id': id,
    'webpage_url': id.isNotEmpty ? 'https://www.youtube.com/watch?v=$id' : urlOrigine,
    'original_url': urlOrigine,
    'extractor': 'youtube',
    'extractor_key': 'Youtube',
    'ie_key': 'Youtube',
    'title': (vd['title'] ?? mf['title']?['simpleText'] ?? 'Sans titre') as String,
    'description': description,
    'channel': (vd['author'] ?? mf['ownerChannelName']) as String?,
    'uploader': (vd['author'] ?? mf['ownerChannelName']) as String?,
    if (channelId != null && channelId.isNotEmpty) 'channel_id': channelId,
    if (chaineUrl != null && chaineUrl.isNotEmpty) 'channel_url': chaineUrl,
    if (chaineUrl != null && chaineUrl.isNotEmpty) 'uploader_url': chaineUrl,
    if (dureeSec > 0) 'duration': dureeSec,
    'view_count': ?int.tryParse('${vd['viewCount'] ?? mf['viewCount'] ?? ''}'),
    if (infoNext.abonnes != null) 'channel_follower_count': infoNext.abonnes,
    'upload_date': ?uploadDate,
    'live_status': isLive ? 'is_live' : 'not_live',
    'age_limit': ageRating ? 18 : 0,
    'thumbnail': ?thumbUrl,
    if (thumbs.isNotEmpty) 'thumbnails': thumbs,
    'formats': formatsOut,
    if (hls != null && hls.isNotEmpty) 'manifest_url': hls,
    'subtitles': subtitles,
    'automatic_captions': autoCaptions,
    if (chapitres.isNotEmpty) 'chapters': chapitres,
    'http_headers': entetes,
    '_source_client': nomClient,
  };
}

// ---------------------------------------------------------------------------
// Recherche, Playlists, Mixes et Chaînes via Innertube (/search, /browse, /next)
// ---------------------------------------------------------------------------

/// Recherche YouTube rapide via `/youtubei/v1/search`.
Future<List<Json>> rechercher(String requete, {String? sp, int max = 30}) async {
  if (!disponible) return const [];
  final vis = await visitorData();
  final corps = <String, dynamic>{
    'context': _ctxWeb(vis),
    'query': requete,
    if (sp != null && sp.isNotEmpty) 'params': sp,
  };
  var data = await _post(
    '/youtubei/v1/search',
    corps,
    entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
  );
  final out = <Json>[];
  final vus = <String>{};
  void collecter(Json racine) {
    for (final v in _trouverTous(racine, 'videoRenderer')) {
      final e = _entreeDepuisVideoRenderer(v);
      if (e != null && vus.add(e['id'] as String)) {
        out.add(e);
        if (out.length >= max) return;
      }
    }
    if (out.length < max) {
      for (final l in _trouverTous(racine, 'lockupViewModel')) {
        if (l['contentType'] == 'LOCKUP_CONTENT_TYPE_VIDEO') {
          final e = _entreeDepuisLockup(l);
          if (e != null && vus.add(e['id'] as String)) {
            out.add(e);
            if (out.length >= max) return;
          }
        }
      }
    }
  }

  collecter(data);
  var pages = 0;
  while (out.length < max && pages < 2) {
    final token = _premierTokenContinuation(data);
    if (token == null) break;
    pages++;
    try {
      data = await _post(
        '/youtubei/v1/search',
        {'context': _ctxWeb(vis), 'continuation': token},
        entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
        timeout: const Duration(seconds: 7),
      );
      final avant = out.length;
      collecter(data);
      if (out.length == avant) break;
    } catch (_) {
      break;
    }
  }
  return out;
}

/// Mix ou file de lecture (`RD...`, `UL...`) via `/youtubei/v1/next`.
Future<Json?> extraireMix(String videoId, String listId, {int max = 25}) async {
  if (!disponible) return null;
  final vis = await visitorData();
  final data = await _appelNext(videoId, playlistId: listId, visitor: vis, timeout: const Duration(seconds: 8));
  if (data == null) return null;
  final panneau = _trouverPremier(data, 'playlistPanelRenderer');
  final items = _trouverTous(panneau ?? data, 'playlistPanelVideoRenderer');
  final entrees = <Json>[];
  final vus = <String>{};
  for (final it in items) {
    final vid = it['videoId'] as String?;
    if (vid == null || vid.isEmpty || !vus.add(vid)) continue;
    final runChaine = ((it['longBylineText'] ?? it['shortBylineText'])?['runs'] as List?)?.firstOrNull;
    final epChaine = runChaine is Map ? (runChaine['navigationEndpoint']?['browseEndpoint']) : null;
    final chId = epChaine is Map ? epChaine['browseId'] as String? : null;
    final chCanon = epChaine is Map ? epChaine['canonicalBaseUrl'] as String? : null;
    entrees.add({
      'id': vid,
      'ie_key': 'Youtube',
      'title': _texteRuns(it['title']) ?? 'Sans titre',
      'url': 'https://www.youtube.com/watch?v=$vid',
      'duration': parseDuree(_texteRuns(it['lengthText'])),
      'channel': _texteRuns(it['longBylineText'] ?? it['shortBylineText']),
      'channel_id': ?chId,
      if (chCanon != null) 'channel_url': 'https://www.youtube.com$chCanon',
      'live_status': _estBadgeLive(it) ? 'is_live' : 'not_live',
    });
    if (entrees.length >= max) break;
  }
  if (entrees.isEmpty) return null;
  return {
    '_type': 'playlist',
    'id': listId,
    'title': (panneau?['title'] as String?) ?? 'Mix',
    'entries': entrees,
  };
}

/// Playlist publique YouTube (`PL...`, `OL...`, `LL...`) via `/youtubei/v1/browse` (`VL$listId`).
Future<Json?> extrairePlaylist(String listId, {int max = 50}) async {
  if (!disponible) return null;
  final vis = await visitorData();
  final browseId = listId.startsWith('VL') ? listId : 'VL$listId';
  var data = await _post(
    '/youtubei/v1/browse',
    {'context': _ctxWeb(vis), 'browseId': browseId},
    entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
  );
  final entrees = <Json>[];
  final vus = <String>{};

  void collecter(Json racine) {
    for (final pvr in _trouverTous(racine, 'playlistVideoRenderer')) {
      final vid = pvr['videoId'] as String?;
      if (vid == null || vid.isEmpty || !vus.add(vid)) continue;
      final runs = ((pvr['shortBylineText'] as Map?)?['runs'] as List?) ?? const [];
      final firstRun = runs.firstOrNull;
      final epCh = firstRun is Map ? (firstRun['navigationEndpoint']?['browseEndpoint']) : null;
      final vinfo = _texteRuns(pvr['videoInfo']);
      entrees.add({
        'id': vid,
        'ie_key': 'Youtube',
        'title': _texteRuns(pvr['title']) ?? 'Sans titre',
        'url': 'https://www.youtube.com/watch?v=$vid',
        'duration': int.tryParse('${pvr['lengthSeconds'] ?? ''}') ?? parseDuree(_texteRuns(pvr['lengthText'])),
        'channel': _texteRuns(pvr['shortBylineText']),
        if (epCh is Map && epCh['browseId'] != null) 'channel_id': epCh['browseId'],
        if (epCh is Map && epCh['canonicalBaseUrl'] != null) 'channel_url': 'https://www.youtube.com${epCh['canonicalBaseUrl']}',
        if (vinfo != null) ..._extraireVuesEtDateTexte(vinfo),
      });
      if (entrees.length >= max) return;
    }
    if (entrees.length < max) {
      for (final lum in _trouverTous(racine, 'lockupViewModel')) {
        final e = _entreeDepuisLockup(lum);
        if (e != null && vus.add(e['id'] as String)) {
          entrees.add(e);
          if (entrees.length >= max) return;
        }
      }
    }
  }

  collecter(data);
  var pages = 0;
  while (entrees.length < max && pages < 3) {
    final token = _premierTokenContinuation(data);
    if (token == null) break;
    pages++;
    try {
      data = await _post(
        '/youtubei/v1/browse',
        {'context': _ctxWeb(vis), 'continuation': token},
        entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
        timeout: const Duration(seconds: 7),
      );
      final avant = entrees.length;
      collecter(data);
      if (entrees.length == avant) break;
    } catch (_) {
      break;
    }
  }

  final metaHeader = _extraireHeaderBrowse(data);
  if (entrees.isEmpty && metaHeader.titre == null) return null;
  return {
    '_type': 'playlist',
    'id': listId,
    'title': metaHeader.titre ?? 'Playlist',
    if (metaHeader.auteur != null) 'channel': metaHeader.auteur,
    if (metaHeader.avatar != null) 'thumbnail': metaHeader.avatar,
    'entries': entrees,
  };
}

/// Chaîne YouTube (`@handle`, `/channel/UC...`, `/videos`, `/shorts`, `/streams`) via Innertube.
Future<Json?> extraireChaine(String racineUrl, {String section = 'videos', int max = 30}) async {
  if (!disponible) return null;
  final vis = await visitorData();
  final cible = '${racineUrl.replaceFirst(RegExp(r'/+$'), '')}/$section';
  String? browseId;
  String? params;

  try {
    final res = await _post(
      '/youtubei/v1/navigation/resolve_url',
      {'context': _ctxWeb(vis), 'url': cible},
      entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
      timeout: const Duration(seconds: 6),
    );
    final ep = res['endpoint']?['browseEndpoint'];
    if (ep is Map) {
      browseId = ep['browseId'] as String?;
      params = ep['params'] as String?;
    }
  } catch (_) {}

  if (browseId == null || browseId.isEmpty) {
    final m = RegExp(r'/channel/(UC[A-Za-z0-9_-]+)').firstMatch(racineUrl);
    if (m == null) return null;
    browseId = m.group(1);
    params = switch (section) {
      'videos' => 'EgZ2aWRlb3PyBgQKAjoA',
      'shorts' => 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D',
      'streams' => 'EgdzdHJlYW1z8gYECgJ6AA%3D%3D',
      _ => null,
    };
  }

  var data = await _post(
    '/youtubei/v1/browse',
    {'context': _ctxWeb(vis), 'browseId': browseId, if (params != null && params.isNotEmpty) 'params': params},
    entetes: {'User-Agent': _uaWeb, 'X-Goog-Visitor-Id': ?vis},
  );
  final header = _extraireHeaderBrowse(data);
  final entrees = <Json>[];
  final vus = <String>{};

  void collecter(Json racine) {
    for (final s in _trouverTous(racine, 'shortsLockupViewModel')) {
      final e = _entreeDepuisShort(s, channel: header.titre, channelId: browseId, channelUrl: racineUrl);
      if (e != null && vus.add(e['id'] as String)) {
        entrees.add(e);
        if (entrees.length >= max) return;
      }
    }
    if (entrees.length < max) {
      for (final l in _trouverTous(racine, 'lockupViewModel')) {
        final e = _entreeDepuisLockup(l, channel: header.titre, channelId: browseId, channelUrl: racineUrl);
        if (e != null && vus.add(e['id'] as String)) {
          entrees.add(e);
          if (entrees.length >= max) return;
        }
      }
    }
    if (entrees.length < max) {
      for (final v in [..._trouverTous(racine, 'videoRenderer'), ..._trouverTous(racine, 'gridVideoRenderer')]) {
        final e = _entreeDepuisVideoRenderer(v, fallbackChannel: header.titre, fallbackChannelId: browseId, fallbackChannelUrl: racineUrl);
        if (e != null && vus.add(e['id'] as String)) {
          entrees.add(e);
          if (entrees.length >= max) return;
        }
      }
    }
  }

  collecter(data);
  if (entrees.isEmpty && header.titre == null) return null;

  return {
    '_type': 'playlist',
    'channel_id': browseId,
    if (header.titre != null) 'channel': header.titre,
    if (header.titre != null) 'title': header.titre,
    if (header.avatar != null) 'thumbnail': header.avatar,
    if (header.abonnes != null) 'channel_follower_count': header.abonnes,
    'entries': entrees,
  };
}

// ---------------------------------------------------------------------------
// Parseurs JSON et métadonnées (testés unitairement)
// ---------------------------------------------------------------------------

Json? _entreeDepuisVideoRenderer(
  Json vr, {
  String? fallbackChannel,
  String? fallbackChannelId,
  String? fallbackChannelUrl,
}) {
  final id = vr['videoId'] as String?;
  if (id == null || id.isEmpty) return null;
  final runs = ((vr['ownerText'] ?? vr['longBylineText'] ?? vr['shortBylineText'])?['runs'] as List?) ?? const [];
  final firstRun = runs.isNotEmpty && runs.first is Map ? runs.first as Map : null;
  final ep = firstRun?['navigationEndpoint']?['browseEndpoint'];
  final chNom = _texteRuns(vr['ownerText'] ?? vr['longBylineText'] ?? vr['shortBylineText']) ?? fallbackChannel;
  final chId = (ep is Map ? ep['browseId'] as String? : null) ?? fallbackChannelId;
  final chCanon = ep is Map ? ep['canonicalBaseUrl'] as String? : null;
  final chUrl = chCanon != null
      ? 'https://www.youtube.com$chCanon'
      : (chId != null ? 'https://www.youtube.com/channel/$chId' : fallbackChannelUrl);

  final live = _estBadgeLive(vr);
  final ts = parseDateRelative(_texteRuns(vr['publishedTimeText']));
  return {
    'id': id,
    'ie_key': 'Youtube',
    'title': _texteRuns(vr['title']) ?? 'Sans titre',
    'url': 'https://www.youtube.com/watch?v=$id',
    'duration': parseDuree(_texteRuns(vr['lengthText'])),
    'channel': ?chNom,
    'channel_id': ?chId,
    'channel_url': ?chUrl,
    'view_count': ?parseVues(_texteRuns(vr['viewCountText'] ?? vr['shortViewCountText'])),
    'timestamp': ?ts,
    'live_status': live ? 'is_live' : 'not_live',
  };
}

Json? _entreeDepuisLockup(Json lum, {String? channel, String? channelId, String? channelUrl}) {
  final id = lum['contentId'] as String?;
  if (id == null || !_regIdYoutube.hasMatch(id)) return null;
  final lmv = lum['lockupMetadataViewModel'] is Map
      ? lum['lockupMetadataViewModel'] as Map
      : (lum['metadata'] is Map ? lum['metadata']['lockupMetadataViewModel'] : null);
  final titre = lmv is Map ? '${lmv['title']?['content'] ?? ''}'.trim() : '';

  int? duree;
  var live = false;
  for (final b in _trouverTous(lum['contentImage'] ?? lum, 'thumbnailBadgeViewModel')) {
    final t = '${b['text'] ?? ''}'.trim();
    final bs = '${b['badgeStyle'] ?? ''}';
    if (bs.contains('LIVE') || t.toUpperCase() == 'EN DIRECT' || t.toUpperCase() == 'LIVE') {
      live = true;
    } else {
      duree ??= parseDuree(t);
    }
  }

  final textesMeta = <String>[];
  if (lmv is Map) {
    final rows = lmv['metadata']?['contentMetadataViewModel']?['metadataRows'];
    if (rows is List) {
      for (final row in rows.whereType<Map>()) {
        final parts = row['metadataParts'];
        if (parts is List) {
          for (final part in parts.whereType<Map>()) {
            final t = part['text']?['content'];
            if (t is String && t.trim().isNotEmpty) textesMeta.add(t.trim());
          }
        }
      }
    }
  }
  int? vues;
  int? ts;
  String? chDetectee;
  for (final txt in textesMeta) {
    final v = parseVues(txt);
    if (v != null && vues == null) {
      vues = v;
      continue;
    }
    final d = parseDateRelative(txt);
    if (d != null && ts == null) {
      ts = d;
      continue;
    }
    chDetectee ??= txt;
  }

  return {
    'id': id,
    'ie_key': 'Youtube',
    'title': titre.isEmpty ? 'Sans titre' : titre,
    'url': 'https://www.youtube.com/watch?v=$id',
    'duration': ?duree,
    if ((channel ?? chDetectee) != null) 'channel': channel ?? chDetectee,
    'channel_id': ?channelId,
    'channel_url': ?channelUrl,
    'view_count': ?vues,
    'timestamp': ?ts,
    'live_status': live ? 'is_live' : 'not_live',
  };
}

Json? _entreeDepuisShort(Json slum, {String? channel, String? channelId, String? channelUrl}) {
  final id = (slum['onTap']?['innertubeCommand']?['reelWatchEndpoint']?['videoId'] as String?) ??
      ('${slum['entityId'] ?? ''}'.startsWith('shorts-shelf-item-')
          ? '${slum['entityId']}'.substring('shorts-shelf-item-'.length)
          : null);
  if (id == null || !_regIdYoutube.hasMatch(id)) return null;
  final om = slum['overlayMetadata'];
  final titre = (om is Map ? (om['primaryText']?['content'] as String?) : null) ??
      (slum['accessibilityText'] as String?)?.split(',').first.trim() ??
      'Short';
  final vuesTxt = om is Map ? (om['secondaryText']?['content'] as String?) : null;
  final vues = parseVues(vuesTxt);
  return {
    'id': id,
    'ie_key': 'Youtube',
    'title': titre,
    'url': 'https://www.youtube.com/shorts/$id',
    'channel': ?channel,
    'channel_id': ?channelId,
    'channel_url': ?channelUrl,
    'view_count': ?vues,
    'live_status': 'not_live',
  };
}

({String? titre, String? auteur, String? avatar, int? abonnes}) _extraireHeaderBrowse(Json data) {
  final hdr = data['header'];
  if (hdr is! Map) return (titre: null, auteur: null, avatar: null, abonnes: null);
  final phr = hdr['pageHeaderRenderer'];
  if (phr is Map) {
    final titrePage = phr['pageTitle'] as String?;
    final phvm = phr['content']?['pageHeaderViewModel'];
    if (phvm is Map) {
      final titre = (phvm['title']?['dynamicTextViewModel']?['text']?['content'] as String?) ?? titrePage;
      final imgs = ((phvm['image']?['decoratedAvatarViewModel']?['avatar']?['avatarViewModel']?['image']?['sources'] as List?) ??
          (phvm['heroImage']?['contentPreviewImageViewModel']?['image']?['sources'] as List?));
      final avatar = imgs != null && imgs.isNotEmpty && imgs.last is Map ? imgs.last['url'] as String? : null;
      int? abonnes;
      String? auteur;
      final rows = phvm['metadata']?['contentMetadataViewModel']?['metadataRows'];
      if (rows is List) {
        for (final row in rows.whereType<Map>()) {
          for (final part in ((row['metadataParts'] as List?) ?? const []).whereType<Map>()) {
            final av = part['avatarStack']?['avatarStackViewModel']?['text']?['content'];
            if (av is String && av.isNotEmpty) auteur ??= av;
            final txt = part['text']?['content'];
            if (txt is String && (txt.contains('abonn') || txt.contains('subscrib'))) {
              abonnes ??= parseVues(txt);
            }
          }
        }
      }
      return (titre: titre, auteur: auteur, avatar: avatar, abonnes: abonnes);
    }
    return (titre: titrePage, auteur: null, avatar: null, abonnes: null);
  }
  final plHdr = hdr['playlistHeaderRenderer'];
  if (plHdr is Map) {
    return (
      titre: _texteRuns(plHdr['title']),
      auteur: _texteRuns(plHdr['ownerText']),
      avatar: null,
      abonnes: null,
    );
  }
  final c4 = hdr['c4TabbedHeaderRenderer'];
  if (c4 is Map) {
    final thumbs = (c4['avatar']?['thumbnails'] as List?) ?? const [];
    return (
      titre: c4['title'] as String?,
      auteur: c4['title'] as String?,
      avatar: thumbs.isNotEmpty && thumbs.last is Map ? thumbs.last['url'] as String? : null,
      abonnes: parseVues(_texteRuns(c4['subscriberCountText'])),
    );
  }
  return (titre: null, auteur: null, avatar: null, abonnes: null);
}

({String? dateUpload, String? chaineUrl, int? abonnes}) _extraireMetaNext(Json next) {
  final pinfo = _trouverPremier(next, 'videoPrimaryInfoRenderer');
  final sinfo = _trouverPremier(next, 'videoSecondaryInfoRenderer');
  final dateTxt = _texteRuns(pinfo?['dateText']);
  var upload = _formaterDateTexte(dateTxt);
  if (upload == null) {
    final ts = parseDateRelative(_texteRuns(pinfo?['relativeDateText']));
    if (ts != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
      upload = '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
    }
  }
  final vor = sinfo?['owner']?['videoOwnerRenderer'];
  final ep = vor is Map ? (vor['navigationEndpoint']?['browseEndpoint']) : null;
  final canon = ep is Map ? ep['canonicalBaseUrl'] as String? : null;
  final chId = ep is Map ? ep['browseId'] as String? : null;
  final chUrl = canon != null
      ? 'https://www.youtube.com$canon'
      : (chId != null ? 'https://www.youtube.com/channel/$chId' : null);
  final abonnes = vor is Map ? parseVues(_texteRuns(vor['subscriberCountText'])) : null;
  return (dateUpload: upload, chaineUrl: chUrl, abonnes: abonnes);
}

List<Json> _extraireChapitresNext(Json next) {
  final mm = _trouverPremier(next, 'macroMarkersListRenderer');
  if (mm == null) return const [];
  final bruts = <({int debut, String titre})>[];
  for (final item in ((mm['contents'] as List?) ?? const []).whereType<Map>()) {
    final r = item['macroMarkersListItemRenderer'];
    if (r is! Map) continue;
    final titre = _texteRuns(r['title']);
    final debut = (r['onTap']?['watchEndpoint']?['startTimeSeconds'] as num?)?.toInt() ??
        parseDuree(_texteRuns(r['timeDescription']));
    if (titre != null && titre.isNotEmpty && debut != null) {
      bruts.add((debut: debut, titre: titre));
    }
  }
  if (bruts.length < 2) return const [];
  return [
    for (var i = 0; i < bruts.length; i++)
      {
        'start_time': bruts[i].debut.toDouble(),
        if (i + 1 < bruts.length) 'end_time': bruts[i + 1].debut.toDouble(),
        'title': bruts[i].titre,
      },
  ];
}

List<Json> _extraireChapitresDescription(String description, int dureeSec) {
  if (description.isEmpty) return const [];
  final reg = RegExp(r'(?:^|\s)((?:\d{1,2}:)?\d{1,2}:\d{2})\s*[-–—|]?\s*(.+)');
  final bruts = <({int debut, String titre})>[];
  for (final ligne in const LineSplitter().convert(description)) {
    final m = reg.firstMatch(ligne.trim());
    if (m == null) continue;
    final sec = parseDuree(m.group(1));
    final titre = m.group(2)!.trim();
    if (sec != null && titre.isNotEmpty && (bruts.isEmpty || sec > bruts.last.debut)) {
      bruts.add((debut: sec, titre: titre));
    }
  }
  if (bruts.length < 2 || bruts.first.debut > 15) return const [];
  return [
    for (var i = 0; i < bruts.length; i++)
      {
        'start_time': bruts[i].debut.toDouble(),
        'end_time': (i + 1 < bruts.length ? bruts[i + 1].debut : (dureeSec > bruts[i].debut ? dureeSec : bruts[i].debut + 60))
            .toDouble(),
        'title': bruts[i].titre,
      },
  ];
}

// ---------------------------------------------------------------------------
// Helpers génériques texte, durées, vues, dates, arbre JSON
// ---------------------------------------------------------------------------

String? _texteRuns(dynamic champ) {
  if (champ is String) return champ.trim().isEmpty ? null : champ.trim();
  if (champ is! Map) return null;
  if (champ['simpleText'] is String) {
    final s = (champ['simpleText'] as String).trim();
    return s.isEmpty ? null : s;
  }
  if (champ['content'] is String) {
    final s = (champ['content'] as String).trim();
    return s.isEmpty ? null : s;
  }
  final runs = champ['runs'];
  if (runs is List) {
    final s = runs.whereType<Map>().map((r) => '${r['text'] ?? ''}').join().trim();
    return s.isEmpty ? null : s;
  }
  return null;
}

bool _estBadgeLive(Map renderer) {
  for (final b in _trouverTous(renderer, 'metadataBadgeRenderer')) {
    final s = '${b['style'] ?? ''} ${b['label'] ?? ''}'.toUpperCase();
    if (s.contains('LIVE') || s.contains('DIRECT')) return true;
  }
  for (final o in _trouverTous(renderer, 'thumbnailOverlayTimeStatusRenderer')) {
    if ('${o['style'] ?? ''}'.toUpperCase() == 'LIVE') return true;
  }
  return false;
}

int? parseDuree(String? texte) {
  if (texte == null) return null;
  final m = RegExp(r'\b(?:(\d+):)?(\d{1,2}):(\d{2})\b').firstMatch(texte.trim());
  if (m == null) return null;
  final h = m.group(1) != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
  final mn = int.tryParse(m.group(2)!) ?? 0;
  final s = int.tryParse(m.group(3)!) ?? 0;
  return h * 3600 + mn * 60 + s;
}

int? parseVues(String? texte) {
  if (texte == null || texte.isEmpty) return null;
  final propre = texte
      .toLowerCase()
      .replaceAll('\u00a0', ' ')
      .replaceAll('\u202f', ' ')
      .replaceAll('d’', '')
      .replaceAll("d'", '')
      .trim();
  if (propre.contains('aucune') || propre.contains('no views')) return 0;
  final mMult = RegExp(r'(\d+(?:[.,\s]\d+)?)\s*(k|m|md|b|milliard|million|millier)\b').firstMatch(propre);
  if (mMult != null) {
    final n = double.tryParse(mMult.group(1)!.replaceAll(' ', '').replaceAll(',', '.'));
    if (n == null) return null;
    final unite = mMult.group(2)!;
    final facteur = switch (unite) {
      'k' || 'millier' => 1e3,
      'm' || 'million' => 1e6,
      'md' || 'b' || 'milliard' => 1e9,
      _ => 1.0,
    };
    return (n * facteur).round();
  }
  final chiffres = RegExp(r'[\d\s]+').firstMatch(propre)?.group(0)?.replaceAll(RegExp(r'\D'), '');
  if (chiffres == null || chiffres.isEmpty) return null;
  return int.tryParse(chiffres);
}

int? parseDateRelative(String? texte) {
  if (texte == null || texte.isEmpty) return null;
  final t = texte.toLowerCase().replaceAll('\u00a0', ' ');
  final m = RegExp(r'(\d+)\s*(seconde|second|minute|heure|hour|jour|day|semaine|week|mois|month|an|année|year)')
      .firstMatch(t);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!) ?? 0;
  final u = m.group(2)!;
  final sec = switch (u) {
    'seconde' || 'second' => n,
    'minute' => n * 60,
    'heure' || 'hour' => n * 3600,
    'jour' || 'day' => n * 86400,
    'semaine' || 'week' => n * 7 * 86400,
    'mois' || 'month' => n * 30 * 86400,
    _ => n * 365 * 86400,
  };
  return DateTime.now().millisecondsSinceEpoch ~/ 1000 - sec;
}

Map<String, dynamic> _extraireVuesEtDateTexte(String info) {
  final out = <String, dynamic>{};
  for (final seg in info.split('•')) {
    final s = seg.trim();
    if (!out.containsKey('view_count')) {
      final v = parseVues(s);
      if (v != null) {
        out['view_count'] = v;
        continue;
      }
    }
    if (!out.containsKey('timestamp')) {
      final ts = parseDateRelative(s);
      if (ts != null) out['timestamp'] = ts;
    }
  }
  return out;
}

String? _formaterUploadDate(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(iso);
  if (m == null) return null;
  return '${m.group(1)}${m.group(2)}${m.group(3)}';
}

const _moisFrEn = {
  'janv': 1, 'jan': 1, 'janvier': 1, 'january': 1,
  'févr': 2, 'fevr': 2, 'fév': 2, 'février': 2, 'feb': 2, 'february': 2,
  'mars': 3, 'mar': 3, 'march': 3,
  'avr': 4, 'avril': 4, 'apr': 4, 'april': 4,
  'mai': 5, 'may': 5,
  'juin': 6, 'jun': 6, 'june': 6,
  'juil': 7, 'juillet': 7, 'jul': 7, 'july': 7,
  'août': 8, 'aout': 8, 'aug': 8, 'august': 8,
  'sept': 9, 'sep': 9, 'septembre': 9, 'september': 9,
  'oct': 10, 'octobre': 10, 'october': 10,
  'nov': 11, 'novembre': 11, 'november': 11,
  'déc': 12, 'dec': 12, 'décembre': 12, 'december': 12,
};

String? _formaterDateTexte(String? texte) {
  if (texte == null || texte.isEmpty) return null;
  final p = texte.toLowerCase().replaceAll('.', '').replaceAll(',', '');
  final mFr = RegExp(r'(\d{1,2})\s+([a-zàâéèêîôùûç]+)\s+(\d{4})').firstMatch(p);
  if (mFr != null) {
    final j = int.tryParse(mFr.group(1)!);
    final mois = _moisFrEn[mFr.group(2)!];
    final a = int.tryParse(mFr.group(3)!);
    if (j != null && mois != null && a != null) {
      return '${a.toString().padLeft(4, '0')}${mois.toString().padLeft(2, '0')}${j.toString().padLeft(2, '0')}';
    }
  }
  final mEn = RegExp(r'([a-z]+)\s+(\d{1,2})\s+(\d{4})').firstMatch(p);
  if (mEn != null) {
    final mois = _moisFrEn[mEn.group(1)!];
    final j = int.tryParse(mEn.group(2)!);
    final a = int.tryParse(mEn.group(3)!);
    if (j != null && mois != null && a != null) {
      return '${a.toString().padLeft(4, '0')}${mois.toString().padLeft(2, '0')}${j.toString().padLeft(2, '0')}';
    }
  }
  return null;
}

List<Json> _trouverTous(dynamic noeud, String cle) {
  final res = <Json>[];
  void visiter(dynamic n) {
    if (n is Map) {
      if (n.containsKey(cle) && n[cle] is Map) {
        res.add((n[cle] as Map).cast<String, dynamic>());
      }
      for (final v in n.values) {
        visiter(v);
      }
    } else if (n is List) {
      for (final v in n) {
        visiter(v);
      }
    }
  }

  visiter(noeud);
  return res;
}

Json? _trouverPremier(dynamic noeud, String cle) {
  if (noeud is Map) {
    if (noeud[cle] is Map) return (noeud[cle] as Map).cast<String, dynamic>();
    for (final v in noeud.values) {
      final r = _trouverPremier(v, cle);
      if (r != null) return r;
    }
  } else if (noeud is List) {
    for (final v in noeud) {
      final r = _trouverPremier(v, cle);
      if (r != null) return r;
    }
  }
  return null;
}

String? _premierTokenContinuation(Json data) {
  final c = _trouverPremier(data, 'continuationEndpoint');
  final t = c?['continuationCommand']?['token'];
  return t is String && t.isNotEmpty ? t : null;
}
