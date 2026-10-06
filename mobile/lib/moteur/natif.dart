/// Accès à yt-dlp embarqué et aux services Android (voir MainActivity.kt).
library;

import 'dart:async';

import 'package:flutter/services.dart';

class Resultat {
  final int code;
  final String sortie, erreur;
  final bool annule;
  Resultat(this.code, this.sortie, this.erreur, this.annule);
  bool get ok => code == 0;
}

class FichierPublie {
  final String nom, uri, chemin, mime;
  final int taille;
  FichierPublie(this.nom, this.uri, this.chemin, this.mime, this.taille);
  Map<String, dynamic> versJson() => {'nom': nom, 'uri': uri, 'chemin': chemin, 'mime': mime, 'taille': taille};
  factory FichierPublie.depuis(Map d) =>
      FichierPublie(d['nom'] ?? '', d['uri'] ?? '', d['chemin'] ?? '', d['mime'] ?? '*/*', (d['taille'] ?? 0) as int);
}

class Natif {
  static const _canal = MethodChannel('yt_nexus/natif');
  static const _flux = EventChannel('yt_nexus/evenements');

  static final _lignes = <String, void Function(String)>{};
  static final _partages = StreamController<String>.broadcast();
  static final _commandesMedia = StreamController<({String action, int position})>.broadcast();
  static final _pip = StreamController<bool>.broadcast();
  static StreamSubscription? _abonnement;

  static late String dossierFichiers, dossierCache, dossierTravail;
  static String version = '?';
  static String versionApp = '0.0.0', abi = '';

  static Stream<String> get partages => _partages.stream;

  /// Boutons de la notification média / de l'écran verrouillé : play, pause, next, prev, stop, seek.
  static Stream<({String action, int position})> get commandesMedia => _commandesMedia.stream;

  /// Entrée / sortie du mode image dans l'image.
  static Stream<bool> get pipEtat => _pip.stream;

  static Future<void> init() async {
    _abonnement ??= _flux.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      if (m['type'] == 'ligne') {
        _lignes[m['id']]?.call(m['ligne'] as String);
      } else if (m['type'] == 'partage') {
        _partages.add(m['texte'] as String);
      } else if (m['type'] == 'media') {
        _commandesMedia.add((action: m['action'] as String, position: (m['position'] as num?)?.toInt() ?? 0));
      } else if (m['type'] == 'pip') {
        _pip.add(m['actif'] == true);
      }
    });
    final r = await _canal.invokeMapMethod<String, dynamic>('init');
    dossierFichiers = r!['fichiers'];
    dossierCache = r['cache'];
    dossierTravail = r['travail'];
    version = r['version'] ?? '?';
    versionApp = r['versionApp'] ?? versionApp;
    abi = r['abi'] ?? '';
  }

  static Future<String?> partageInitial() => _canal.invokeMethod<String>('partageInitial');

  /// Lance yt-dlp avec [args]. Si [ligne] est fourni, chaque ligne de sortie y est envoyée.
  static Future<Resultat> executer(String id, List<String> args, {void Function(String)? ligne}) async {
    if (ligne != null) _lignes[id] = ligne;
    try {
      final r = await _canal.invokeMapMethod<String, dynamic>(
          'executer', {'id': id, 'args': args, 'flux': ligne != null});
      return Resultat(r!['code'] ?? 1, r['sortie'] ?? '', r['erreur'] ?? '', r['annule'] == true);
    } finally {
      _lignes.remove(id);
    }
  }

  static Future<void> arreter(String id) => _canal.invokeMethod('arreter', {'id': id});

  static Future<(String, String)> majYtdlp({bool nightly = false}) async {
    final r = await _canal.invokeMapMethod<String, dynamic>('majYtdlp', {'nightly': nightly});
    version = r!['version'] ?? version;
    return (r['statut'] as String, version);
  }

  static Future<List<FichierPublie>> publier(String dossier, String sousDossier) async {
    final r = await _canal.invokeListMethod<Map>('publier', {'dossier': dossier, 'sousDossier': sousDossier});
    return [for (final d in r ?? []) FichierPublie.depuis(d)];
  }

  static Future<bool> existe(String uri) async => await _canal.invokeMethod<bool>('existe', {'uri': uri}) ?? false;
  static Future<bool> supprimerFichier(String uri) async =>
      await _canal.invokeMethod<bool>('supprimerFichier', {'uri': uri}) ?? false;
  static Future<void> ouvrir(String uri, String mime) => _canal.invokeMethod('ouvrir', {'uri': uri, 'mime': mime});
  static Future<void> partager(String uri, String mime) =>
      _canal.invokeMethod('partager', {'uri': uri, 'mime': mime});
  static Future<void> ouvrirLien(String url) => _canal.invokeMethod('ouvrirLien', {'url': url});

  static Future<void> service(bool actif, {String titre = '', String texte = '', int progression = -1}) =>
      _canal.invokeMethod('service', {'actif': actif, 'titre': titre, 'texte': texte, 'progression': progression});
  static Future<void> notifier(String titre, String texte) =>
      _canal.invokeMethod('notifier', {'titre': titre, 'texte': texte});
  /// Luminosité de la fenêtre (0‥1) ; -1 rend la main au système. Sans [valeur], lit seulement.
  static Future<double> luminosite([double? valeur]) async =>
      await _canal.invokeMethod<double>('luminosite', {'valeur': valeur}) ?? 0.5;
  static Future<String?> lireTexte(String uri) => _canal.invokeMethod<String>('lireTexte', {'uri': uri});
  static Future<bool> peutInstaller() async => await _canal.invokeMethod<bool>('peutInstaller') ?? false;
  static Future<void> installerApk(String chemin) => _canal.invokeMethod('installerApk', {'chemin': chemin});
  /// Notification média : titre, état de lecture et position (la barre avance seule entre deux envois).
  static Future<void> media({
    required String titre,
    String artiste = '',
    String? image,
    required bool lecture,
    required int position,
    required int duree,
    double vitesse = 1,
    bool prec = false,
    bool suiv = false,
  }) =>
      _canal.invokeMethod('media', {
        'titre': titre, 'artiste': artiste, 'image': image, 'lecture': lecture,
        'position': position, 'duree': duree, 'vitesse': vitesse, 'prec': prec, 'suiv': suiv,
      });
  static Future<void> mediaArreter() => _canal.invokeMethod('mediaArreter');

  /// Passe en image dans l'image ([ratio] = largeur / hauteur de la vidéo).
  static Future<bool> pip(double ratio) async => await _canal.invokeMethod<bool>('pip', {'ratio': ratio}) ?? false;

  /// Entrer en image dans l'image tout seul quand on quitte l'app.
  static Future<void> pipAuto(bool actif, double ratio) => _canal.invokeMethod('pipAuto', {'actif': actif, 'ratio': ratio});

  /// 'wifi' (non facturé) | 'mobile' | 'autre' | 'aucun'
  static Future<String> reseau() async => await _canal.invokeMethod<String>('reseau') ?? 'autre';

  static Future<void> demanderNotifications() => _canal.invokeMethod('demanderNotifications');
}
