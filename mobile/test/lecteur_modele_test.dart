import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:yt_nexus/moteur/analyse.dart' as analyse;
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/moteur/paroles.dart';
import 'package:yt_nexus/moteur/reglages.dart';
import 'package:yt_nexus/moteur/taches.dart';
import 'package:yt_nexus/ui/lecteur.dart';
import 'package:yt_nexus/ui/lecteur_audio.dart';
import 'package:yt_nexus/ui/page_reglages.dart';
import 'package:yt_nexus/ui/theme.dart';

void main() {
  test('extraction et normalisation des chapitres yt-dlp', () {
    final info = {
      'duration': 300,
      'chapters': [
        {'start_time': 95.5, 'end_time': 200.0, 'title': 'Deuxième partie'},
        {'start_time': 0, 'end_time': 95.5, 'title': 'Introduction'},
        {'start_time': 200.0, 'title': ''}, // sans fin ni titre explicites
        {'title': 'invalide'}, // sans start_time -> ignoré
      ],
    };

    final ch = extraireChapitresInfo(info);
    expect(ch, hasLength(3));
    expect(ch[0].titre, 'Introduction');
    expect(ch[0].debutMs, 0);
    expect(ch[0].finMs, 95500);

    expect(ch[1].titre, 'Deuxième partie');
    expect(ch[1].debutMs, 95500);
    expect(ch[1].finMs, 200000);

    expect(ch[2].titre, 'Chapitre 3');
    expect(ch[2].debutMs, 200000);
    expect(ch[2].finMs, 300000);
  });

  test('sérialisation JSON des chapitres sur Tache et rétrocompatibilité', () {
    final t = Tache('https://youtu.be/test', {'type': 'video'}, titre: 'Démo', duree: 180)
      ..fichiers = [FichierPublie('demo.mp4', 'content://demo', '', 'video/mp4', 1024)]
      ..chapitres = [
        const ChapitreVideo(titre: 'Intro', debutMs: 0, finMs: 45000),
        const ChapitreVideo(titre: 'Coeur', debutMs: 45000, finMs: 180000),
      ];

    final json = t.versJson();
    final relue = Tache.depuis(json);
    expect(relue.chapitres, hasLength(2));
    expect(relue.chapitres[0].titre, 'Intro');
    expect(relue.chapitres[1].debutMs, 45000);
    expect(relue.chapitres[1].finMs, 180000);

    // Ancienne tâche sans clé 'chapitres'
    final ancienne = Map<String, dynamic>.of(json)..remove('chapitres');
    final relueAncienne = Tache.depuis(ancienne);
    expect(relueAncienne.chapitres, isEmpty);
  });

  test('réglages par défaut du lecteur présents et typés', () {
    expect(reglagesDefaut['lecteur_orientation'], isA<int>());
    expect(reglagesDefaut['lecteur_vitesse'], isA<double>());
    expect(reglagesDefaut['lecteur_vitesse_maintien'], isA<double>());
    expect(reglagesDefaut['lecteur_st'], isA<bool>());
    expect(reglagesDefaut['lecteur_st_taille'], isA<int>());
    expect(reglagesDefaut['lecteur_st_fond'], isA<bool>());
    expect(reglagesDefaut['lecteur_st_couleur'], 'blanc');
    expect(reglagesDefaut['lecteur_saut'], 10);
    expect(reglagesDefaut['lecteur_auto'], isTrue);
    expect(reglagesDefaut['lecteur_gestes'], isTrue);
    expect(reglagesDefaut['lecteur_nuit'], 0.0);
    expect(reglagesDefaut['lecteur_miroir'], isFalse);
    expect(reglagesDefaut['lecteur_reprendre'], isTrue);
  });

  testWidgets('PageReglages filtre par catégories et par recherche sans débordement', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: const Scaffold(body: PageReglages()),
    ));

    expect(find.text('Apparence & Confort'), findsOneWidget);
    expect(find.text('Médias & Qualité par défaut'), findsOneWidget);

    await tester.tap(find.text('Lecteur'));
    await tester.pumpAndSettle();
    expect(find.text('Lecteur vidéo & gestes'), findsOneWidget);
    expect(find.text('Apparence & Confort'), findsNothing);

    await tester.enterText(find.byType(TextField), 'wifi');
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi uniquement'), findsOneWidget);
    expect(find.text('Lecteur vidéo & gestes'), findsNothing);
  });

  test('extraction de palette audio adaptative depuis RGBA', () {
    // Monochrome sombre -> null (repli sur les couleurs du thème)
    final sombre = Uint8List.fromList([
      for (var i = 0; i < 64; i++) ...[12, 12, 14, 255],
    ]);
    expect(calculerPaletteAudioDepuisRgba(sombre), isNull);

    // Pochette bicolore bleu électrique + corail -> 2 couleurs contrastées et distinctes
    final colore = Uint8List.fromList([
      for (var i = 0; i < 48; i++) ...[28, 120, 245, 255],
      for (var i = 0; i < 24; i++) ...[240, 75, 110, 255],
    ]);
    final pal = calculerPaletteAudioDepuisRgba(colore);
    expect(pal, isNotNull);
    expect(pal!.primaire, isNot(equals(pal.secondaire)));
    final hsvP = HSVColor.fromColor(pal.primaire);
    expect(hsvP.saturation, greaterThanOrEqualTo(0.54));
    expect(hsvP.value, inInclusiveRange(0.54, 0.80));
  });

  testWidgets('MoteurAudio enchaîne les 3 styles visuels sans perte d’état', (tester) async {
    final initial = moteurAudio.stylePochette;
    addTearDown(() => moteurAudio.choisirStylePochette(initial));

    moteurAudio.choisirStylePochette('vinyle');
    expect(moteurAudio.stylePochette, 'vinyle');
    moteurAudio.basculerStylePochette();
    expect(moteurAudio.stylePochette, 'carte');
    moteurAudio.basculerStylePochette();
    expect(moteurAudio.stylePochette, 'onde');
    moteurAudio.basculerStylePochette();
    expect(moteurAudio.stylePochette, 'vinyle');
  });

  testWidgets('MiniLecteurAudio reste masqué quand aucune piste n’est ouverte', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: const Scaffold(bottomNavigationBar: MiniLecteurAudio()),
    ));
    expect(find.byType(MiniLecteurAudio), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  test('analyserM3u8Maitre extrait et résout chaque résolution avec sa piste audio', () {
    const manifeste = '''
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud_aac",NAME="Original",DEFAULT=YES,URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.64002a",AUDIO="aud_aac"
video/1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2100000,RESOLUTION=1280x720,FRAME-RATE=30,CODECS="avc1.4d401f",AUDIO="aud_aac"
video/720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360,FRAME-RATE=30,CODECS="vp09.00.21.08",AUDIO="aud_aac"
video/360p.m3u8
''';
    final sources = analyse.analyserM3u8Maitre(
      manifeste,
      Uri.parse('https://cdn.example.com/hls/master.m3u8'),
      const {'User-Agent': 'Test'},
    );
    expect(sources, hasLength(3));
    expect(sources.map((s) => s.hauteur).toList(), [1080, 720, 360]);
    expect(sources.first.libelle, '1080p60');
    expect(sources.first.codec, 'H.264');
    expect(sources.first.m3u8Filtre, contains('https://cdn.example.com/hls/audio/main.m3u8'));
    expect(sources.first.m3u8Filtre, contains('https://cdn.example.com/hls/video/1080p.m3u8'));
    expect(sources.first.m3u8Filtre, isNot(contains('video/720p.m3u8')));
  });

  test('sousTitresStreaming filtre les traductions inutiles et ordonne les langues', () {
    final info = {
      'language': 'en',
      'subtitles': {
        'live_chat': [
          {'ext': 'json3', 'url': 'https://example.com/chat.json3'},
        ],
        'en': [
          {'ext': 'vtt', 'url': 'https://example.com/en.vtt'},
        ],
        'fr': [
          {'ext': 'vtt', 'url': 'https://example.com/fr.vtt'},
        ],
      },
      'automatic_captions': {
        'en-orig': [
          {'ext': 'vtt', 'url': 'https://example.com/en-orig.vtt'},
        ],
        'zu': [
          {'ext': 'vtt', 'url': 'https://example.com/zu.vtt'},
        ],
      },
    };
    final pistes = analyse.sousTitresStreaming(info);
    expect(pistes.any((p) => p.code == 'live_chat'), isFalse);
    expect(pistes.any((p) => p.code == 'zu'), isFalse);
    expect(pistes.where((p) => !p.auto), hasLength(2));
    expect(pistes.any((p) => p.auto && p.code == 'en'), isTrue);
  });

  test('analyserSousTitresTexte déduplique les lignes roulantes WebVTT YouTube', () {
    const vtt = '''
WEBVTT

00:00:01.000 --> 00:00:03.000
<c>Bonjour tout le monde</c>

00:00:03.000 --> 00:00:05.000
Bonjour tout le monde
Bienvenue sur la chaîne
''';
    final d = analyserSousTitresTexte(vtt, estVtt: true, autoYoutube: true);
    expect(d, isNotNull);
    expect(d!.synchro, isTrue);
    expect(d.lignes, hasLength(2));
    expect(d.lignes[0].texte, 'Bonjour tout le monde');
    expect(d.lignes[1].texte, 'Bienvenue sur la chaîne');
  });

  test('MediaLecteur et réglages streaming par défaut sont cohérents', () {
    expect(reglagesDefaut['lecteur_stream_st'], isFalse);
    expect(reglagesDefaut['lecteur_stream_qualite'], 'auto');
    final e = analyse.Entree('abc', 'Vidéo test', 'https://www.youtube.com/watch?v=abc', 120, null, 'Chaîne', 100, null, false);
    final m = MediaLecteur.depuisEntree(e);
    expect(m.estStream, isTrue);
    expect(m.clePrefs, 'stream:abc');
  });

  testWidgets('Lecteur accepte luminosité, volume, glisser et double-appui même quand les boutons sont affichés',
      (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const canalNatif = MethodChannel('yt_nexus/natif');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var lumCourante = 0.4;
    var volCourant = 0.3;
    final appelsLum = <double>[];
    final appelsVol = <double>[];

    messenger.setMockMethodCallHandler(canalNatif, (appel) async {
      switch (appel.method) {
        case 'luminosite':
          final v = (appel.arguments as Map?)?['valeur'] as double?;
          if (v != null && v >= 0) {
            lumCourante = v;
            appelsLum.add(v);
          }
          return lumCourante;
        case 'volume':
          final v = (appel.arguments as Map?)?['valeur'] as double?;
          if (v != null) {
            volCourant = v;
            appelsVol.add(v);
          }
          return volCourant;
        default:
          return null;
      }
    });
    const canalWakeloockToggle = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      StandardMessageCodec(),
    );
    messenger.setMockMessageHandler(canalWakeloockToggle.name, (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]));
    addTearDown(() {
      messenger.setMockMethodCallHandler(canalNatif, null);
      messenger.setMockMessageHandler(canalWakeloockToggle.name, null);
    });

    final ctrl = _FauxControleurVideo();
    final media = MediaLecteur.depuisEntree(
      analyse.Entree('v1', 'Démo lecteur', 'https://www.youtube.com/watch?v=v1', 180, null, 'Chaîne', 10, null, false),
    );

    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: Lecteur([media], 0, controleurInitial: ctrl),
    ));
    await tester.pump();

    // Les contrôles sont affichés dès l'ouverture (bouton Pause visible et actif).
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    // 1. Glisser vertical à gauche -> augmente la luminosité malgré les boutons affichés.
    await tester.dragFrom(const Offset(120, 300), const Offset(0, -140));
    await tester.pump();
    expect(appelsLum, isNotEmpty);
    expect(lumCourante, greaterThan(0.4));

    // 2. Glisser vertical à droite -> augmente le volume système malgré les boutons affichés.
    await tester.dragFrom(const Offset(680, 300), const Offset(0, -140));
    await tester.pump();
    expect(appelsVol, isNotEmpty);
    expect(volCourant, greaterThan(0.3));

    // 3. Glisser horizontal -> fait avancer la vidéo malgré les boutons affichés.
    final posAvant = ctrl.value.position;
    await tester.dragFrom(const Offset(260, 180), const Offset(180, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(ctrl.value.position, greaterThan(posAvant));

    // 4. Double appui à droite (puis 3e appui en rafale) -> saute +10s puis +10s malgré les boutons affichés.
    final posAvantSaut = ctrl.value.position;
    await tester.tapAt(const Offset(700, 200));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(700, 200));
    await tester.pump(const Duration(milliseconds: 80));
    expect(ctrl.value.position.inSeconds - posAvantSaut.inSeconds, 10);

    await tester.tapAt(const Offset(700, 200));
    await tester.pump(const Duration(milliseconds: 350));
    expect(ctrl.value.position.inSeconds - posAvantSaut.inSeconds, 20);

    // 5. Les boutons (ex. Pause) fonctionnent toujours normalement.
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pumpAndSettle();
    expect(ctrl.value.isPlaying, isFalse);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pumpAndSettle();
    expect(ctrl.value.isPlaying, isTrue);

    // 6. Appui long maintenu -> accélère à 2× tant que maintenu puis restaure 1×.
    final gesteMaintien = await tester.startGesture(const Offset(140, 200));
    await tester.pump(const Duration(milliseconds: 650));
    expect(ctrl.value.playbackSpeed, 2.0);
    expect(find.textContaining('▶▶'), findsOneWidget);
    await gesteMaintien.up();
    await tester.pump();
    expect(ctrl.value.playbackSpeed, 1.0);

    // 7. Appui simple dans le vide -> masque les boutons (IgnorePointer actif).
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(const Offset(140, 200));
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump(const Duration(milliseconds: 220));
    final op = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).last);
    expect(op.opacity, 0.0);

    // Laisser les timers d'animation / masquage se terminer proprement avant teardown.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _FauxControleurVideo extends VideoPlayerController {
  _FauxControleurVideo() : super.networkUrl(Uri.parse('https://example.com/v.mp4')) {
    value = const VideoPlayerValue(
      duration: Duration(minutes: 3),
      position: Duration(seconds: 30),
      size: Size(1280, 720),
      isInitialized: true,
      isPlaying: true,
    );
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);

  @override
  Future<void> seekTo(Duration position) async {
    final p = position < Duration.zero
        ? Duration.zero
        : (position > value.duration ? value.duration : position);
    value = value.copyWith(position: p);
  }

  @override
  Future<void> setLooping(bool looping) async => value = value.copyWith(isLooping: looping);

  @override
  Future<void> setVolume(double volume) async => value = value.copyWith(volume: volume.clamp(0.0, 1.0));

  @override
  Future<void> setPlaybackSpeed(double speed) async => value = value.copyWith(playbackSpeed: speed);

  @override
  Future<List<VideoAudioTrack>> getAudioTracks() async => const [];

  @override
  Future<void> dispose() async {
    value = const VideoPlayerValue.uninitialized();
    super.dispose();
  }
}
