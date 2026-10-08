/// Miniatures gardées sur le disque : chaque vignette affichée (ou d'un téléchargement terminé)
/// est enregistrée une fois, puis relue depuis le fichier — elle reste visible hors ligne.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'natif.dart';

final _connues = <String, bool>{}; // url → fichier présent
final _enCours = <String, Future<File?>>{};

Directory get _dossier => Directory('${Natif.dossierFichiers}/miniatures');

/// Nom stable (FNV-1a 64 bits) : String.hashCode ne l'est pas d'une exécution à l'autre.
String _nom(String url) {
  var h = 0xcbf29ce484222325;
  for (final c in url.codeUnits) {
    h ^= c;
    h *= 0x100000001b3; // débordement 64 bits voulu
  }
  return '${h.toUnsigned(64).toRadixString(16)}.img';
}

File fichier(String url) => File('${_dossier.path}/${_nom(url)}');

/// Chemin local si la miniature est déjà sur le disque.
String? locale(String? url) {
  if (url == null || !url.startsWith('http')) return url;
  final f = fichier(url);
  final ok = _connues[url] ??= f.existsSync();
  return ok ? f.path : null;
}

/// Télécharge la miniature sur le disque (sans effet si elle y est déjà).
Future<File?> garder(String? url) {
  if (url == null || !url.startsWith('http')) return Future.value(null);
  final f = fichier(url);
  if (_connues[url] == true) return Future.value(f);
  return _enCours[url] ??= () async {
    try {
      if (await f.exists()) {
        _connues[url] = true;
        return f;
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final rep = await (await client.getUrl(Uri.parse(url))).close();
        if (rep.statusCode != 200) return null;
        final octets = <int>[];
        await for (final b in rep) {
          octets.addAll(b);
        }
        if (octets.isEmpty) return null;
        await _dossier.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsBytes(octets, flush: true);
        await tmp.rename(f.path);
        _connues[url] = true;
        return f;
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    } finally {
      _enCours.remove(url);
    }
  }();
}

/// Fichier local s'il existe, sinon le réseau (et la miniature est gardée pour la prochaine fois).
ImageProvider image(String url) {
  final l = locale(url);
  if (l != null) return FileImage(File(l));
  if (!url.startsWith('http')) return FileImage(File(url));
  garder(url);
  return NetworkImage(url);
}

/// Supprime les miniatures qui ne servent plus à aucune des URL données.
Future<void> nettoyer(Iterable<String?> gardees) async {
  try {
    final noms = {for (final u in gardees) if (u != null && u.startsWith('http')) _nom(u)};
    await for (final e in _dossier.list()) {
      if (e is File && !noms.contains(e.uri.pathSegments.last)) {
        await e.delete();
      }
    }
    _connues.clear();
  } catch (_) {}
}
