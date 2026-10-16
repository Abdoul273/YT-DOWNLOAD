import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/maj.dart';
import 'package:yt_nexus/moteur/natif.dart';
import 'package:yt_nexus/moteur/taches.dart';

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

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(canal, null);
    // Laisse finir les sauvegardes JSON déclenchées par les réglages.
    await pumpEventQueue();
    await dossier.delete(recursive: true);
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
    addTearDown(g.dispose);
    final t = Tache('https://youtu.be/abc123', {'type': 'video'})..statut = 'pause';
    g.taches.add(t);
    expect(await g.doublon('https://youtube.com/shorts/abc123', 'video'), same(t));
    expect(await g.doublon(t.url, 'audio'), isNull);
  });

  test('Un fichier supprimé du téléphone ne bloque pas un nouveau téléchargement', () async {
    final g = Gestionnaire();
    addTearDown(g.dispose);
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
    addTearDown(g.dispose);
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
      addTearDown(g.dispose);
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
