import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/moteur/reglages.dart';
import 'package:yt_nexus/moteur/taches.dart';
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
}
