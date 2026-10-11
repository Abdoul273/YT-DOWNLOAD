import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/langues.dart' as langues;
import 'package:yt_nexus/ui/etat.dart';
import 'package:yt_nexus/moteur/taches.dart';
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/ui/page_file.dart';
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

}
