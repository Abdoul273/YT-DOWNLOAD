/// Mises à jour de l'app : on lit la dernière release GitHub du site de téléchargement,
/// on télécharge l'APK adapté au téléphone et on ouvre l'installateur d'Android.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'natif.dart';
import 'reglages.dart';

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

  File get _apk => File('${Natif.dossierCache}/maj/yt-nexus.apk');

  /// Interroge GitHub (au plus toutes les 6 h, sauf [force]). Renvoie la version disponible.
  Future<NouvelleVersion?> verifier({bool force = false}) async {
    final maintenant = DateTime.now().millisecondsSinceEpoch;
    if (!force && maintenant - ((reglages['derniere_verif_maj'] ?? 0) as num) < 6 * 3600 * 1000) return dispo;
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
      return dispo = NouvelleVersion(version, '${d['body'] ?? ''}'.trim(), a['browser_download_url'], (a['size'] ?? 0) as int);
    } catch (e) {
      erreur = '$e';
      return dispo;
    } finally {
      client.close();
      verification = false;
      notifyListeners();
    }
  }

  /// Télécharge l'APK puis ouvre l'installateur Android.
  Future<void> installer() async {
    final v = dispo;
    if (v == null || progression != null) return;
    progression = 0;
    erreur = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      await _apk.parent.create(recursive: true);
      final pret = _apk.existsSync() && _apk.lengthSync() == v.taille && reglages['apk_version'] == v.version;
      if (!pret) {
        final req = await client.getUrl(Uri.parse(v.url));
        req.headers.set(HttpHeaders.userAgentHeader, 'YT-NEXUS/${Natif.versionApp}');
        final rep = await req.close();
        if (rep.statusCode != 200) throw 'Téléchargement refusé (${rep.statusCode})';
        final total = rep.contentLength > 0 ? rep.contentLength : v.taille;
        final tmp = File('${_apk.path}.part');
        final sortie = tmp.openWrite();
        var recu = 0;
        await for (final morceau in rep) {
          sortie.add(morceau);
          recu += morceau.length;
          if (total > 0) {
            progression = recu / total;
            notifyListeners();
          }
        }
        await sortie.close();
        if (v.taille > 0 && recu != v.taille) throw 'Fichier incomplet, réessaie.';
        await tmp.rename(_apk.path);
        reglages['apk_version'] = v.version;
      }
      progression = 1;
      notifyListeners();
      await Natif.installerApk(_apk.path);
    } catch (e) {
      erreur = '$e';
    } finally {
      client.close();
      progression = null;
      notifyListeners();
    }
  }
}

final maj = Maj();
