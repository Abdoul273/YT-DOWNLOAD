import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/analyse.dart' as analyse;
import 'package:yt_nexus/moteur/formats.dart' as formats;
import 'package:yt_nexus/moteur/innertube.dart' as innertube;
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/moteur/taches.dart';

class _BindingHttpReel extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Map<String, dynamic> _playerExemple({String id = '0e3GPea1Tyg', bool multiAudio = true}) => {
      'playabilityStatus': {'status': 'OK'},
      'videoDetails': {
        'videoId': id,
        'title': 'Je Survie 50 Heures en Antarctique',
        'lengthSeconds': '742',
        'channelId': 'UCX6OQ3DkcsbYNE6H8uQQuVA',
        'author': 'MrBeast',
        'viewCount': '125000000',
        'isLive': false,
        'shortDescription': '0:00 Intro\n2:10 Arrivée\n8:05 Tempête',
        'thumbnail': {
          'thumbnails': [
            {'url': 'https://i.ytimg.com/vi/$id/hqdefault.jpg', 'width': 480, 'height': 360},
          ],
        },
      },
      'streamingData': {
        'hlsManifestUrl': 'https://manifest.googlevideo.com/api/manifest/hls_variant/example.m3u8',
        'formats': [
          {
            'itag': 18,
            'url': 'https://rr1.googlevideo.com/videoplayback?itag=18',
            'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
            'bitrate': 500000,
            'width': 640,
            'height': 360,
            'fps': 30,
            'qualityLabel': '360p',
          },
        ],
        'adaptiveFormats': [
          {
            'itag': 137,
            'url': 'https://rr1.googlevideo.com/videoplayback?itag=137',
            'mimeType': 'video/mp4; codecs="avc1.640028"',
            'bitrate': 4000000,
            'width': 1920,
            'height': 1080,
            'fps': 60,
            'contentLength': '120000000',
            'qualityLabel': '1080p60',
          },
          {
            'itag': 313,
            'url': 'https://rr1.googlevideo.com/videoplayback?itag=313',
            'mimeType': 'video/webm; codecs="vp09.00.51.08"',
            'bitrate': 14000000,
            'width': 3840,
            'height': 2160,
            'fps': 60,
            'contentLength': '380000000',
            'qualityLabel': '2160p60',
          },
          {
            'itag': 140,
            'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&lang=en',
            'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            'bitrate': 129000,
            'audioSampleRate': '44100',
            'audioChannels': 2,
            'contentLength': '12000000',
            'ifPresent': true,
            if (multiAudio)
              'audioTrack': {'id': 'en-US.4', 'displayName': 'Anglais (original)', 'audioIsDefault': true},
          },
          if (multiAudio)
            {
              'itag': 140,
              'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&lang=fr',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 129000,
              'audioSampleRate': '44100',
              'audioChannels': 2,
              'contentLength': '12100000',
              'audioTrack': {'id': 'fr.3', 'displayName': 'Français', 'audioIsDefault': false},
            },
        ],
      },
      'captions': {
        'playerCaptionsTracklistRenderer': {
          'captionTracks': [
            {
              'baseUrl': 'https://www.youtube.com/api/timedtext?v=$id&lang=fr',
              'vssId': '.fr',
              'languageCode': 'fr',
              'isTranslatable': true,
              'name': {'simpleText': 'Français'},
            },
            {
              'baseUrl': 'https://www.youtube.com/api/timedtext?v=$id&lang=en',
              'vssId': 'a.en',
              'kind': 'asr',
              'languageCode': 'en',
              'isTranslatable': true,
              'name': {'simpleText': 'Anglais (généré automatiquement)'},
            },
          ],
          'translationLanguages': [
            {'languageCode': 'es', 'languageName': {'simpleText': 'Espagnol'}},
          ],
        },
      },
    };

Map<String, dynamic> _nextExemple() => {
      'contents': {
        'twoColumnWatchNextResults': {
          'results': {
            'results': {
              'contents': [
                {
                  'videoPrimaryInfoRenderer': {
                    'dateText': {'simpleText': '24 nov. 2021'},
                  },
                },
                {
                  'videoSecondaryInfoRenderer': {
                    'owner': {
                      'videoOwnerRenderer': {
                        'subscriberCountText': {'simpleText': '527\u00a0M d’abonnés'},
                        'navigationEndpoint': {
                          'browseEndpoint': {'browseId': 'UCX6OQ3DkcsbYNE6H8uQQuVA', 'canonicalBaseUrl': '/@MrBeast'},
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        },
      },
      'engagementPanels': [
        {
          'macroMarkersListRenderer': {
            'contents': [
              {
                'macroMarkersListItemRenderer': {
                  'title': {'simpleText': 'Ouverture'},
                  'timeDescription': {'simpleText': '0:00'},
                  'onTap': {'watchEndpoint': {'startTimeSeconds': 0}},
                },
              },
              {
                'macroMarkersListItemRenderer': {
                  'title': {'simpleText': 'Camp de base'},
                  'timeDescription': {'simpleText': '3:20'},
                  'onTap': {'watchEndpoint': {'startTimeSeconds': 200}},
                },
              },
            ],
          },
        },
      ],
    };

void main() {
  _BindingHttpReel();
  const canal = MethodChannel('yt_nexus/natif');
  late Directory dossier;

  setUp(() async {
    dossier = await Directory.systemTemp.createTemp('yt-nexus-innertube-');
    Natif.dossierCache = dossier.path;
    Natif.dossierFichiers = dossier.path;
    Natif.dossierTravail = dossier.path;
    innertube.baseUriTest = null;
    innertube.reinitialiserEtatTest();
  });

  tearDown(() async {
    innertube.baseUriTest = null;
    innertube.reinitialiserEtatTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    await dossier.delete(recursive: true);
  });

  test('Extraction ID et hôte YouTube sur toutes variantes d’URL', () {
    expect(innertube.extraireIdVideo('https://youtu.be/dQw4w9WgXcQ?si=xyz'), 'dQw4w9WgXcQ');
    expect(innertube.extraireIdVideo('https://www.youtube.com/watch?v=0e3GPea1Tyg&t=10'), '0e3GPea1Tyg');
    expect(innertube.extraireIdVideo('https://m.youtube.com/shorts/ai1gIWacf0I'), 'ai1gIWacf0I');
    expect(innertube.extraireIdVideo('https://music.youtube.com/watch?v=XqZsoesa55w'), 'XqZsoesa55w');
    expect(innertube.extraireIdVideo('https://tiktok.com/@user/video/12345678901'), isNull);
    expect(innertube.extrairePlaylistId('https://www.youtube.com/playlist?list=PLabc123'), 'PLabc123');
    expect(innertube.estChaineYoutube('https://www.youtube.com/@MKBHD/videos'), isTrue);
  });

  test('Construction info_dict Innertube : doublages, 4K, chapitres, sous-titres, HLS et résolution Dart sans -sim', () {
    final info = innertube.construireInfoDepuisPlayer(
      _playerExemple(),
      urlOrigine: 'https://www.youtube.com/watch?v=0e3GPea1Tyg',
      nextData: _nextExemple(),
    );

    final resume = analyse.resumeVideo(info);
    expect(resume.titre, 'Je Survie 50 Heures en Antarctique');
    expect(resume.date, '20211124');
    expect(resume.chapitres, 2);
    expect(resume.originale, 'en-US');
    expect(resume.pisteVoulue, 'fr');
    expect(resume.sousTitres.manuels, ['fr']);
    expect(resume.sousTitres.auto, isTrue);

    final (quals, tAudio) = resume.qualitesPour('fr');
    expect(quals.map((q) => q.hauteur), containsAll([2160, 1080, 360]));
    expect(tAudio, 12100000);

    final sources = analyse.sourcesApercu(info);
    expect(sources.any((s) => s.hls && s.adaptatif), isTrue);
    expect(sources.any((s) => !s.hls && s.hauteur == 360), isTrue);

    // Résolution directe des formats en Dart (0 sous-processus -sim)
    final (piste, orig, deux) = formats.planAudio(info, 'fr', true);
    final selFr = formats.resoudreFormatsSelection(
      info,
      {'type': 'video', 'qualite': '1080', 'conteneur': 'mp4', 'compatible': true},
      piste,
      orig,
      deux,
    );
    expect(selFr, isNotNull);
    expect(selFr!.parties.map((p) => p.$1), ['137', '140-fr.3', '140-en-US.4']);
    expect(selFr.selecteurExact, startsWith('137+140-fr.3+140-en-US.4/'));
    expect(selFr.codecs.first.$1, 'avc1.640028');
  });

  test('Anti-robot : LOGIN_REQUIRED rafraîchit visitorData automatiquement et réussit sans cookies ni yt-dlp', () async {
    var visiteursEmis = 0;
    var appelsPlayer = 0;
    final serveur = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => serveur.close(force: true));
    innertube.baseUriTest = Uri.http('127.0.0.1', '', null).replace(port: serveur.port);

    serveur.listen((req) async {
      final corps = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/youtubei/v1/visitor_id') {
        visiteursEmis++;
        req.response.write(jsonEncode({'responseContext': {'visitorData': 'VIS_$visiteursEmis'}}));
      } else if (req.uri.path == '/youtubei/v1/player') {
        appelsPlayer++;
        final v = corps['context']?['client']?['visitorData'];
        if (v == 'VIS_1') {
          req.response.write(jsonEncode({
            'playabilityStatus': {'status': 'LOGIN_REQUIRED', 'reason': "Sign in to confirm you're not a bot"},
          }));
        } else {
          req.response.write(jsonEncode(_playerExemple(id: 'dQw4w9WgXcQ')));
        }
      } else if (req.uri.path == '/youtubei/v1/next') {
        req.response.write(jsonEncode(_nextExemple()));
      }
      await req.response.close();
    });

    final info = await analyse.infoComplete('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(visiteursEmis, 2);
    expect(appelsPlayer, 2);
    expect(info['_source_client'], 'VISIONOS');
    expect(info['title'], 'Je Survie 50 Heures en Antarctique');
  });

  test('Secours mobile : si VISIONOS est bloqué et yt-dlp aussi, IOS+ANDROID prennent le relais sans erreur cookies', () async {
    final serveur = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => serveur.close(force: true));
    innertube.baseUriTest = Uri.http('127.0.0.1', '', null).replace(port: serveur.port);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (appel) async {
      if (appel.method == 'executer') {
        return {'code': 1, 'sortie': '', 'erreur': "ERROR: [youtube] Sign in to confirm you're not a bot"};
      }
      return null;
    });

    serveur.listen((req) async {
      final corps = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/youtubei/v1/visitor_id') {
        req.response.write(jsonEncode({'responseContext': {'visitorData': 'VIS_OK'}}));
      } else if (req.uri.path == '/youtubei/v1/player') {
        final cn = corps['context']?['client']?['clientName'];
        if (cn == 'VISIONOS') {
          req.response.write(jsonEncode({'playabilityStatus': {'status': 'UNPLAYABLE', 'reason': 'Not playable on visionOS'}}));
        } else {
          req.response.write(jsonEncode(_playerExemple(id: 'XqZsoesa55w', multiAudio: false)));
        }
      } else {
        req.response.write(jsonEncode(_nextExemple()));
      }
      await req.response.close();
    });

    final info = await analyse.infoComplete('https://www.youtube.com/watch?v=XqZsoesa55w');
    expect(info['_source_client'], anyOf('ANDROID', 'IOS'));
    expect((info['formats'] as List), isNotEmpty);
  });

  test('Recherche, Chaîne (lockupViewModel + Shorts) et Playlist via Innertube HTTP', () async {
    final serveur = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => serveur.close(force: true));
    innertube.baseUriTest = Uri.http('127.0.0.1', '', null).replace(port: serveur.port);

    serveur.listen((req) async {
      final corps = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      switch (req.uri.path) {
        case '/youtubei/v1/visitor_id':
          req.response.write(jsonEncode({'responseContext': {'visitorData': 'VIS_1'}}));
        case '/youtubei/v1/search':
          req.response.write(jsonEncode({
            'contents': {
              'itemSectionRenderer': {
                'contents': [
                  {
                    'videoRenderer': {
                      'videoId': 'bXwWvtrHr3M',
                      'title': {'runs': [{'text': 'Test Container'}]},
                      'lengthText': {'simpleText': '1:02:26'},
                      'viewCountText': {'simpleText': '12\u202f467\u202f793\u00a0vues'},
                      'publishedTimeText': {'simpleText': 'il y a 1 mois'},
                      'ownerText': {
                        'runs': [
                          {
                            'text': 'Squeezie',
                            'navigationEndpoint': {
                              'browseEndpoint': {'browseId': 'UCWeg2Pkate69NFdBeuRFTAw', 'canonicalBaseUrl': '/@Squeezie'},
                            },
                          },
                        ],
                      },
                    },
                  },
                ],
              },
            },
          }));
        case '/youtubei/v1/navigation/resolve_url':
          req.response.write(jsonEncode({
            'endpoint': {'browseEndpoint': {'browseId': 'UCBJycsmduvYEL83R_U4JriQ', 'params': 'EgZ2aWRlb3M'}},
          }));
        case '/youtubei/v1/browse':
          final bid = corps['browseId'] as String?;
          if (bid != null && bid.startsWith('VL')) {
            req.response.write(jsonEncode({
              'header': {
                'pageHeaderRenderer': {'pageTitle': 'Ma Playlist Test'},
              },
              'contents': [
                {
                  'lockupViewModel': {
                    'contentId': 'qfDc10opQf0',
                    'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                    'metadata': {
                      'lockupMetadataViewModel': {
                        'title': {'content': 'Coding Mix'},
                        'metadata': {
                          'contentMetadataViewModel': {
                            'metadataRows': [
                              {'metadataParts': [{'text': {'content': 'FilFar'}}, {'text': {'content': '100 k vues'}}]},
                            ],
                          },
                        },
                      },
                    },
                    'contentImage': {
                      'thumbnailViewModel': {
                        'overlays': [
                          {
                            'thumbnailBottomOverlayViewModel': {
                              'badges': [{'thumbnailBadgeViewModel': {'text': '1:32:25'}}],
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              ],
            }));
          } else {
            req.response.write(jsonEncode({
              'header': {
                'pageHeaderRenderer': {
                  'pageTitle': 'Marques Brownlee',
                  'content': {
                    'pageHeaderViewModel': {
                      'title': {'dynamicTextViewModel': {'text': {'content': 'Marques Brownlee'}}},
                      'metadata': {
                        'contentMetadataViewModel': {
                          'metadataRows': [
                            {'metadataParts': [{'text': {'content': '21,4\u00a0M d’abonnés'}}]},
                          ],
                        },
                      },
                    },
                  },
                },
              },
              'contents': [
                {
                  'lockupViewModel': {
                    'contentId': 'hdMszZ2ah5Q',
                    'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                    'metadata': {
                      'lockupMetadataViewModel': {
                        'title': {'content': 'Macbook Review'},
                        'metadata': {
                          'contentMetadataViewModel': {
                            'metadataRows': [
                              {'metadataParts': [{'text': {'content': '6,1\u00a0M de vues'}}, {'text': {'content': 'il y a 5 jours'}}]},
                            ],
                          },
                        },
                      },
                    },
                    'contentImage': {
                      'thumbnailViewModel': {
                        'overlays': [
                          {'thumbnailBottomOverlayViewModel': {'badges': [{'thumbnailBadgeViewModel': {'text': '15:14'}}]}},
                        ],
                      },
                    },
                  },
                },
              ],
            }));
          }
      }
      await req.response.close();
    });

    final res = await analyse.rechercher('Squeezie', analyse.Filtres());
    expect(res, hasLength(1));
    expect(res.first.id, 'bXwWvtrHr3M');
    expect(res.first.duree, 3746);
    expect(res.first.vues, 12467793);
    expect(res.first.chaine, 'Squeezie');

    final ch = await analyse.explorerChaine(chaineUrl: 'https://www.youtube.com/@MKBHD');
    expect(ch.titre, 'Marques Brownlee');
    expect(ch.abonnes, 21400000);
    expect(ch.entrees, hasLength(1));
    expect(ch.entrees.first.duree, 914);
    expect(ch.entrees.first.vues, 6100000);

    final pl = await analyse.analyser('https://www.youtube.com/playlist?list=PLEM4vOSCprStzppPemEYAF6ZEUrQYj5N5') as analyse.Playlist;
    expect(pl.titre, 'Ma Playlist Test');
    expect(pl.entrees.single.id, 'qfDc10opQf0');
    expect(pl.entrees.single.duree, 5545);
  });

  test('Gestionnaire : aucune invocation -sim quand formats sont présents dans infoComplete', () async {
    final serveur = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => serveur.close(force: true));
    innertube.baseUriTest = Uri.http('127.0.0.1', '', null).replace(port: serveur.port);

    serveur.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/youtubei/v1/visitor_id') {
        req.response.write(jsonEncode({'responseContext': {'visitorData': 'VIS_DL'}}));
      } else if (req.uri.path == '/youtubei/v1/player') {
        req.response.write(jsonEncode(_playerExemple(id: 'dlFast12345')));
      } else {
        req.response.write(jsonEncode(_nextExemple()));
      }
      await req.response.close();
    });

    final appels = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (appel) async {
      appels.add(appel);
      return switch (appel.method) {
        'espaceLibre' => 5 * 1024 * 1024 * 1024,
        'publier' => [{'nom': 'video.mp4', 'uri': 'content://ok', 'chemin': '/ok.mp4', 'mime': 'video/mp4', 'taille': 1000}],
        'executer' => {'code': 0, 'sortie': ''},
        _ => null,
      };
    });

    final g = Gestionnaire();
    addTearDown(() async {
      await g.sauvegarder();
      g.dispose();
    });
    final fin = Completer<void>();
    g.addListener(() {
      final st = g.taches.isNotEmpty ? g.taches.first.statut : '';
      if ((st == 'termine' || st == 'erreur') && !fin.isCompleted) fin.complete();
    });
    await g.ajouter([const Ajout('https://youtu.be/dlFast12345')], {'type': 'video', 'qualite': '1080', 'compatible': true});
    await fin.future.timeout(const Duration(seconds: 3));

    final execs = appels.where((a) => a.method == 'executer').toList();
    expect(execs.where((a) => '${a.arguments['id']}'.endsWith('-sim')), isEmpty);
    expect(execs, hasLength(1));
    final args = (execs.single.arguments['args'] as List).cast<String>();
    final idxF = args.indexOf('-f');
    expect(idxF, greaterThanOrEqualTo(0));
    expect(args[idxF + 1], startsWith('137+'));
    expect(g.taches.single.parties.map((p) => p.$1), contains('137'));
  });
}
