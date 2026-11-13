import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/analyse.dart' as analyse;
import 'package:yt_nexus/moteur/langues.dart' as langues;
import 'package:yt_nexus/moteur/reglages.dart';
import 'package:yt_nexus/ui/etat.dart';
import 'package:yt_nexus/moteur/taches.dart';
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/ui/page_fichiers.dart';
import 'package:yt_nexus/ui/page_file.dart';
import 'package:yt_nexus/ui/page_recherche.dart';
import 'package:yt_nexus/ui/page_video.dart';
import 'package:yt_nexus/ui/theme.dart';

void main() {
  test('langues', () {
    expect(langues.nom('fr-CA'), 'Français (CA)');
    expect(langues.memeLangue('fr-FR', 'fr'), isTrue);
  });

  test('extraction des liens', () {
    expect(extraireLiens('regarde https://youtu.be/abc et https://youtu.be/def'), hasLength(2));
    expect(extraireLiens('youtube.com/watch?v=abc'), ['https://youtube.com/watch?v=abc']);
  });

  Future<void> afficherCarte(WidgetTester tester, Tache t) async {
    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: Scaffold(body: Center(child: SizedBox(width: 380, child: CarteTache(t)))),
    ));
  }

  testWidgets('Refuser l’annulation conserve le téléchargement en cours', (tester) async {
    final t = Tache('https://youtu.be/test', {}, titre: 'Vidéo à conserver')
      ..statut = 'telechargement'
      ..progression = 42;
    gestionnaire.taches.add(t);
    addTearDown(() => gestionnaire.taches.remove(t));
    await afficherCarte(tester, t);
    await tester.tap(find.byTooltip('Annuler'));
    await tester.pumpAndSettle();
    expect(find.text('Annuler ce téléchargement ?'), findsOneWidget);
    expect(t.arret, isNull);
    await tester.tap(find.text('Garder'));
    await tester.pumpAndSettle();
    expect(t.arret, isNull);
    expect(t.statut, 'telechargement');
    expect(t.progression, 42);
  });

  testWidgets('Une fermeture du dialogue conserve la tâche et ses fichiers', (tester) async {
    final fichier = FichierPublie('video.mp4', 'content://test/video', '/test/video.mp4', 'video/mp4', 1024);
    final t = Tache('https://youtu.be/test', {}, titre: 'Vidéo terminée')
      ..statut = 'termine'
      ..fichiers = [fichier];
    gestionnaire.taches.add(t);
    addTearDown(() => gestionnaire.taches.remove(t));
    await afficherCarte(tester, t);
    await tester.tap(find.byTooltip('Retirer de la liste'));
    await tester.pumpAndSettle();
    expect(find.text('Retirer de la liste ?'), findsOneWidget);
    expect(gestionnaire.taches, contains(t));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(gestionnaire.taches, contains(t));
    expect(t.statut, 'termine');
    expect(t.fichiers, [fichier]);
  });

  testWidgets('Une tâche terminée pendant la confirmation ne sera pas annulée', (tester) async {
    final t = Tache('https://youtu.be/test', {}, titre: 'Vidéo presque terminée')..statut = 'telechargement';
    gestionnaire.taches.add(t);
    addTearDown(() => gestionnaire.taches.remove(t));
    await afficherCarte(tester, t);
    await tester.tap(find.byTooltip('Annuler'));
    await tester.pumpAndSettle();
    t.statut = 'termine';
    await tester.tap(find.text('Annuler le téléchargement'));
    await tester.pumpAndSettle();
    expect(t.statut, 'termine');
    expect(t.arret, isNull);
  });


  testWidgets('Confirmer l’annulation arrête effectivement le téléchargement', (tester) async {
    final appels = <MethodCall>[];
    const canal = MethodChannel('yt_nexus/natif');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canal, (appel) async { appels.add(appel); return null; });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(canal, null));
    final t = Tache('https://youtu.be/test', {}, titre: 'Vidéo à annuler')..statut = 'telechargement';
    gestionnaire.taches.add(t);
    addTearDown(() => gestionnaire.taches.remove(t));
    await afficherCarte(tester, t);
    await tester.tap(find.byTooltip('Annuler'));
    await tester.pumpAndSettle();
    expect(appels, isEmpty);
    expect(t.arret, isNull);
    await tester.tap(find.text('Annuler le téléchargement'));
    await tester.pumpAndSettle();
    expect(t.arret, 'annule');
    expect(appels.single.method, 'arreter');
    expect(appels.single.arguments, {'id': t.id});
  });

  testWidgets('PageFichiers : jauge stockage, vue grille, playlists locales et renommage', (tester) async {
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('yt-nexus-fichiers-'));
    Natif.dossierCache = tmp!.path;
    Natif.dossierFichiers = tmp.path;
    Natif.dossierTravail = tmp.path;
    final prevGrille = reglages['fichiers_vue_grille'];
    final prevPlaylists = reglages['playlists_locales'];
    reglages['fichiers_vue_grille'] = false;
    reglages['playlists_locales'] = <Map<String, dynamic>>[];

    const canal = MethodChannel('yt_nexus/natif');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (appel) async {
      return switch (appel.method) {
        'etatStockage' => {
          'libre': 8 * 1024 * 1024 * 1024,
          'total': 64 * 1024 * 1024 * 1024,
          'fichiers': [
            {
              'nom': 'orphelin.mp4',
              'uri': 'content://orp/1',
              'chemin': 'Download/YT-NEXUS/orphelin.mp4',
              'mime': 'video/mp4',
              'taille': 5 * 1024 * 1024,
            },
          ],
        },
        'existe' => true,
        'renommerFichier' => {
          'nom': '${appel.arguments['nouveauNom']}.mp4',
          'chemin': 'Download/YT-NEXUS/${appel.arguments['nouveauNom']}.mp4',
        },
        _ => null,
      };
    });

    final video = Tache('https://youtu.be/v', {'type': 'video'}, titre: 'Clip démo', chaine: 'Chaîne', duree: 120)
      ..statut = 'termine'
      ..tailleFichier = 12 * 1024 * 1024
      ..fichiers = [FichierPublie('clip.mp4', 'content://v/1', 'Download/YT-NEXUS/clip.mp4', 'video/mp4', 12 * 1024 * 1024)];
    final audio = Tache('https://youtu.be/a', {'type': 'audio'}, titre: 'Son studio', duree: 95)
      ..statut = 'termine'
      ..tailleFichier = 4 * 1024 * 1024
      ..fichiers = [FichierPublie('son.mp3', 'content://a/1', 'Download/YT-NEXUS/son.mp3', 'audio/mpeg', 4 * 1024 * 1024)];
    gestionnaire.taches.addAll([video, audio]);

    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      gestionnaire.taches.removeWhere((t) => t == video || t == audio);
      reglages['fichiers_vue_grille'] = prevGrille;
      reglages['playlists_locales'] = prevPlaylists;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    });

    try {
      await tester.pumpWidget(MaterialApp(
        theme: construireTheme(true),
        home: const Scaffold(body: PageFichiers()),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();

      expect(find.text('1 à nettoyer'), findsOneWidget);
      expect(find.text('Clip démo'), findsOneWidget);

      await tester.tap(find.byTooltip('Vue grille'));
      await tester.pumpAndSettle();
      expect(reglages['fichiers_vue_grille'], isTrue);
      expect(find.byType(SliverGrid), findsOneWidget);

      await tester.tap(find.text('+ Playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Soirée');
      await tester.tap(find.text('Créer'));
      await tester.pumpAndSettle();
      ScaffoldMessenger.of(tester.element(find.byType(PageFichiers))).clearSnackBars();
      await tester.pumpAndSettle();
      expect(find.text('Playlist vide'), findsOneWidget);

      await tester.ensureVisible(find.text('Ajouter des titres'));
      await tester.pump();
      await tester.tap(find.text('Ajouter des titres'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clip démo').last);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(find.text('Soirée'), findsOneWidget);

      await tester.tap(find.byTooltip('Options').first);
      await tester.pumpAndSettle();
      expect(find.text('Extraire l’audio'), findsOneWidget);
      expect(find.text('Renommer le titre'), findsOneWidget);
      await tester.tap(find.text('Renommer le titre'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Clip renommé');
      await tester.tap(find.text('Renommer'));
      await tester.pumpAndSettle();
      expect(video.titre, 'Clip renommé');
      expect(find.text('Clip renommé'), findsOneWidget);

      await tester.tap(find.text('1 à nettoyer'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Stockage & nettoyage'), findsOneWidget);
      expect(find.text('orphelin.mp4'), findsOneWidget);
    } finally {
      await tester.runAsync(() async {
        reglages['fichiers_vue_grille'] = prevGrille;
        reglages['playlists_locales'] = prevPlaylists;
        try {
          await reglages.attendreSauvegarde().timeout(const Duration(milliseconds: 500));
        } catch (_) {}
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    }
  });

  test('Horodatage vidéo : conversion texte <-> secondes', () {
    expect(parserHorodatage('90'), 90);
    expect(parserHorodatage('1:30'), 90);
    expect(parserHorodatage('01:01:01'), 3661);
    expect(parserHorodatage('invalide'), isNull);
    expect(formaterHorodatage(0), '0:00');
    expect(formaterHorodatage(90), '1:30');
    expect(formaterHorodatage(3661), '1:01:01');
  });

  testWidgets('PageVideo : curseur visuel d’extrait synchronisé et filtre/plage playlist', (tester) async {
    tester.view.physicalSize = const Size(540, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final video = analyse.resumeVideo({
      'id': 'extrait1',
      'webpage_url': 'https://youtu.be/extrait1',
      'title': 'Vidéo extrait démo',
      'duration': 180,
      'uploader': 'Créateur',
      'formats': <Map<String, dynamic>>[],
    });

    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: Scaffold(body: PageVideo(resultatInitial: video)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final boutonExtrait = find.text('Options avancées');
    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pump();
    await tester.ensureVisible(boutonExtrait);
    await tester.pump();
    await tester.tap(boutonExtrait);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RangeSlider), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), '0:30');
    await tester.pump();
    expect(tester.widget<RangeSlider>(find.byType(RangeSlider)).values, const RangeValues(30, 180));

    await tester.enterText(find.byType(TextField).at(2), '1:30');
    await tester.pump();
    expect(tester.widget<RangeSlider>(find.byType(RangeSlider)).values, const RangeValues(30, 90));

    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pump();
    await tester.ensureVisible(find.text('Tout'));
    await tester.pump();
    await tester.tap(find.text('Tout'));
    await tester.pump();
    expect(tester.widget<RangeSlider>(find.byType(RangeSlider)).values, const RangeValues(0, 180));

    final entrees = [
      for (var i = 1; i <= 12; i++)
        analyse.Entree(
          'id$i',
          i == 12 ? 'Finale spéciale' : 'Épisode $i',
          'https://youtu.be/id$i',
          120,
          null,
          'Chaîne',
          1000,
          null,
          false,
        ),
    ];
    final playlist = analyse.Playlist(
      'https://youtube.com/playlist?list=PL12',
      'Grande série',
      'Chaîne',
      null,
      entrees,
    );

    await tester.pumpWidget(MaterialApp(
      theme: construireTheme(true),
      home: Scaffold(body: PageVideo(key: const ValueKey('playlist'), resultatInitial: playlist)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('12 / 12 sélectionnées'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), 'Finale');
    await tester.pump();
    expect(find.text('12 cochées · 1 affichées / 12'), findsOneWidget);
    expect(find.textContaining('Finale spéciale'), findsOneWidget);
    expect(find.textContaining('Épisode 1'), findsNothing);

    await tester.tap(find.byTooltip('Effacer le filtre'));
    await tester.pump();
    await tester.ensureVisible(find.text('Plage'));
    await tester.tap(find.text('Plage'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.ensureVisible(find.text('1–10'));
    await tester.tap(find.text('1–10'));
    await tester.pump();
    expect(find.text('10 / 12 sélectionnées'), findsOneWidget);
  });

  testWidgets('PageChaine : onglets Vidéos/Shorts, filtre et téléchargement en 1 tap', (tester) async {
    tester.view.physicalSize = const Size(420, 960);
    tester.view.devicePixelRatio = 1.0;

    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('yt-nexus-chaine-'));
    Natif.dossierCache = tmp!.path;
    Natif.dossierFichiers = tmp.path;
    Natif.dossierTravail = tmp.path;
    final prevSim = reglages['simultanes'];
    reglages['simultanes'] = 1;
    final occupe = Tache('https://youtu.be/busy_ch', {'type': 'video'}, titre: 'En cours')..statut = 'telechargement';
    gestionnaire.taches.add(occupe);

    const canal = MethodChannel('yt_nexus/natif');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (_) async => null);

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      gestionnaire.taches.removeWhere((t) => t == occupe || t.url.contains('vid_ch_') || t.url.contains('sh_ch_'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    });

    try {
      await tester.pumpWidget(MaterialApp(
        theme: construireTheme(true),
        home: TickerMode(
          enabled: false,
          child: PageChaine(
            nomChaine: 'Créateur démo',
            chargeurTest: (section) async {
              if (section == 'shorts') {
                return analyse.InfosChaine(
                  titre: 'Créateur démo',
                  url: 'https://www.youtube.com/@createur',
                  abonnes: 42000,
                  entrees: [
                    analyse.Entree('sh1', 'Short express', 'https://youtube.com/shorts/sh_ch_1', 45, null, 'Créateur démo', 9000, null, false),
                  ],
                );
              }
              return analyse.InfosChaine(
                titre: 'Créateur démo',
                url: 'https://www.youtube.com/@createur',
                abonnes: 42000,
                entrees: [
                  analyse.Entree('v1', 'Tutoriel Flutter', 'https://youtu.be/vid_ch_1', 240, null, 'Créateur démo', 12000, null, false),
                  analyse.Entree('v2', 'Astuce Dart', 'https://youtu.be/vid_ch_2', 90, null, 'Créateur démo', 5000, null, false),
                ],
              );
            },
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Créateur démo'), findsWidgets);
      expect(find.textContaining('42 k abonnés'), findsOneWidget);
      expect(find.text('Tutoriel Flutter'), findsOneWidget);
      expect(find.text('Astuce Dart'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Flutter');
      await tester.pump();
      expect(find.text('Tutoriel Flutter'), findsOneWidget);
      expect(find.text('Astuce Dart'), findsNothing);
      await tester.tap(find.byTooltip('Effacer'));
      await tester.pump();

      await tester.tap(find.text('⚡ Shorts'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Short express'), findsOneWidget);

      await tester.tap(find.text('Télécharger').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(gestionnaire.taches.any((t) => t.url.contains('sh_ch_1')), isTrue);
      expect(find.text('En file'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    } finally {
      await tester.runAsync(() async {
        reglages['simultanes'] = prevSim;
        try {
          await reglages.attendreSauvegarde().timeout(const Duration(milliseconds: 500));
        } catch (_) {}
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    }
  });

  testWidgets('PageFile : actions globales rapides et réorganisation par glisser-déposer', (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;

    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('yt-nexus-file-'));
    Natif.dossierCache = tmp!.path;
    Natif.dossierFichiers = tmp.path;
    Natif.dossierTravail = tmp.path;
    final prevOnglet = onglet.value;
    onglet.value = 2;

    const canal = MethodChannel('yt_nexus/natif');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (_) async => null);

    final actif = Tache('https://youtu.be/f_actif', {'type': 'video'}, titre: 'En cours demo')..statut = 'telechargement';
    final enPause = Tache('https://youtu.be/f_pause', {'type': 'video'}, titre: 'En pause demo')..statut = 'pause';
    final erreur = Tache('https://youtu.be/f_err', {'type': 'video'}, titre: 'En échec demo')..statut = 'erreur';
    final att1 = Tache('https://youtu.be/f_att1', {'type': 'video'}, titre: 'Attente un')..statut = 'en_attente';
    final att2 = Tache('https://youtu.be/f_att2', {'type': 'video'}, titre: 'Attente deux')..statut = 'en_attente';
    final ajoutees = [actif, enPause, erreur, att1, att2];
    gestionnaire.taches.addAll(ajoutees);

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      onglet.value = prevOnglet;
      gestionnaire.taches.removeWhere(ajoutees.contains);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    });

    try {
      await tester.pumpWidget(MaterialApp(
        theme: construireTheme(true),
        home: const Scaffold(body: PageFile()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Tout en pause (3)'), findsOneWidget);
      expect(find.text('Tout reprendre (1)'), findsOneWidget);
      expect(find.text('Relancer (1)'), findsOneWidget);
      expect(find.byType(SliverReorderableList), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.low_priority_rounded), findsNothing);

      await tester.tap(find.text('Tout reprendre (1)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(enPause.statut, isNot('pause'));
      expect(find.text('Tout reprendre (1)'), findsNothing);
    } finally {
      await tester.runAsync(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    }
  });
}
