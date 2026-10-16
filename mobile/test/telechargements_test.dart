import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/maj.dart';
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/moteur/taches.dart';
import 'package:yt_nexus/moteur/erreurs.dart';
import 'package:yt_nexus/moteur/persistance.dart';
import 'package:yt_nexus/moteur/reglages.dart';

/// Les tests HTTP parlent uniquement au serveur local créé dans chaque scénario.
class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _Binding();
  const canal = MethodChannel('yt_nexus/natif');
  late Directory dossier;
  late List<MethodCall> appels;
  late int libreTravail, libreDestination, libreCache;

  setUp(() async {
    dossier = await Directory.systemTemp.createTemp('yt-nexus-test-');
    Natif.dossierCache = dossier.path;
    Natif.dossierFichiers = dossier.path;
    Natif.dossierTravail = dossier.path;
    appels = [];
    libreTravail = libreDestination = libreCache = 1024 * 1024 * 1024;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, (appel) async {
      appels.add(appel);
      return switch (appel.method) {
        'espaceLibre' => appel.arguments['travail'] == true ? libreTravail :
            appel.arguments['telechargements'] == true ? libreDestination : libreCache,
        'existe' => appel.arguments['uri'] != 'content://supprime',
        'executer' => {
          'code': 0,
          'sortie': (appel.arguments['id'] as String).endsWith('-sim')
              ? jsonEncode([{'format_id': '18', 'vcodec': 'h264', 'filesize': 100 * 1024 * 1024}])
              : jsonEncode({'title': 'Vidéo test', 'duration': 60, 'formats': []}),
        },
        _ => null,
      };
    });
  });

  void liberer(Gestionnaire g) {
    addTearDown(() async {
      await g.sauvegarder();
      g.dispose();
    });
  }

  tearDown(() async {
    await reglages.attendreSauvegarde();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    // Laisse finir les sauvegardes JSON déclenchées par les réglages.
    await pumpEventQueue();
    await dossier.delete(recursive: true);
  });

  test('La priorité déplace les tâches en attente sans interrompre les actives', () {
    final g = Gestionnaire();
    liberer(g);
    final ancienne = Tache('https://youtu.be/ancienne', {})..statut = 'pause';
    final recente = Tache('https://youtu.be/recente', {})..statut = 'programme'..programme = 4102444800;
    final active = Tache('https://youtu.be/active', {})..statut = 'telechargement';
    g.taches.addAll([active, recente, ancienne]);
    expect(g.fileAttente, [ancienne, recente]);
    g.deplacer(recente.id, 0);
    expect(g.fileAttente, [recente, ancienne]);
    expect(active.statut, 'telechargement');
    expect(active.arret, isNull);
    expect(recente.statut, 'programme');
    expect(recente.programme, 4102444800);
    final recharge = Gestionnaire()..taches.addAll(g.taches.map((t) => Tache.depuis(t.versJson())));
    addTearDown(recharge.dispose);
    expect(recharge.fileAttente.map((t) => t.id), [recente.id, ancienne.id]);
    g.deplacer(recente.id, 1);
    expect(g.fileAttente, [ancienne, recente]);
    expect(appels.where((a) => a.method == 'arreter'), isEmpty);
  });

  test('Les erreurs proposent uniquement la correction adaptée', () {
    expect(remede(analyser('Sign in to confirm you are not a bot').$1), Remede.cookies);
    expect(remede(analyser('Requested format is not available').$1), Remede.qualite);
    expect(remede('Espace insuffisant dans Téléchargements'), Remede.stockage);
    expect(remede(analyser('Private video').$1), isNull);
  });

  test('Changer la qualité relance la tâche en échec et conserve les autres options', () {
    final g = Gestionnaire();
    liberer(g);
    final t = Tache('https://youtu.be/qualite', {'type': 'video', 'qualite': '1080', 'langue_audio': 'fr'})
      ..statut = 'erreur'..erreur = 'Format demandé indisponible';
    g.taches.add(t);
    g.changerQualite(t.id, '480');
    expect(t.statut, 'en_attente');
    expect(t.options['qualite'], '480');
    expect(t.options['langue_audio'], 'fr');
    expect(t.erreur, isEmpty);
    t.statut = 'telechargement';
    g.changerQualite(t.id, '720');
    expect(t.options['qualite'], '480');
  });

  test('Un format audio en échec peut être remplacé sans changer les options vidéo', () {
    final g = Gestionnaire();
    liberer(g);
    final t = Tache('https://youtu.be/format', {'type': 'audio', 'format_audio': 'mp3', 'qualite': '1080'})..statut = 'erreur';
    g.taches.add(t);
    g.changerQualite(t.id, 'original');
    expect(t.options['format_audio'], 'original');
    expect(t.options['qualite'], '1080');
    expect(t.statut, 'en_attente');
  });

  Map<String, dynamic> decoderCarte(Object? brut) => Map<String, dynamic>.from(brut as Map);

  test('Une principale corrompue ne remplace jamais la dernière sauvegarde valide', () async {
    final f = File('${dossier.path}/donnees.json');
    await ecrireJsonSecours(f, {'valeur': 1}, decoderCarte);
    await ecrireJsonSecours(f, {'valeur': 2}, decoderCarte);
    await f.writeAsString('{tronque');
    final lecture = await lireJsonSecours(f, decoderCarte);
    expect(lecture.donnees, {'valeur': 1});
    expect(lecture.avertissement, contains('secours'));
    await ecrireJsonSecours(f, {'valeur': 3}, decoderCarte);
    expect(jsonDecode(await File('${f.path}.bak').readAsString()), {'valeur': 1});
    expect((await lireJsonSecours(f, decoderCarte)).donnees, {'valeur': 3});
  });

  test('Deux copies corrompues sont conservées et signalées', () async {
    final f = File('${dossier.path}/donnees.json');
    final secours = File('${f.path}.bak');
    await f.writeAsString('{');
    await secours.writeAsString('[');
    final lecture = await lireJsonSecours(f, decoderCarte);
    expect(lecture.donnees, isNull);
    expect(lecture.avertissement, contains('conservés'));
    await expectLater(ecrireJsonSecours(f, {'valeur': 3}, decoderCarte), throwsA(isA<FileSystemException>()));
    expect(await f.readAsString(), '{');
    expect(await secours.readAsString(), '[');
  });

  test('Les réglages récupèrent le secours même si le JSON principal a un mauvais type', () async {
    await File('${dossier.path}/reglages.json').writeAsString('{"qualite":123}');
    await File('${dossier.path}/reglages.json.bak').writeAsString('{"qualite":"480","theme":"clair","favoris":["abc"]}');
    final r = Reglages();
    addTearDown(r.dispose);
    await r.charger();
    expect(r['qualite'], '480');
    expect(r['favoris'], ['abc']);
    expect(r.avertissement, contains('secours'));
  });

  test('Un historique partiellement invalide est remplacé par le secours complet', () async {
    final t = Tache('https://youtu.be/sauvegarde', {})..statut = 'pause'..priorite = 8;
    await File('${dossier.path}/taches.json').writeAsString(jsonEncode([t.versJson(), 'invalide']));
    await File('${dossier.path}/taches.json.bak').writeAsString(jsonEncode([t.versJson()]));
    final g = Gestionnaire();
    await g.demarrer();
    await pumpEventQueue();
    await g.sauvegarder();
    g.dispose();
    expect(g.taches, hasLength(1));
    expect(g.taches.single.id, t.id);
    expect(g.taches.single.priorite, 8);
    expect(g.avertissement, contains('secours'));
  });

  test('Les liens classiques, courts, Shorts et music désignent la même vidéo', () {
    final cles = [
      'https://youtu.be/abc123?si=partage',
      'https://www.youtube.com/watch?v=abc123&list=PLtest&t=12',
      'https://m.youtube.com/shorts/abc123',
      'https://music.youtube.com/watch?v=abc123',
      'https://youtube.com/live/abc123',
    ].map(Gestionnaire.cleVideo).toSet();
    expect(cles, {'youtube:abc123'});
    expect(Gestionnaire.cleVideo('https://example.com/watch?v=abc123'), isNot('youtube:abc123'));
  });

  test('Détecter une vidéo en pause sans bloquer sa version audio', () async {
    final g = Gestionnaire();
    liberer(g);
    final t = Tache('https://youtu.be/abc123', {'type': 'video'})..statut = 'pause';
    g.taches.add(t);
    expect(await g.doublon('https://youtube.com/shorts/abc123', 'video'), same(t));
    expect(await g.doublon(t.url, 'audio'), isNull);
  });

  test('Un fichier supprimé du téléphone ne bloque pas un nouveau téléchargement', () async {
    final g = Gestionnaire();
    liberer(g);
    final t = Tache('https://youtu.be/abc123', {'type': 'video'})
      ..statut = 'termine'
      ..fichiers = [FichierPublie('video.mp4', 'content://supprime', '', 'video/mp4', 6)];
    g.taches.add(t);
    expect(await g.doublon(t.url, 'video'), isNull);
    t.fichiers = [FichierPublie('video.mp4', 'content://present', '', 'video/mp4', 6)];
    expect(await g.doublon(t.url, 'video'), same(t));
  });

  test('La file ignore les doublons et ne retélécharge un fichier que sur demande', () async {
    final g = Gestionnaire();
    liberer(g);
    final options = {'type': 'video', 'programme': 4102444800};
    final liens = [const Ajout('https://youtu.be/doublon'), const Ajout('https://youtube.com/watch?v=doublon')];
    expect(await g.ajouter(liens, options), hasLength(1));
    expect(await g.ajouter(liens, options, retelcharger: true), isEmpty);
    g.taches.single
      ..statut = 'termine'
      ..fichiers = [FichierPublie('video.mp4', 'content://present', '', 'video/mp4', 6)];
    expect(await g.ajouter(liens, options), isEmpty);
    expect(await g.ajouter(liens, options, retelcharger: true), hasLength(1));
    expect(g.taches, hasLength(2));
  });

  for (final destination in [false, true]) {
    test('Un espace insuffisant ${destination ? 'dans Téléchargements' : 'pour la fusion'} bloque avant de télécharger', () async {
      if (destination) {
        libreDestination = 120 * 1024 * 1024;
      } else {
        libreTravail = 200 * 1024 * 1024; // La source tient, mais pas la fusion et la copie.
      }
      final g = Gestionnaire();
      liberer(g);
      final fin = Completer<void>();
      g.addListener(() {
        if (g.taches.isNotEmpty && g.taches.first.statut == 'erreur' && !fin.isCompleted) fin.complete();
      });
      await g.ajouter([Ajout('https://youtu.be/espace-$destination')], {'type': 'video'});
      await fin.future.timeout(const Duration(seconds: 3));
      expect(g.taches.single.erreur, contains('Espace insuffisant'));
      expect(appels.where((a) => a.method == 'executer' && a.arguments['id'] == g.taches.single.id), isEmpty);
      expect(appels.where((a) => a.method == 'publier'), isEmpty);
    });
  }

  test('Un espace insuffisant empêche de commencer une mise à jour', () async {
    libreCache = 1024;
    final maj = Maj()..dispo = NouvelleVersion('9.0.0', '', 'http://127.0.0.1:1/app.apk', 6);
    addTearDown(maj.dispose);
    await maj.installer();
    expect(maj.erreur, contains('Espace insuffisant'));
    expect(appels.where((a) => a.method == 'installerApk'), isEmpty);
  });

  for (final cas in ['reprise', 'sans reprise', 'plage invalide', '416', 'autre version', 'coupure']) {
    test('Mise à jour : $cas', () async {
      final serveur = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => serveur.close(force: true));
      final url = 'http://127.0.0.1:${serveur.port}/app.apk';
      final maj = Maj()..dispo = NouvelleVersion('9.0.0', '', url, 6);
      addTearDown(maj.dispose);
      final tmp = File('${dossier.path}/maj/yt-nexus.apk.part');
      await tmp.parent.create();
      if (cas != 'coupure') {
        await tmp.writeAsString('abc');
        await File('${tmp.path}.json').writeAsString(jsonEncode({
          'version': cas == 'autre version' ? '8.0.0' : '9.0.0',
          'url': url, 'taille': 6, 'validateur': '"original"',
        }));
      }
      final plages = <String?>[];
      final validateurs = <String?>[];
      serveur.listen((req) async {
        plages.add(req.headers.value(HttpHeaders.rangeHeader));
        validateurs.add(req.headers.value(HttpHeaders.ifRangeHeader));
        final rep = req.response;
        rep.headers.set(HttpHeaders.etagHeader, '"original"');
        if (cas == '416' && plages.length == 1) {
          rep.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        } else if (cas == 'coupure' && plages.length == 1) {
          rep.write('abc'); // Fin de réponse prématurée : conserver les trois octets.
        } else if (cas == 'reprise' || cas == 'plage invalide' || (cas == 'coupure' && plages.length == 2)) {
          rep.statusCode = HttpStatus.partialContent;
          rep.headers.set(HttpHeaders.contentRangeHeader, cas == 'plage invalide' ? 'bytes 0-2/6' : 'bytes 3-5/6');
          rep.contentLength = 3;
          rep.write('def');
        } else {
          rep.contentLength = 6;
          rep.write('abcdef');
        }
        await rep.close();
      });

      await maj.installer();
      if (cas == 'coupure') {
        expect(maj.erreur, contains('incomplet'));
        expect(await tmp.readAsString(), 'abc');
        expect(appels.where((a) => a.method == 'installerApk'), isEmpty);
        await maj.installer();
      }
      if (cas == 'plage invalide') {
        expect(maj.erreur, contains('incohérente'));
        expect(await tmp.readAsString(), 'abc');
        expect(appels.where((a) => a.method == 'installerApk'), isEmpty);
      } else {
        expect(maj.erreur, isNull);
        expect(await File('${dossier.path}/maj/yt-nexus.apk').readAsString(), 'abcdef');
        expect(await tmp.exists(), isFalse);
        expect(appels.where((a) => a.method == 'installerApk'), hasLength(1));
      }
      expect(plages, switch (cas) {
        'autre version' => [null],
        '416' => ['bytes=3-', null],
        'coupure' => [null, 'bytes=3-'],
        _ => ['bytes=3-'],
      });
      if (cas == 'reprise') expect(validateurs, ['"original"']);
    });
  }
}
