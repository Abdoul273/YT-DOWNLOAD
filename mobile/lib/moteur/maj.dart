/// Mises à jour de l'app : on lit la dernière release GitHub du site de téléchargement,
/// on télécharge l'APK adapté au téléphone et on ouvre l'installateur d'Android.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'natif.dart';
import 'reglages.dart';
import 'taches.dart' show formaterTaille;

const _depot = 'Abdoul273/yt-nexus-site';

class NouvelleVersion {
  final String version, notes, url;
  final int taille;
  NouvelleVersion(this.version, this.notes, this.url, this.taille);
}

/// -1 si a < b, 0 si égales, 1 si a > b (versions « 1.2.3 »).
int comparerVersions(String a, String b) {
  List<int> v(String s) => s.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
  final x = v(a), y = v(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

class Maj extends ChangeNotifier {
  NouvelleVersion? dispo;
  double? progression; // pendant le téléchargement
  String? erreur;
  bool verification = false;

  StreamSubscription? _abo;

  @override
  void dispose() {
    _abo?.cancel();
    super.dispose();
  }

  File get _apk => File('${Natif.dossierCache}/maj/yt-nexus.apk');

  /// Interroge GitHub (au plus toutes les 30 min, sauf [force]). Renvoie la version disponible.
  Future<NouvelleVersion?> verifier({bool force = false}) async {
    final maintenant = DateTime.now().millisecondsSinceEpoch;
    if (!force && maintenant - ((reglages['derniere_verif_maj'] ?? 0) as num) < 30 * 60 * 1000) return dispo;
    if (verification) return dispo;
    verification = true;
    erreur = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_depot/releases/latest'));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'YT-NEXUS/${Natif.versionApp}');
      final rep = await req.close().timeout(const Duration(seconds: 15));
      if (rep.statusCode != 200) throw 'GitHub a répondu ${rep.statusCode}';
      final d = jsonDecode(await rep.transform(utf8.decoder).join()) as Map;
      reglages['derniere_verif_maj'] = maintenant;
      final version = '${d['tag_name']}'.replaceFirst(RegExp(r'^v'), '');
      if (comparerVersions(version, Natif.versionApp) <= 0) {
        dispo = null;
        return null;
      }
      // 64 bits → yt-nexus.apk ; anciens téléphones 32 bits → yt-nexus-armv7.apk
      final nom = Natif.abi.startsWith('armeabi') ? 'yt-nexus-armv7.apk' : 'yt-nexus.apk';
      final assets = ((d['assets'] as List?) ?? []).cast<Map>();
      final a = assets.where((a) => a['name'] == nom).firstOrNull ??
          assets.where((a) => '${a['name']}'.endsWith('.apk')).firstOrNull;
      if (a == null) return dispo = null;
      final nouvelle = NouvelleVersion(version, '${d['body'] ?? ''}'.trim(), a['browser_download_url'], (a['size'] ?? 0) as int);
      dispo = nouvelle;
      return dispo;
    } catch (e) {
      erreur = '$e';
      return dispo;
    } finally {
      client.close();
      verification = false;
      notifyListeners();
    }
  }

  bool get apkPret {
    final v = dispo;
    return v != null && _apk.existsSync() && _apk.lengthSync() == v.taille && reglages['apk_version'] == v.version;
  }

  /// Garde le fichier partiel et son identité entre les essais, y compris après redémarrage.
  Future<void> _telechargerApk(HttpClient client, NouvelleVersion v) async {
    final tmp = File('${_apk.path}.part');
    final meta = File('${tmp.path}.json');
    final identite = {'version': v.version, 'url': v.url, 'taille': v.taille};
    Map sauvegarde = {};
    try {
      sauvegarde = jsonDecode(await meta.readAsString()) as Map;
    } catch (_) {}
    final correspond = identite.entries.every((e) => sauvegarde[e.key] == e.value);
    var debut = await tmp.exists() && correspond ? await tmp.length() : 0;
    if (v.taille > 0 && debut > v.taille) debut = 0;
    if (debut == 0 && await tmp.exists()) await tmp.writeAsBytes([]);

    // Une réponse 416 à une reprise invalide autorise un seul nouvel essai depuis zéro.
    for (var essai = 0; essai < 2; essai++) {
      if (v.taille > 0 && debut == v.taille) break;
      final libre = await Natif.espaceLibre();
      final restant = max(0, v.taille - debut);
      if (libre < restant + 50 * 1024 * 1024) {
        throw 'Espace insuffisant pour la mise à jour : ${formaterTaille(restant + 50 * 1024 * 1024)} nécessaires, '
            '${formaterTaille(libre)} libres.';
      }
      final req = await client.getUrl(Uri.parse(v.url)).timeout(const Duration(seconds: 20));
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'YT-NEXUS/${Natif.versionApp}')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (debut > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$debut-');
        final validateur = sauvegarde['validateur'];
        if (validateur is String && validateur.isNotEmpty) req.headers.set(HttpHeaders.ifRangeHeader, validateur);
      }
      final rep = await req.close().timeout(const Duration(seconds: 20));
      if (rep.statusCode == HttpStatus.requestedRangeNotSatisfiable && debut > 0) {
        await rep.drain<void>().timeout(const Duration(seconds: 30));
        debut = 0;
        await tmp.writeAsBytes([]);
        continue;
      }
      if (rep.statusCode != HttpStatus.ok && rep.statusCode != HttpStatus.partialContent) {
        throw 'Téléchargement refusé (${rep.statusCode})';
      }
      var total = v.taille;
      if (rep.statusCode == HttpStatus.partialContent) {
        final plage = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(rep.headers.value(HttpHeaders.contentRangeHeader) ?? '');
        if (plage == null || int.parse(plage[1]!) != debut ||
            int.parse(plage[2]!) < debut || int.parse(plage[2]!) >= int.parse(plage[3]!) ||
            (v.taille > 0 && int.parse(plage[3]!) != v.taille)) {
          throw 'Reprise refusée : le serveur a renvoyé une plage de données incohérente.';
        }
        total = int.parse(plage[3]!);
      } else {
        // Serveur sans reprise, ou fichier changé (If-Range) : remplacer le partiel.
        debut = 0;
        total = rep.contentLength > 0 ? rep.contentLength : v.taille;
        if (v.taille > 0 && total != v.taille) throw 'La taille de la mise à jour a changé. Vérifie à nouveau les mises à jour.';
        if (libre < total + 50 * 1024 * 1024) throw 'Espace insuffisant pour recommencer la mise à jour.';
      }
      final etag = rep.headers.value(HttpHeaders.etagHeader);
      final validateur = etag != null && !etag.startsWith('W/') ? etag : rep.headers.value(HttpHeaders.lastModifiedHeader);
      // Invalider l'ancienne identité avant de remplacer les octets.
      await meta.writeAsString('{}', flush: true);
      if (debut == 0) await tmp.writeAsBytes([]);
      await meta.writeAsString(jsonEncode({...identite, 'validateur': validateur}), flush: true);
      final sortie = tmp.openWrite(mode: FileMode.append);
      // Écouter aussi les erreurs de disque dès l'ouverture du sink.
      final ecriture = sortie.done;
      ecriture.ignore();
      var recu = debut;
      progression = total > 0 ? recu / total : 0;
      notifyListeners();
      try {
        await sortie.addStream(rep.timeout(const Duration(seconds: 30)).map((morceau) {
          recu += morceau.length;
          if (total > 0 && recu > total) throw 'La mise à jour dépasse la taille attendue.';
          if (total > 0 && (recu * 100 ~/ total) != ((progression ?? 0) * 100).floor()) {
            progression = recu / total;
            notifyListeners();
          }
          return morceau;
        }));
      } finally {
        await sortie.close();
      }
      if (total <= 0 || recu != total) throw 'Fichier incomplet. Réessaie pour reprendre le téléchargement.';
      debut = recu;
      break;
    }
    if (debut <= 0 || (v.taille > 0 && debut != v.taille)) throw 'Fichier incomplet, réessaie.';
    await tmp.rename(_apk.path);
    reglages['apk_version'] = v.version;
    if (await meta.exists()) await meta.delete();
  }

  /// Télécharge l'APK (si besoin) puis lance l'installation Android.
  Future<void> installer() async {
    final v = dispo;
    if (v == null || progression != null) return;
    progression = 0;
    erreur = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      await _apk.parent.create(recursive: true);
      final pret = apkPret;
      if (!pret) {
        await _telechargerApk(client, v);
      }
      progression = 1;
      notifyListeners();
      _abo ??= Natif.installationsEchouees.listen((m) {
        erreur = m;
        notifyListeners();
      });
      await Natif.installerApk(_apk.path);
    } catch (e) {
      erreur = '$e';
    } finally {
      client.close(force: true);
      progression = null;
      notifyListeners();
    }
  }
}

final maj = Maj();
