/// Réglages persistants (fichier JSON dans le stockage privé de l'app).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'natif.dart';

const reglagesDefaut = <String, dynamic>{
  'simultanes': 2, // téléchargements en parallèle
  'langue_audio': 'fr', // piste doublée voulue ("original" = VO)
  'garder_vo': true, // garder la VO en 2e piste
  'sous_titres_secours': true, // pas de doublage → sous-titres intégrés
  'type': 'video',
  'qualite': '1080',
  'conteneur': 'mp4',
  'format_audio': 'mp3',
  'qualite_audio': '0', // 0 = meilleure (VBR) ; sinon kbps
  'sponsorblock': false,
  'miniature': true,
  'metadonnees': true,
  'fragments': 4,
  'limite_vitesse': '', // ex. "2M"
  'modele_nom': '%(title)s [%(id)s].%(ext)s',
  'sous_dossier_playlist': true,
  'notifications': true,
  'relances': 4, // nouvelles tentatives automatiques
  'wifi_seulement': false,
  'plage_active': false, // ne télécharger que dans une plage horaire (ex. la nuit)
  'plage_debut': 23 * 60, // minutes depuis minuit
  'plage_fin': 7 * 60,
  'presse_papiers_auto': true, // propose de télécharger un lien YouTube copié
  'dernier_lien_propose': '',
  'eco_donnees': false, // qualité plafonnée sur réseau mobile
  'eco_qualite': '480',
  'pin_hash': '', // verrouillage par code
  'pin_sel': '',
  'pip_auto': true, // vidéo en image dans l'image en quittant l'app
  'favoris': <String>[], // ids des fichiers favoris
  'tri_fichiers': 'recent',
  'theme': 'sombre',
  'maj_auto': true,
  'derniere_maj': 0,
};

class Reglages extends ChangeNotifier {
  final Map<String, dynamic> _v = Map.of(reglagesDefaut);
  bool _ecriture = false, _aRecrire = false, _cookies = false;

  File get _fichier => File('${Natif.dossierFichiers}/reglages.json');
  File get fichierCookies => File('${Natif.dossierFichiers}/cookies.txt');

  dynamic operator [](String cle) => _v[cle];

  void operator []=(String cle, dynamic valeur) {
    _v[cle] = valeur;
    notifyListeners();
    _sauver();
  }

  /// Pour les données internes (positions de lecture…) : pas de reconstruction de l'interface.
  void ecrireSansPrevenir(String cle, dynamic valeur) {
    _v[cle] = valeur;
    _sauver();
  }

  Map<String, dynamic> get tout => Map.unmodifiable(_v);

  Future<void> charger() async {
    try {
      _v.addAll((jsonDecode(await _fichier.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {}
    try {
      _cookies = await fichierCookies.exists() && await fichierCookies.length() > 0;
    } catch (_) {}
  }

  /// Une seule écriture à la fois (la dernière valeur gagne) : deux écritures simultanées
  /// dans le même fichier temporaire pouvaient le tronquer et faire perdre tous les réglages
  /// (code, favoris, positions de lecture…).
  Future<void> _sauver() async {
    if (_ecriture) {
      _aRecrire = true;
      return;
    }
    _ecriture = true;
    try {
      do {
        _aRecrire = false;
        try {
          final tmp = File('${_fichier.path}.tmp');
          await tmp.writeAsString(jsonEncode(_v), flush: true);
          await tmp.rename(_fichier.path);
        } catch (_) {}
      } while (_aRecrire);
    } finally {
      _ecriture = false;
    }
  }

  bool get aDesCookies => _cookies;

  /// Options d'authentification/réseau communes à tous les appels yt-dlp.
  List<String> argsAuth() => [
        if (aDesCookies) ...['--cookies', fichierCookies.path],
        '--cache-dir', '${Natif.dossierCache}/yt-dlp',
      ];

  Future<void> enregistrerCookies(String texte) async {
    if (texte.trim().isEmpty) {
      if (await fichierCookies.exists()) await fichierCookies.delete();
      _cookies = false;
    } else {
      final t = texte.trimLeft();
      await fichierCookies.writeAsString(
          t.startsWith('# Netscape') || t.startsWith('# HTTP') ? t : '# Netscape HTTP Cookie File\n$t');
      _cookies = true;
    }
    notifyListeners();
  }
}

final reglages = Reglages();
