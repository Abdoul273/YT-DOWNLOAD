/// File de téléchargements : parallélisme, pause/reprise, relances, persistance.
/// Portage de nexus/taches.py.
///
/// Chaque téléchargement :
///   1. récupère les infos (cache de l'analyse si récent) ;
///   2. choisit les pistes (formats.planAudio) et résout les formats exacts ;
///   3. lance yt-dlp avec --load-info-json dans un dossier de travail privé
///      (les fichiers partiels y restent pour la reprise) ;
///   4. range le résultat dans Téléchargements/YT-NEXUS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'analyse.dart' as analyse;
import 'erreurs.dart' as erreurs;
import 'formats.dart' as formats;
import 'langues.dart' as langues;
import 'miniatures.dart' as miniatures;
import 'natif.dart';
import 'reglages.dart';

const enCours = {'analyse', 'telechargement', 'traitement', 'attente_relance'};
const actifs = {...enCours, 'en_attente', 'programme'};
const finis = {'termine', 'erreur', 'annule'};

const phasesPp = {
  'Merger': 'Fusion des pistes', 'FFmpegMerger': 'Fusion des pistes',
  'FFmpegExtractAudio': 'Conversion audio', 'ExtractAudio': 'Conversion audio',
  'EmbedSubtitle': 'Intégration des sous-titres', 'FFmpegEmbedSubtitle': 'Intégration des sous-titres',
  'EmbedThumbnail': 'Ajout de la miniature', 'FFmpegMetadata': 'Métadonnées', 'Metadata': 'Métadonnées',
  'SponsorBlock': 'Suppression des sponsors', 'ModifyChapters': 'Découpage des segments',
  'FFmpegSplitChapters': 'Découpage en chapitres', 'SplitChapters': 'Découpage en chapitres',
  'FFmpegVideoRemuxer': 'Conversion du conteneur', 'FFmpegSubtitlesConvertor': 'Conversion des sous-titres',
  'FFmpegThumbnailsConvertor': 'Conversion de la miniature', 'ThumbnailsConvertor': 'Conversion de la miniature',
};

double _maintenant() => DateTime.now().millisecondsSinceEpoch / 1000;

String _id() {
  final r = Random();
  return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
}

/// Élément à ajouter à la file.
class Ajout {
  final String url;
  final String? titre, miniature, chaine, groupe;
  final int? duree;
  const Ajout(this.url, {this.titre, this.miniature, this.chaine, this.duree, this.groupe});
}

class Tache {
  String id, url, titre, statut, phase = '', message = '', erreur = '', pistes = '';
  String? miniature, chaine, groupe;
  int? duree, eta;
  Map<String, dynamic> options;
  double progression = 0, vitesse = 0, cree, tentatives = 0;
  double? fin, programme;
  int telecharge = 0, total = 0, tailleFichier = 0;
  List<FichierPublie> fichiers = [];

  // interne
  String? arret; // "pause" | "annule" | "reattendre" (Wi-Fi perdu)
  Completer<void>? _reveil;
  List<(String, int, String)> parties = []; // (format_id, taille, libellé)

  Tache(this.url, this.options, {String? titre, this.miniature, this.chaine, this.duree, this.groupe})
      : id = _id(),
        titre = titre ?? url,
        statut = options['programme'] != null ? 'programme' : 'en_attente',
        programme = (options['programme'] as num?)?.toDouble(),
        cree = _maintenant();

  String get dossierTravail => '${Natif.dossierTravail}/$id';
  FichierPublie? get fichierPrincipal {
    if (fichiers.isEmpty) return null;
    final medias = fichiers.where((f) => f.mime.startsWith('video') || f.mime.startsWith('audio'));
    return medias.isNotEmpty ? medias.reduce((a, b) => a.taille >= b.taille ? a : b) : fichiers.first;
  }

  Map<String, dynamic> versJson() => {
        'id': id, 'url': url, 'titre': titre, 'miniature': miniature, 'chaine': chaine, 'duree': duree,
        'groupe': groupe, 'options': options, 'statut': statut, 'progression': progression,
        'telecharge': telecharge, 'total': total, 'message': message, 'erreur': erreur,
        'fichiers': [for (final f in fichiers) f.versJson()], 'taille_fichier': tailleFichier, 'pistes': pistes,
        'cree': cree, 'fin': fin, 'programme': programme, 'tentatives': tentatives, 'phase': phase,
      };

  factory Tache.depuis(Map d) {
    final t = Tache(d['url'], ((d['options'] as Map?) ?? {}).cast<String, dynamic>());
    t
      ..id = d['id'] ?? t.id
      ..titre = d['titre'] ?? t.url
      ..miniature = d['miniature']
      ..chaine = d['chaine']
      ..duree = (d['duree'] as num?)?.toInt()
      ..groupe = d['groupe']
      ..statut = d['statut'] ?? 'en_attente'
      ..progression = ((d['progression'] ?? 0) as num).toDouble()
      ..telecharge = ((d['telecharge'] ?? 0) as num).toInt()
      ..total = ((d['total'] ?? 0) as num).toInt()
      ..message = d['message'] ?? ''
      ..erreur = d['erreur'] ?? ''
      ..fichiers = [for (final f in (d['fichiers'] as List?) ?? []) FichierPublie.depuis(f as Map)]
      ..tailleFichier = ((d['taille_fichier'] ?? 0) as num).toInt()
      ..pistes = d['pistes'] ?? ''
      ..cree = ((d['cree'] ?? 0) as num).toDouble()
      ..fin = (d['fin'] as num?)?.toDouble()
      ..programme = (d['programme'] as num?)?.toDouble()
      ..tentatives = ((d['tentatives'] ?? 0) as num).toDouble()
      ..phase = d['phase'] ?? '';
    return t;
  }
}

class Gestionnaire extends ChangeNotifier {
  final taches = <Tache>[];
  Timer? _minuteur, _sauvegarde;
  double _derniereNotif = 0, _dernierReseau = 0;
  String _reseau = 'inconnu';
  bool _serviceActif = false;
  bool _ecriture = false, _aRecrire = false;

  /// Nombre de téléchargements actifs et débit total : écoutés par l'en-tête et la barre
  /// de navigation, qui ne se reconstruisent ainsi que si la valeur change vraiment.
  final nbActifsN = ValueNotifier<int>(0);
  final debitN = ValueNotifier<double>(0);

  /// Incrémenté à chaque changement autre que l'avancement d'un téléchargement
  /// (ajout, fin, suppression…) : la bibliothèque n'a pas à se reconstruire 4 fois par seconde.
  final statuts = ValueNotifier<int>(0);

  File get _fichier => File('${Natif.dossierFichiers}/taches.json');

  Iterable<Tache> get enCoursListe => taches.where((t) => actifs.contains(t.statut) || t.statut == 'pause');
  int get nbActifs => taches.where((t) => actifs.contains(t.statut)).length;
  double get debit => taches.where((t) => t.statut == 'telechargement').fold(0.0, (a, t) => a + t.vitesse);

  Future<void> demarrer() async {
    try {
      final donnees = jsonDecode(await _fichier.readAsString()) as List;
      for (final d in donnees) {
        final t = Tache.depuis(d as Map);
        if (enCours.contains(t.statut)) {
          // Interrompu par la fermeture de l'app : on reprend automatiquement.
          t
            ..statut = 'en_attente'
            ..phase = ''
            ..message = 'Reprise après redémarrage';
        }
        taches.add(t);
      }
    } catch (_) {}
    _minuteur = Timer.periodic(const Duration(milliseconds: 700), (_) => _repartir());
    unawaited(_verifierFichiers());
    unawaited(_garderMiniatures());
  }

  /// Miniatures des tâches gardées sur le disque (visibles hors ligne), les autres supprimées.
  Future<void> _garderMiniatures() async {
    await miniatures.nettoyer(taches.map((t) => t.miniature));
    for (final t in taches.toList()) {
      await miniatures.garder(t.miniature);
    }
  }

  /// Signale les fichiers supprimés depuis une autre app.
  Future<void> _verifierFichiers() async {
    for (final t in taches.where((t) => t.statut == 'termine' && t.fichiers.isNotEmpty).toList()) {
      final p = t.fichierPrincipal;
      if (p != null && !await Natif.existe(p.uri)) t.message = 'Fichier déplacé ou supprimé';
    }
    _touche();
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    super.dispose();
  }

  // ── état ────────────────────────────────────────────────────────────
  void _touche({bool sauver = false, bool progres = false}) {
    if (!progres) statuts.value++;
    nbActifsN.value = nbActifs;
    debitN.value = debit;
    notifyListeners();
    _majService();
    if (sauver) {
      _sauver();
    } else {
      _sauvegarde ??= Timer(const Duration(seconds: 5), _sauver);
    }
  }

  /// Écritures l'une après l'autre : deux écritures simultanées dans le même fichier
  /// temporaire pouvaient produire un JSON tronqué et faire perdre toute la liste.
  Future<void> _sauver() async {
    _sauvegarde?.cancel();
    _sauvegarde = null;
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
          await tmp.writeAsString(jsonEncode([for (final t in taches) t.versJson()]), flush: true);
          await tmp.rename(_fichier.path);
        } catch (_) {}
      } while (_aRecrire);
    } finally {
      _ecriture = false;
    }
  }

  /// Notification de premier plan : garde l'app en vie pendant les téléchargements.
  void _majService() {
    final actives = taches.where((t) => actifs.contains(t.statut)).toList();
    if (actives.isEmpty) {
      if (_serviceActif) {
        _serviceActif = false;
        _derniereNotif = 0;
        Natif.service(false);
      }
      return;
    }
    _serviceActif = true;
    final m = _maintenant();
    if (m - _derniereNotif < 1) return;
    _derniereNotif = m;
    final dl = actives.where((t) => enCours.contains(t.statut)).toList();
    final premier = dl.isNotEmpty ? dl.first : actives.first;
    final prog = dl.isEmpty ? -1 : (dl.fold(0.0, (a, t) => a + t.progression) / dl.length).round();
    final titre = actives.length == 1 ? premier.titre : '${actives.length} téléchargements';
    final texte = dl.isEmpty
        ? 'En attente'
        : [premier.phase, if (debit > 0) '${formaterTaille(debit.round())}/s'].where((s) => s.isNotEmpty).join(' · ');
    Natif.service(true, titre: titre, texte: texte, progression: prog);
  }

  void _maj(Tache t, {bool sauver = false}) => _touche(sauver: sauver);

  // ── actions ─────────────────────────────────────────────────────────
  List<Tache> ajouter(List<Ajout> elements, Map<String, dynamic> options) {
    // Les options non précisées prennent les réglages actuels
    options = {
      for (final k in const ['type', 'qualite', 'conteneur', 'format_audio', 'qualite_audio', 'langue_audio', 'garder_vo', 'sponsorblock'])
        k: reglages[k],
      ...options,
    };
    final nouvelles = <Tache>[];
    for (final e in elements) {
      if (e.url.isEmpty) continue;
      final t = Tache(e.url, Map.of(options),
          titre: e.titre, miniature: e.miniature, chaine: e.chaine, duree: e.duree, groupe: e.groupe);
      taches.insert(0, t);
      nouvelles.add(t);
    }
    _touche(sauver: true);
    _repartir();
    return nouvelles;
  }

  Tache? _get(String id) => taches.where((t) => t.id == id).firstOrNull;

  void _reveiller(Tache t) {
    if (t._reveil != null && !t._reveil!.isCompleted) t._reveil!.complete();
  }

  void pause(String id) {
    final t = _get(id);
    if (t == null) return;
    if (enCours.contains(t.statut)) {
      t.arret = 'pause';
      _reveiller(t);
      Natif.arreter(t.id);
    } else if (t.statut == 'en_attente' || t.statut == 'programme') {
      t
        ..statut = 'pause'
        ..phase = '';
      _maj(t, sauver: true);
    }
  }

  void reprendre(String id) {
    final t = _get(id);
    if (t == null || !{'pause', 'erreur', 'annule'}.contains(t.statut)) return;
    if (t.statut != 'pause') {
      t
        ..tentatives = 0
        ..progression = 0;
    }
    t
      ..statut = 'en_attente'
      ..erreur = ''
      ..message = ''
      ..phase = '';
    _maj(t, sauver: true);
  }

  void relancer(String id) {
    final t = _get(id);
    if (t == null || enCours.contains(t.statut)) return;
    t
      ..tentatives = 0
      ..statut = 'en_attente'
      ..erreur = ''
      ..message = ''
      ..phase = ''
      ..progression = 0
      ..fichiers = []
      ..telecharge = 0;
    _maj(t, sauver: true);
  }

  void annuler(String id) {
    final t = _get(id);
    if (t == null) return;
    if (enCours.contains(t.statut)) {
      t.arret = 'annule';
      _reveiller(t);
      Natif.arreter(t.id);
    } else if ({'en_attente', 'programme', 'pause'}.contains(t.statut)) {
      _menage(t);
      t
        ..statut = 'annule'
        ..phase = ''
        ..vitesse = 0
        ..eta = null;
      _maj(t, sauver: true);
    }
  }

  Future<void> supprimer(String id, {bool fichier = false}) async {
    final t = _get(id);
    if (t == null) return;
    if (enCours.contains(t.statut)) {
      t.arret = 'annule';
      _reveiller(t);
      await Natif.arreter(t.id);
    } else if (t.statut != 'termine') {
      _menage(t);
    }
    if (fichier) {
      for (final f in t.fichiers) {
        try {
          await Natif.supprimerFichier(f.uri);
        } catch (_) {}
      }
    }
    taches.remove(t);
    _touche(sauver: true);
  }

  void actionGlobale(String action) {
    for (final t in taches.toList()) {
      switch (action) {
        case 'pause_tout' when actifs.contains(t.statut):
          pause(t.id);
        case 'reprendre_tout' when t.statut == 'pause':
          reprendre(t.id);
        case 'relancer_erreurs' when t.statut == 'erreur':
          relancer(t.id);
        case 'vider_termines' when t.statut == 'termine':
          supprimer(t.id);
        case 'vider_echecs' when t.statut == 'erreur' || t.statut == 'annule':
          supprimer(t.id);
      }
    }
  }

  /// Dossiers de travail qui ne servent plus (hors téléchargements actifs ou en pause).
  List<Directory> _orphelins() {
    final garder = {for (final t in taches) if (actifs.contains(t.statut) || t.statut == 'pause') t.id};
    try {
      return Directory(Natif.dossierTravail)
          .listSync()
          .whereType<Directory>()
          .where((d) => !garder.contains(d.uri.pathSegments.where((s) => s.isNotEmpty).last))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static int _tailleDossier(Directory d) {
    var n = 0;
    try {
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        n += f.lengthSync();
      }
    } catch (_) {}
    return n;
  }

  /// Octets occupés par les fichiers temporaires (partiels, caches d'analyse).
  int tailleTemporaires() {
    var n = _orphelins().fold(0, (a, d) => a + _tailleDossier(d));
    final infos = Directory('${Natif.dossierCache}/infos');
    if (infos.existsSync()) n += _tailleDossier(infos);
    return n;
  }

  /// Comme [tailleTemporaires], sans bloquer l'interface (parcours dans un autre isolate).
  Future<int> tailleTemporairesAsync() {
    final garder = {for (final t in taches) if (actifs.contains(t.statut) || t.statut == 'pause') t.id};
    final travail = Natif.dossierTravail, infos = '${Natif.dossierCache}/infos';
    return compute(_tailleTemporairesIsolat, (travail, infos, garder));
  }

  /// Supprime les temporaires ; renvoie les octets libérés.
  int viderTemporaires() {
    final n = tailleTemporaires();
    for (final d in _orphelins()) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
    final infos = Directory('${Natif.dossierCache}/infos');
    try {
      if (infos.existsSync()) {
        final garder = {for (final t in taches) if (actifs.contains(t.statut) || t.statut == 'pause') '${t.id}.json'};
        for (final f in infos.listSync().whereType<File>()) {
          if (!garder.contains(f.uri.pathSegments.last)) f.deleteSync();
        }
      }
    } catch (_) {}
    return n;
  }

  /// Rapport pour comprendre les échecs (à copier/coller).
  String rapport() {
    final b = StringBuffer('YT-NEXUS ${Natif.versionApp} · yt-dlp ${Natif.version}\n')
      ..writeln('Android · réseau : $_reseau · Wi-Fi seul : ${reglages['wifi_seulement']} · éco données : ${reglages['eco_donnees']}')
      ..writeln('Tâches : ${taches.length} (erreurs : ${taches.where((t) => t.statut == 'erreur').length})');
    for (final t in taches.where((t) => t.statut == 'erreur').take(10)) {
      b
        ..writeln('\n— ${t.titre}')
        ..writeln('  ${t.url}')
        ..writeln('  options : ${jsonEncode(t.options)}')
        ..writeln('  erreur : ${t.erreur.split('\n').take(6).join(' | ')}');
    }
    return b.toString();
  }

  /// Supprime les fichiers partiels d'un téléchargement abandonné.
  void _menage(Tache t) {
    try {
      final d = Directory(t.dossierTravail);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    try {
      File('${Natif.dossierCache}/infos/${t.id}.json').deleteSync();
    } catch (_) {}
  }

  // ── exécution ───────────────────────────────────────────────────────
  /// Dans la plage horaire choisie (ex. 23:00 → 07:00, qui peut passer minuit) ?
  bool _dansLaPlage() {
    if (reglages['plage_active'] != true) return true;
    final d = (reglages['plage_debut'] as num).toInt(), f = (reglages['plage_fin'] as num).toInt();
    final n = DateTime.now();
    final h = n.hour * 60 + n.minute;
    if (d == f) return true;
    return d < f ? h >= d && h < f : h >= d || h < f;
  }

  static String heure(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// Raison pour laquelle aucun téléchargement ne doit tourner maintenant (null = libre).
  String? get raisonAttente {
    if (reglages['wifi_seulement'] == true && (_reseau == 'mobile' || _reseau == 'inconnu')) return 'En attente du Wi-Fi';
    if (!_dansLaPlage()) {
      return 'En attente de la plage ${heure((reglages['plage_debut'] as num).toInt())}–${heure((reglages['plage_fin'] as num).toInt())}';
    }
    return null;
  }

  void _repartir() {
    final max = (reglages['simultanes'] as num).toInt();
    var actives = taches.where((t) => enCours.contains(t.statut)).length;
    final m = _maintenant();
    var change = false;
    if (reglages['wifi_seulement'] != true) {
      _reseau = 'inconnu';
      _dernierReseau = 0;
    } else if (m - _dernierReseau >= 4) {
      _dernierReseau = m;
      Natif.reseau().then((r) => _reseau = r).catchError((_) => _reseau = 'autre');
    }
    final raison = raisonAttente;
    if (raison != null && reglages['wifi_seulement'] == true && _reseau == 'mobile') {
      // Wi-Fi perdu en cours de route : on met en attente (les fichiers partiels sont gardés)
      for (final t in taches.where((t) => enCours.contains(t.statut) && t.arret == null)) {
        t.arret = 'reattendre';
        _reveiller(t);
        Natif.arreter(t.id);
      }
    }
    for (final t in taches.where((t) => t.statut == 'en_attente')) {
      final voulue = raison ?? '';
      if (t.phase != voulue && (voulue.isNotEmpty || t.phase.startsWith('En attente de'))) {
        t.phase = voulue;
        change = true;
      }
    }
    for (final t in taches) {
      if (t.statut == 'programme' && (t.programme ?? 0) <= m) {
        t.statut = 'en_attente';
        change = true;
      }
    }
    // Les plus anciennes d'abord (la liste est affichée du plus récent au plus ancien)
    for (final t in taches.reversed) {
      if (actives >= max || raison != null) break;
      if (t.statut == 'en_attente') {
        t
          ..statut = 'analyse'
          ..arret = null;
        actives++;
        change = true;
        unawaited(_executer(t));
      }
    }
    if (change) _touche();
  }

  Future<void> _executer(Tache t) async {
    try {
      await _executerAvecRelances(t);
    } catch (e) {
      t
        ..statut = 'erreur'
        ..erreur = 'Erreur interne : $e'
        ..vitesse = 0
        ..eta = null;
      _maj(t, sauver: true);
    }
  }

  Future<void> _executerAvecRelances(Tache t) async {
    final relances = (reglages['relances'] as num).toInt();
    while (true) {
      var (ok, message, passagere) = (false, '', false);
      if (t.arret == null) {
        t.tentatives++;
        (ok, message, passagere) = await _uneTentative(t);
      }
      if (t.arret == 'pause') {
        t
          ..statut = 'pause'
          ..phase = ''
          ..vitesse = 0
          ..eta = null;
        return _maj(t, sauver: true);
      }
      if (t.arret == 'reattendre') {
        t
          ..statut = 'en_attente'
          ..arret = null
          ..phase = ''
          ..vitesse = 0
          ..eta = null;
        return _maj(t, sauver: true);
      }
      if (t.arret == 'annule') {
        _menage(t);
        t
          ..statut = 'annule'
          ..phase = ''
          ..vitesse = 0
          ..eta = null;
        return _maj(t, sauver: true);
      }
      if (ok) return _terminer(t);
      if (passagere && t.tentatives <= relances) {
        final attente = min(60, 5 * pow(2, t.tentatives - 1).toInt());
        t
          ..statut = 'attente_relance'
          ..vitesse = 0
          ..eta = null
          ..phase = 'Nouvelle tentative dans $attente s (${t.tentatives.toInt()}/$relances)'
          ..message = message;
        _maj(t);
        analyse.oublier(t.url); // liens peut-être expirés (403)
        t._reveil = Completer();
        await Future.any([t._reveil!.future, Future.delayed(Duration(seconds: attente))]);
        continue;
      }
      t
        ..statut = 'erreur'
        ..erreur = message
        ..phase = ''
        ..vitesse = 0
        ..eta = null;
      return _maj(t, sauver: true);
    }
  }

  Future<void> _terminer(Tache t) async {
    t
      ..statut = 'traitement'
      ..phase = 'Enregistrement dans Téléchargements…';
    _maj(t);
    String sous = '';
    if (t.groupe != null && reglages['sous_dossier_playlist'] == true) {
      sous = t.groupe!.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
      if (sous.length > 120) sous = sous.substring(0, 120);
    }
    try {
      t.fichiers = await Natif.publier(t.dossierTravail, sous);
    } catch (e) {
      t
        ..statut = 'erreur'
        ..erreur = "Impossible d'enregistrer le fichier : $e"
        ..phase = '';
      return _maj(t, sauver: true);
    }
    t
      ..statut = 'termine'
      ..progression = 100
      ..phase = ''
      ..vitesse = 0
      ..eta = null
      ..tailleFichier = t.fichiers.fold(0, (a, f) => a + f.taille)
      ..fin = _maintenant()
      ..erreur = ''
      ..message = '';
    _maj(t, sauver: true);
    unawaited(miniatures.garder(t.miniature));
    try {
      File('${Natif.dossierCache}/infos/${t.id}.json').deleteSync();
    } catch (_) {}
    if (reglages['notifications'] == true) Natif.notifier('Téléchargement terminé', t.titre);
  }

  /// (réussi, message d'erreur, erreur passagère ?)
  Future<(bool, String, bool)> _uneTentative(Tache t) async {
    var o = t.options;
    t
      ..statut = 'analyse'
      ..phase = 'Analyse de la vidéo'
      ..erreur = '';
    _maj(t);
    final Map<String, dynamic> info;
    try {
      info = await analyse.infoComplete(t.url);
    } on analyse.ErreurAnalyse catch (e) {
      return (false, e.message, e.passagere);
    }
    if (t.arret != null) return (false, '', false);
    if (info['live_status'] == 'is_live') {
      return (false, "Les directs en cours ne sont pas pris en charge : attends la fin du live.", false);
    }

    // Économie de données : qualité plafonnée tant qu'on est sur le réseau mobile
    if (reglages['eco_donnees'] == true && o['type'] != 'audio') {
      final plafond = int.tryParse('${reglages['eco_qualite']}') ?? 480;
      final voulue = int.tryParse('${o['qualite'] ?? reglages['qualite']}');
      var mobile = false;
      try {
        mobile = await Natif.reseau() == 'mobile';
      } catch (_) {}
      if (mobile && (voulue == null || voulue > plafond)) {
        o = {...o, 'qualite': '$plafond'};
        t.message = 'Données mobiles : qualité limitée à ${plafond}p';
      }
    }

    // Pistes audio
    final langue = (o['langue_audio'] ?? reglages['langue_audio']) as String;
    final garderVo = (o['garder_vo'] ?? reglages['garder_vo']) == true && o['type'] != 'audio';
    final (piste, originale, deux) = formats.planAudio(info, langue, garderVo);
    final sel = formats.selecteur(o, piste, originale, deux);
    final tri = formats.tri(o);

    final dossierInfos = Directory('${Natif.dossierCache}/infos')..createSync(recursive: true);
    final cheminInfo = '${dossierInfos.path}/${t.id}.json';
    await File(cheminInfo).writeAsString(jsonEncode(info));
    Directory(t.dossierTravail).createSync(recursive: true);

    // Résolution exacte des formats (tailles, ordre des parties) : simulation, sans réseau
    final conteneur = (o['conteneur'] ?? reglages['conteneur']) as String;
    final sim = await Natif.executer('${t.id}-sim', [
      '--load-info-json', cheminInfo, '--ignore-config', '--no-warnings',
      '-f', sel, '-S', tri.join(','), '--audio-multistreams', '--merge-output-format', conteneur,
      '-O', '%(requested_formats)j', '-O', '%(format_id)s\t%(height)s\t%(language)s\t%(filesize,filesize_approx)s',
    ]);
    if (t.arret != null) return (false, '', false);
    if (!sim.ok) {
      final (message, passagere) = erreurs.analyser(sim.erreur.isNotEmpty ? sim.erreur : sim.sortie, sim.code);
      return (false, message, passagere);
    }
    t.parties = [];
    final lignesSim = sim.sortie.trim().split('\n');
    List? demandes;
    try {
      final d = jsonDecode(lignesSim.first);
      if (d is List) demandes = d;
    } catch (_) {}
    String libelle(String? hauteur, String? code, bool video) => video
        ? 'Vidéo ${hauteur ?? ''}p'.replaceAll(' p', '')
        : (code != null && code.isNotEmpty && code != 'NA' ? 'Audio ${langues.drapeau(code)} ${langues.nom(code)}' : 'Audio');
    if (demandes != null) {
      for (final f in demandes.cast<Map>()) {
        final video = formats.estVideo(f.cast<String, dynamic>());
        t.parties.add((
          '${f['format_id']}',
          formats.taille(f.cast<String, dynamic>()),
          libelle('${f['height']}', f['language'] as String?, video),
        ));
      }
    } else if (lignesSim.length > 1) {
      final c = lignesSim[1].split('\t');
      final h = c.length > 1 && c[1] != 'NA' ? c[1] : null;
      t.parties.add((c[0], c.length > 3 ? int.tryParse(c[3]) ?? 0 : 0, libelle(h, c.length > 2 ? c[2] : null, h != null)));
    }

    // Description des pistes et messages
    var msg = '';
    String desc;
    if (piste != null) {
      desc = '${langues.drapeau(piste)} ${langues.nom(piste)}';
      if (deux) desc += ' + ${langues.drapeau(originale)} VO';
    } else {
      desc = originale != null ? '${langues.drapeau(originale)} ${langues.nom(originale)}' : 'Piste unique';
      if (langue != 'original' && !langues.memeLangue(originale, langue)) {
        msg = 'Pas de doublage ${langues.nom(langue).toLowerCase()} sur YouTube pour cette vidéo';
      }
    }
    final secours = piste == null &&
        langue != 'original' &&
        !langues.memeLangue(originale, langue) &&
        o['type'] != 'audio' &&
        reglages['sous_titres_secours'] == true;
    if (secours) msg += ' → sous-titres intégrés';
    t
      ..titre = (info['title'] ?? t.titre) as String
      ..miniature = t.miniature ?? analyse.miniature(info)
      ..chaine = (info['channel'] ?? info['uploader'] ?? t.chaine) as String?
      ..duree = (info['duration'] as num?)?.toInt() ?? t.duree
      ..pistes = desc
      ..total = t.parties.fold(0, (a, p) => a + p.$2);
    // Toujours remplacer : sinon « Accès refusé (403). Nouvelle tentative… » de la tentative
    // précédente reste affiché alors que la reprise télécharge normalement.
    t.message = msg;
    _maj(t);

    final cmd = _commande(t, o, sel, tri, cheminInfo, piste ?? originale, deux ? originale : null, secours, langue);
    return _lancer(t, cmd);
  }

  String _quote(String s) => "'${s.replaceAll("'", "'\"'\"'")}'";

  List<String> _commande(Tache t, Map<String, dynamic> o, String sel, List<String> tri, String cheminInfo,
      String? piste, String? vo, bool secours, String langue) {
    final r = reglages;
    final audio = o['type'] == 'audio';
    final conteneur = (o['conteneur'] ?? r['conteneur']) as String;
    final cmd = <String>[
      '--load-info-json', cheminInfo, '--ignore-config', '--no-simulate',
      '-f', sel, '-S', tri.join(','),
      '-P', t.dossierTravail, '-o', r['modele_nom'] as String,
      '--quiet', '--progress', '--newline', '--no-warnings', '--no-mtime', '--no-playlist',
      '--progress-template', 'download:NEXUS %(progress)j\t%(info.format_id)s',
      '--progress-template', 'postprocess:NEXUSPP %(progress.postprocessor)s\t%(progress.status)s',
      '--print', 'after_move:NEXUSFICHIER %(filepath)s',
      '-N', '${r['fragments']}', '--http-chunk-size', '10M',
      '--retries', '10', '--fragment-retries', '10',
      '--retry-sleep', 'http:exp=1:30', '--retry-sleep', 'fragment:exp=1:30',
      '--socket-timeout', '30', '--trim-filenames', '120',
      ...r.argsAuth(),
    ];
    if ((r['limite_vitesse'] as String).isNotEmpty) cmd.addAll(['-r', r['limite_vitesse']]);
    if (r['metadonnees'] == true) cmd.addAll(['--embed-metadata', '--embed-chapters']);
    if (r['miniature'] == true && conteneur != 'webm') cmd.add('--embed-thumbnail');

    if (audio) {
      final fa = (o['format_audio'] ?? r['format_audio']) as String;
      cmd.add('-x');
      if (fa != 'original') {
        cmd.addAll(['--audio-format', fa, '--audio-quality', '${o['qualite_audio'] ?? r['qualite_audio']}']);
      }
    } else {
      cmd.addAll(['--audio-multistreams', '--merge-output-format', conteneur]);
      if (piste != null && conteneur != 'webm') {
        // Pistes nommées ; seule la 1re (langue voulue) est « par défaut ».
        String nommer(int i, String nom) =>
            ' -metadata:s:a:$i title=${_quote(nom)} -metadata:s:a:$i handler_name=${_quote(nom)}';
        var pp = nommer(0, langues.nom(piste)).trim();
        if (vo != null) {
          pp += nommer(1, '${langues.nom(vo)} (VO)');
          pp += ' -disposition:a 0 -disposition:a:0 default';
        }
        cmd.addAll(['--postprocessor-args', 'Merger:$pp']);
      }
      final sousTitres = <String>[...((o['sous_titres'] as List?) ?? []).cast<String>()];
      if (secours) {
        final b = langues.base(langue);
        sousTitres.addAll([b, '$b-.*']);
      }
      if (sousTitres.isNotEmpty) {
        cmd.addAll(['--write-subs', '--sub-langs', sousTitres.toSet().join(','), '--sleep-subtitles', '1']);
        if (secours || o['sous_titres_auto'] == true) cmd.add('--write-auto-subs');
        cmd.addAll(o['sous_titres_fichier'] == true ? ['--convert-subs', 'srt'] : ['--embed-subs']);
      }
      if (o['chapitres_separes'] == true) {
        cmd.addAll(['--split-chapters', '-o', 'chapter:%(title)s/%(section_number)02d - %(section_title)s.%(ext)s']);
      }
    }
    if ((o['sponsorblock'] ?? r['sponsorblock']) == true) {
      cmd.addAll(['--sponsorblock-remove', 'sponsor,selfpromo,interaction']);
    }
    final debut = ((o['debut'] ?? '') as String).trim(), fin = ((o['fin'] ?? '') as String).trim();
    if (debut.isNotEmpty || fin.isNotEmpty) {
      cmd.addAll([
        '--download-sections', '*${debut.isEmpty ? '0' : debut}-${fin.isEmpty ? 'inf' : fin}',
        '--force-keyframes-at-cuts',
      ]);
    }
    return cmd;
  }

  Future<(bool, String, bool)> _lancer(Tache t, List<String> cmd) async {
    final erreursLignes = <String>[];
    String? fichier;
    var derniereMaj = 0.0;
    t
      ..statut = 'telechargement'
      ..phase = 'Connexion…';
    _maj(t);
    final r = await Natif.executer(t.id, cmd, ligne: (ligne) {
      if (ligne.startsWith('NEXUS ')) {
        // yt-dlp envoie des dizaines de lignes par seconde : inutile de toutes les décoder
        final m = _maintenant();
        final fin = ligne.contains('"finished"');
        if ((fin || m - derniereMaj > 0.25) && _ligneProgression(t, ligne)) {
          derniereMaj = m;
          _touche(progres: !fin);
        }
      } else if (ligne.startsWith('NEXUSPP ')) {
        _lignePp(t, ligne);
      } else if (ligne.startsWith('NEXUSFICHIER ')) {
        fichier = ligne.substring('NEXUSFICHIER '.length).trim();
      } else if (ligne.trim().isNotEmpty) {
        erreursLignes.add(ligne.trimRight());
        if (erreursLignes.length > 60) erreursLignes.removeAt(0);
      }
    });
    if (t.arret != null || r.annule) return (false, '', false);
    if (r.code == 0 && fichier != null) return (true, '', false);
    var texte = [...erreursLignes, r.erreur].where((s) => s.isNotEmpty).join('\n');
    if (r.code == 0 && fichier == null) texte = texte.isEmpty ? 'Aucun fichier produit.' : texte;
    final (message, passagere) = erreurs.analyser(texte, r.code);
    return (false, message, passagere);
  }

  bool _ligneProgression(Tache t, String ligne) {
    final Map p;
    final brut = ligne.substring('NEXUS '.length);
    final tab = brut.lastIndexOf('\t');
    final formatId = tab >= 0 ? brut.substring(tab + 1).trim() : '';
    try {
      p = jsonDecode(tab >= 0 ? brut.substring(0, tab) : brut) as Map;
    } catch (_) {
      return false;
    }
    var idx = t.parties.indexWhere((part) => part.$1 == formatId);
    if (idx < 0) idx = 0;
    final n = max(1, t.parties.length);
    var totalPart = ((p['total_bytes'] ?? p['total_bytes_estimate'] ?? 0) as num).toInt();
    var fait = ((p['downloaded_bytes'] ?? 0) as num).toInt();
    if (p['status'] == 'finished') {
      totalPart = totalPart == 0 ? fait : totalPart;
      fait = totalPart;
    }
    final tailles = [for (final part in t.parties) part.$2];
    if (idx < tailles.length && totalPart > 0) tailles[idx] = totalPart;
    double prog;
    if (t.parties.isNotEmpty && tailles.every((x) => x > 0)) {
      final total = tailles.fold(0, (a, b) => a + b);
      final avant = tailles.take(idx).fold(0, (a, b) => a + b);
      prog = (avant + fait) / total * 100;
      t
        ..total = total
        ..telecharge = avant + fait;
    } else {
      final frac = totalPart > 0 ? fait / totalPart : 0;
      prog = (idx + frac) / n * 100;
      t.telecharge = fait;
    }
    t.progression = (max(t.statut == 'telechargement' ? t.progression : 0, min(prog, 99.5)) * 10).round() / 10;
    t.vitesse = ((p['speed'] ?? 0) as num).toDouble();
    num? eta = p['eta'] as num?;
    if (t.vitesse > 0 && t.total > 0) eta = max(0, (t.total - t.telecharge) / t.vitesse);
    t.eta = eta?.toInt();
    final lib = idx < t.parties.length ? t.parties[idx].$3 : 'Téléchargement';
    t
      ..phase = n > 1 ? '$lib (${idx + 1}/$n)' : lib
      ..statut = 'telechargement';
    return true;
  }

  void _lignePp(Tache t, String ligne) {
    final c = ligne.substring('NEXUSPP '.length).trim().split('\t');
    if (c.length > 1 && c[1] == 'started' && c[0] != 'MoveFiles') {
      t
        ..statut = 'traitement'
        ..phase = '${phasesPp[c[0]] ?? c[0]}…'
        ..vitesse = 0
        ..eta = null
        ..progression = max(t.progression, 99.5);
      _touche();
    }
  }
}

int _tailleTemporairesIsolat((String, String, Set<String>) a) {
  final (travail, infos, garder) = a;
  var n = 0;
  int taille(Directory d) {
    var x = 0;
    try {
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        x += f.lengthSync();
      }
    } catch (_) {}
    return x;
  }

  try {
    for (final d in Directory(travail).listSync().whereType<Directory>()) {
      if (!garder.contains(d.uri.pathSegments.where((s) => s.isNotEmpty).last)) n += taille(d);
    }
  } catch (_) {}
  final i = Directory(infos);
  if (i.existsSync()) n += taille(i);
  return n;
}

String formaterTaille(num octets) {
  if (octets <= 0) return '—';
  const unites = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var v = octets.toDouble();
  var i = 0;
  while (v >= 1024 && i < unites.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1).replaceAll('.', ',')} ${unites[i]}';
}

String formaterDuree(num? s) {
  if (s == null) return '';
  final t = s.toInt();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, sec = t % 60;
  String d(int x) => x.toString().padLeft(2, '0');
  return h > 0 ? '$h:${d(m)}:${d(sec)}' : '$m:${d(sec)}';
}

final gestionnaire = Gestionnaire();
