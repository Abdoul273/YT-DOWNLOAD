/// JSON atomique et dernière copie valide, commune aux réglages et à l'historique.
library;

import 'dart:convert';
import 'dart:io';

Future<({T? donnees, String? avertissement})> lireJsonSecours<T>(File fichier, T Function(Object?) decoder) async {
  var trouve = false;
  for (final secours in [false, true]) {
    final source = secours ? File('${fichier.path}.bak') : fichier;
    if (!await source.exists()) continue;
    trouve = true;
    try {
      return (donnees: decoder(jsonDecode(await source.readAsString())),
          avertissement: secours ? 'Données récupérées depuis la sauvegarde de secours (${fichier.uri.pathSegments.last}).' : null);
    } catch (_) {
      // Une copie illisible ne doit pas empêcher de lire l'autre.
    }
  }
  return (donnees: null, avertissement: trouve
      ? 'Impossible de lire ${fichier.uri.pathSegments.last} et sa sauvegarde. Les fichiers ont été conservés.' : null);
}

Future<void> ecrireJsonSecours<T>(File fichier, Object donnees, T Function(Object?) decoder) async {
  final texte = jsonEncode(donnees);
  decoder(jsonDecode(texte)); // Valider aussi ce qui va être écrit.
  final secours = File('${fichier.path}.bak');
  String? precedent;
  final principalePresente = await fichier.exists();
  if (principalePresente) {
    try {
      final ancien = await fichier.readAsString();
      decoder(jsonDecode(ancien));
      precedent = ancien;
    } catch (_) {}
  }
  var secoursValide = false;
  final secoursPresent = await secours.exists();
  if (secoursPresent) {
    try {
      decoder(jsonDecode(await secours.readAsString()));
      secoursValide = true;
    } catch (_) {}
  }
  if (precedent == null && !secoursValide && (principalePresente || secoursPresent)) {
    throw const FileSystemException('Sauvegarde suspendue : aucune copie valide, fichiers existants conservés.');
  }
  // Ne jamais remplacer un bon secours par une principale corrompue.
  if (precedent != null || !secoursValide) {
    final tmpSecours = File('${secours.path}.tmp');
    await tmpSecours.writeAsString(precedent ?? texte, flush: true);
    await tmpSecours.rename(secours.path);
  }
  final tmp = File('${fichier.path}.tmp');
  await tmp.writeAsString(texte, flush: true);
  await tmp.rename(fichier.path);
}
