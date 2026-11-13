/// Lecteur vidéo « Liquid Glass » intégré pour les vidéos téléchargées.
///
/// Respecte strictement la disposition en bas d'écran : heure à gauche, boutons
/// d'action (format, rotation réversible, boucle A-B, file, verrou) alignés à
/// droite sur la même ligne que le temps, et barre de progression juste en dessous.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../moteur/analyse.dart' as analyse;
import '../moteur/gouts.dart';
import '../moteur/langues.dart' as langues;
import '../moteur/miniatures.dart' as miniatures;
import '../moteur/natif.dart';
import '../moteur/paroles.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'lecteur_audio.dart';
import 'theme.dart';

bool _estFichierAudio(Tache t) =>
    (t.fichierPrincipal?.mime.startsWith('audio') ?? false) || t.options['type'] == 'audio';

Future<void> ouvrirLecteur(BuildContext context, List<Tache> liste, int index) {
  if (liste.isEmpty) return Future.value();
  final i = index.clamp(0, liste.length - 1);
  final cible = liste[i];
  if (_estFichierAudio(cible)) {
    final audios = liste.where(_estFichierAudio).toList();
    final idxAudio = audios.indexOf(cible);
    return ouvrirLecteurAudio(context, liste: audios, index: idxAudio < 0 ? 0 : idxAudio);
  }
  if (moteurAudio.enLecture) moteurAudio.pause();
  final videos = liste.where((t) => !_estFichierAudio(t)).toList();
  final idxVideo = videos.indexOf(cible);
  return Navigator.of(context).push(PageRouteBuilder(
    pageBuilder: (_, _, _) => Lecteur(videos.isEmpty ? [cible] : videos, idxVideo < 0 ? 0 : idxVideo),
    transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
  ));
}

const _orientations = ['Automatique', 'Portrait', 'Paysage · deux sens'];
const _formats = ['Ajuster', 'Remplir', '16:9', '4:3', '21:9', 'Étirer'];
const _couleursSt = <String, (String, Color)>{
  'blanc': ('Blanc pur', Colors.white),
  'jaune': ('Cinéma or', Color(0xFFFFE066)),
  'cyan': ('Néon cyan', Color(0xFF7DF9FF)),
};

class Lecteur extends StatefulWidget {
  final List<Tache> liste;
  final int index;
  const Lecteur(this.liste, this.index, {super.key});

  @override
  State<Lecteur> createState() => _LecteurState();
}

class _LecteurState extends State<Lecteur> with SingleTickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  int _generation = 0;
  late final List<Tache> _file = List<Tache>.of(widget.liste);
  late int _index = widget.index.clamp(0, math.max(0, _file.length - 1));
  String? _erreur;

  bool _controles = true;
  bool _verrou = false;
  bool _boucle = false;
  bool _signale = false;
  bool _pip = false;
  bool _enLecture = false;
  bool _glisseBarre = false;
  bool _reste = false;
  bool _interaction = false;
  final _abos = <StreamSubscription>[];

  List<VideoAudioTrack> _pistes = [];
  List<ChapitreVideo> _chapitres = [];
  bool _chargeChapitresEnLigne = false;

  // Sous-titres multi-pistes synchronisés + style
  List<({String id, String label, FichierPublie fichier})> _sourcesSt = [];
  DonneesParoles? _donneesSt;
  String? _idStActif;
  int _stDecalageMs = 0;

  Timer? _masquer;
  Timer? _sommeil;
  DateTime? _finSommeil;
  int _sommeilMin = 0; // 0 = off, -1 = fin de cette vidéo, >0 = minutes

  // Préférences mémorisées
  int _orientation = _pref<num>('lecteur_orientation', 0).toInt().clamp(0, 2);
  double _vitesse = _pref<num>('lecteur_vitesse', 1.0).toDouble().clamp(0.25, 4.0);
  double _vitesseMaintien = _pref<num>('lecteur_vitesse_maintien', 2.0).toDouble().clamp(1.25, 4.0);
  bool _sousTitresActifs = _pref<bool>('lecteur_st', true);
  int _tailleSt = _pref<num>('lecteur_st_taille', 17).toInt().clamp(12, 32);
  bool _fondSt = _pref<bool>('lecteur_st_fond', true);
  String _couleurSt = _pref<String>('lecteur_st_couleur', 'blanc');
  int _margeSt = _pref<num>('lecteur_st_marge', 28).toInt().clamp(8, 120);
  int _format = _pref<num>('lecteur_format', 0).toInt().clamp(0, _formats.length - 1);
  int _saut = _pref<num>('lecteur_saut', 10).toInt().clamp(5, 120);
  bool _auto = _pref<bool>('lecteur_auto', true);
  bool _gestes = _pref<bool>('lecteur_gestes', true);
  double _nuit = _pref<num>('lecteur_nuit', 0.0).toDouble().clamp(0.0, 0.6);
  bool _miroir = _pref<bool>('lecteur_miroir', false);
  final bool _reprendreAuto = _pref<bool>('lecteur_reprendre', true);

  // Audio DSP (partagé avec Onde Studio via Natif.effetsAudio)
  bool _eqActif = _pref<bool>('audio_eq_actif', false);
  String _eqProfil = _pref<String>('audio_eq_profil', 'neutre');
  List<double> _bandes = _lireBandes();
  int _basses = _pref<num>('audio_basses', 0).toInt().clamp(0, 1000);
  double _gain = _pref<num>('audio_gain', 0.0).toDouble().clamp(0.0, 15.0);

  // Boucle A-B
  Duration? _a, _b;

  // Enchaînement suivant
  Timer? _compteur;
  int _compte = 0;
  bool _compteAnnule = false;

  // Gestes, zoom et HUD
  String? _indication;
  IconData? _iconeIndication;
  Timer? _finIndication;
  int _cumulSaut = 0;
  Timer? _finSaut;
  int _onde = 0; // -1 gauche, 1 droite, 0 aucune
  bool _poulsCentre = false;
  Timer? _finOnde;
  Timer? _finPoulsCentre;
  Duration? _cible;
  double? _ratioGlisseBarre;
  double _debutGlisse = 0;
  Duration _positionDebut = Duration.zero;
  double _luminosite = 0.5;
  double _volume = 1.0;
  double? _vitesseAvantAppuiLong;
  String? _barre; // 'lum' | 'vol'
  Timer? _finBarre;

  // Pinch zoom + pan libre (1.0x..3.5x)
  final _pointeurs = <int, Offset>{};
  double _distanceDebutPince = 0;
  double _zoomDebutPince = 1.0;
  Offset _milieuPincePrecedent = Offset.zero;
  double _zoom = 1.0;
  Offset _panZoom = Offset.zero;

  late final AnimationController _pouls =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  static T _pref<T>(String cle, T defaut) {
    final v = reglages[cle];
    return v is T ? v : defaut;
  }

  static List<double> _lireBandes() {
    final l = reglages['audio_eq_bandes'];
    if (l is List && l.length == 5) {
      return [for (final x in l) ((x as num?) ?? 0).toDouble().clamp(-1.0, 1.0)];
    }
    return [0.0, 0.0, 0.0, 0.0, 0.0];
  }

  void _retenir(String cle, dynamic v) => reglages.ecrireSansPrevenir(cle, v);

  Tache get _tache => _file[_index];
  bool get _audio => _tache.fichierPrincipal?.mime.startsWith('audio') ?? false;
  bool get _aSuivant => _index < _file.length - 1;
  bool get _aSousTitres => _sourcesSt.isNotEmpty;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Natif.luminosite().then((v) {
      if (mounted) _luminosite = v.clamp(0.0, 1.0);
    });
    _abos.add(Natif.commandesMedia.listen(_commande));
    _abos.add(Natif.pipEtat.listen((v) {
      if (mounted) setState(() => _pip = v);
    }));
    _charger();
  }

  @override
  void dispose() {
    _memoriserPosition();
    _masquer?.cancel();
    _sommeil?.cancel();
    _finIndication?.cancel();
    _finSaut?.cancel();
    _finOnde?.cancel();
    _finPoulsCentre?.cancel();
    _finBarre?.cancel();
    _compteur?.cancel();
    _pouls.dispose();
    for (final a in _abos) {
      a.cancel();
    }
    WakelockPlus.disable();
    Natif.mediaArreter();
    Natif.pipAuto(false, 16 / 9);
    _ctrl?.dispose();
    Natif.luminosite(-1);
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── chargement ──────────────────────────────────────────────────────
  Future<void> _charger() async {
    final generation = ++_generation;
    bool perime() => !mounted || generation != _generation;
    _memoriserPosition();
    _annulerCompte();
    final ancien = _ctrl;
    ancien?.removeListener(_maj);
    _enLecture = false;
    _interaction = false;
    _glisseBarre = false;
    _cible = null;
    _ratioGlisseBarre = null;
    if (_sommeilMin == -1) {
      _sommeil?.cancel();
      _sommeilMin = 0;
      _finSommeil = null;
    }

    // Chapitres sauvegardés ou déjà en cache RAM
    var ch = List<ChapitreVideo>.of(_tache.chapitres);
    if (ch.isEmpty && _tache.url.startsWith('http')) {
      final enCache = analyse.infoEnCache(_tache.url);
      if (enCache != null) {
        ch = extraireChapitresInfo(enCache);
        if (ch.isNotEmpty) gestionnaire.mettreAJourChapitres(_tache, ch);
      }
    }

    final sourcesSt = sourcesLocalesDisponibles(_tache);
    final decMap = (reglages['decalages_st'] as Map?) ?? const {};
    final stIdPref = ((reglages['pistes_st'] as Map?) ?? const {})[_tache.id] as String?;

    setState(() {
      _ctrl = null;
      _erreur = null;
      _pistes = [];
      _chapitres = ch;
      _chargeChapitresEnLigne = false;
      _sourcesSt = sourcesSt;
      _donneesSt = null;
      _idStActif = sourcesSt.isEmpty
          ? null
          : sourcesSt.any((s) => s.id == stIdPref)
              ? stIdPref
              : sourcesSt.first.id;
      _stDecalageMs = (decMap[_tache.id] as num?)?.toInt() ?? 0;
      _signale = false;
      _compteAnnule = false;
      _a = _b = null;
      _zoom = 1.0;
      _panZoom = Offset.zero;
    });

    await ancien?.dispose();
    if (perime()) return;
    final f = _tache.fichierPrincipal;
    if (f == null) {
      setState(() => _erreur = 'Fichier introuvable');
      return;
    }

    if (sourcesSt.isNotEmpty && _idStActif != null) {
      final src = sourcesSt.firstWhere((s) => s.id == _idStActif, orElse: () => sourcesSt.first);
      unawaited(_chargerPisteSousTitres(src, generation, silencieux: true));
    }

    final uri = Uri.parse(f.uri);
    final opts = VideoPlayerOptions(allowBackgroundPlayback: true);
    final ctrl = uri.scheme == 'content'
        ? VideoPlayerController.contentUri(uri, videoPlayerOptions: opts)
        : VideoPlayerController.file(
            File(f.chemin.isNotEmpty ? f.chemin : uri.toFilePath()),
            videoPlayerOptions: opts,
          );
    try {
      await ctrl.initialize();
    } catch (_) {
      ctrl.dispose();
      if (!perime()) {
        setState(() => _erreur = 'Lecture impossible : fichier déplacé, supprimé ou format non pris en charge.');
      }
      return;
    }
    if (perime()) {
      ctrl.dispose();
      return;
    }
    await ctrl.setLooping(_boucle);
    await ctrl.setPlaybackSpeed(_vitesse);
    await ctrl.setVolume(_volume);
    final pos = ((reglages['positions'] as Map?) ?? {})[_tache.id];
    if (_reprendreAuto && pos is int && pos > 10000 && pos < ctrl.value.duration.inMilliseconds * 0.95) {
      await ctrl.seekTo(Duration(milliseconds: pos));
    }
    if (perime()) {
      ctrl.dispose();
      return;
    }
    if (_reprendreAuto && pos is int && ctrl.value.position.inMilliseconds > 10000) {
      _indiquer('Reprise à ${_temps(Duration(milliseconds: pos))}', Icons.history_rounded);
    }
    ctrl.addListener(_maj);
    setState(() => _ctrl = ctrl);
    _orienter();
    await ctrl.play();
    if (perime()) return;
    _appliquerEffetsAudio();
    _synchro();
    _programmerMasquage();
    try {
      final p = await ctrl.getAudioTracks();
      if (!perime()) setState(() => _pistes = p);
    } catch (_) {}
  }

  Future<void> _chargerPisteSousTitres(
    ({String id, String label, FichierPublie fichier}) src,
    int gen, {
    bool silencieux = false,
  }) async {
    final d = await chargerFichierParolesLocal(
      src.fichier,
      labelSource: src.label,
      dureeTotaleSec: _tache.duree,
    );
    if (!mounted || gen != _generation) return;
    setState(() {
      _idStActif = src.id;
      _donneesSt = d;
    });
    final pistesMap = Map<String, dynamic>.of((reglages['pistes_st'] as Map?)?.cast<String, dynamic>() ?? {});
    pistesMap[_tache.id] = src.id;
    _retenir('pistes_st', pistesMap);
    if (!silencieux) {
      _indiquer(src.label, Icons.closed_caption_rounded);
    }
  }

  Future<void> _chargerChapitresEnLigne({StateSetter? majFeuille}) async {
    if (_chargeChapitresEnLigne || !_tache.url.startsWith('http')) return;
    setState(() => _chargeChapitresEnLigne = true);
    majFeuille?.call(() {});
    try {
      final info = await analyse.infoComplete(_tache.url);
      final ch = extraireChapitresInfo(info);
      if (!mounted) return;
      if (ch.isNotEmpty) {
        gestionnaire.mettreAJourChapitres(_tache, ch);
        setState(() => _chapitres = ch);
        majFeuille?.call(() {});
        toast(context, '${ch.length} chapitres chargés');
      } else {
        toast(context, 'Aucun chapitre sur cette vidéo');
      }
    } catch (_) {
      if (mounted) toast(context, 'Impossible de récupérer les chapitres hors ligne', erreur: true);
    } finally {
      if (mounted) {
        setState(() => _chargeChapitresEnLigne = false);
        majFeuille?.call(() {});
      }
    }
  }

  void _appliquerEffetsAudio() {
    Natif.effetsAudio(
      actif: _eqActif,
      bandes: _bandes,
      basses: _basses,
      gain: _gain,
    );
  }

  Future<void> _orienter() =>
      _audio ? SystemChrome.setPreferredOrientations([]) : Natif.orientationLecteur(_orientation);

  void _menuOrientation() => _choisir<int>(
        'Rotation de l’écran',
        [for (var i = 0; i < _orientations.length; i++) (i, _orientations[i], _orientation == i)],
        (i) {
          setState(() => _orientation = i);
          _retenir('lecteur_orientation', i);
          _orienter();
          _indiquer(_orientations[i], Icons.screen_rotation_rounded);
        },
      );

  void _pivoter() {
    final paysage = MediaQuery.orientationOf(context) == Orientation.landscape;
    setState(() => _orientation = paysage ? 1 : 2);
    _retenir('lecteur_orientation', _orientation);
    _orienter();
    _indiquer(_orientations[_orientation], Icons.screen_rotation_rounded);
  }

  Future<void> _allerAuTemps() async {
    final ctrl = _ctrl;
    if (ctrl == null) return;
    var texte = _temps(ctrl.value.position);
    _masquer?.cancel();
    final cible = await showDialog<Duration>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, maj) {
        final c = ctx.c;
        final morceaux = texte.trim().split(':');
        final nombres = morceaux.map(int.tryParse).toList();
        final valide = morceaux.isNotEmpty &&
            morceaux.length <= 3 &&
            nombres.every((n) => n != null && n >= 0) &&
            nombres.skip(1).every((n) => n! < 60);
        var secondes = 0;
        if (valide) {
          for (final n in nombres) {
            secondes = secondes * 60 + n!;
          }
        }
        final temps = Duration(seconds: secondes);
        final possible = valide && temps <= ctrl.value.duration;
        return AlertDialog(
          backgroundColor: const Color(0xF012162A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withAlpha(22)),
          ),
          title: const Text('Aller à un moment', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          content: TextFormField(
            initialValue: texte,
            autofocus: true,
            style: mono(ctx, taille: 16, couleur: Colors.white),
            keyboardType: TextInputType.datetime,
            onChanged: (v) => maj(() => texte = v),
            decoration: InputDecoration(
              labelText: 'Position (mm:ss ou hh:mm:ss)',
              labelStyle: const TextStyle(color: Colors.white70),
              helperText: 'Durée totale : ${_temps(ctrl.value.duration)}',
              helperStyle: const TextStyle(color: Colors.white54),
              errorText: possible ? null : 'Saisis une position dans la vidéo',
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withAlpha(28)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.indigo, width: 1.5),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.indigo),
              onPressed: possible ? () => Navigator.pop(ctx, temps) : null,
              child: const Text('Aller'),
            ),
          ],
        );
      }),
    );
    _programmerMasquage();
    if (cible != null && mounted) {
      await ctrl.seekTo(cible);
      _synchro();
    }
  }

  Future<void> _synchro() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    _enLecture = v.isPlaying;
    v.isPlaying ? WakelockPlus.enable() : WakelockPlus.disable();
    if (_audio) {
      v.isPlaying ? _pouls.repeat(reverse: true) : _pouls.stop();
    }
    Natif.media(
      titre: _tache.titre,
      artiste: _tache.chaine ?? '',
      image: miniatures.locale(_tache.miniature) ?? _tache.miniature,
      lecture: v.isPlaying,
      position: v.position.inMilliseconds,
      duree: v.duration.inMilliseconds,
      vitesse: _vitesse,
      prec: _index > 0,
      suiv: _aSuivant,
    );
    if (!_audio) Natif.pipAuto(v.isPlaying && reglages['pip_auto'] == true, _ratio(c));
  }

  double _ratio(VideoPlayerController c) {
    final t = c.value.size;
    return t.height > 0 ? t.width / t.height : 16 / 9;
  }

  Future<void> _entrerPip() async {
    final c = _ctrl;
    if (c == null) return;
    if (!await Natif.pip(_ratio(c)) && mounted) toast(context, 'Image dans l’image indisponible', erreur: true);
  }

  void _commande(({String action, int position}) m) {
    final c = _ctrl;
    if (!mounted) return;
    switch (m.action) {
      case 'play':
        c?.play();
      case 'pause':
        c?.pause();
        _memoriserPosition();
      case 'next':
        _aller(_index + 1);
      case 'prev':
        _aller(_index - 1);
      case 'seek':
        c?.seekTo(Duration(milliseconds: m.position)).then((_) => _synchro());
      case 'stop':
        c?.pause();
        _memoriserPosition();
        Navigator.of(context).pop();
    }
  }

  void _maj() {
    final c = _ctrl;
    if (!mounted || c == null) return;
    final v = c.value;
    if (v.hasError) {
      if (_erreur == null) {
        WakelockPlus.disable();
        Natif.mediaArreter();
        Natif.pipAuto(false, 16 / 9);
        setState(() {
          _verrou = false;
          _erreur = 'La lecture a été interrompue. Réessaie ou ouvre le fichier avec une autre application.';
        });
      }
      return;
    }
    if (v.isInitialized && v.isPlaying != _enLecture) _synchro();
    if (!_signale &&
        v.duration > Duration.zero &&
        (v.position.inSeconds > 60 || v.position.inMilliseconds > v.duration.inMilliseconds * 0.3)) {
      _signale = true;
      gouts.signal('lecture', url: _tache.url, titre: _tache.titre, chaine: _tache.chaine);
    }

    // Boucle A-B
    final b = _b;
    if (b != null && v.isPlaying && v.position >= b) {
      c.seekTo(_a ?? Duration.zero);
    }

    final fini = !_boucle &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        (v.isCompleted || v.position >= v.duration) &&
        !v.isPlaying;
    if (fini) {
      _effacerPosition();
      if (_sommeilMin == -1) {
        _sommeilMin = 0;
        _finSommeil = null;
        _indiquer('Minuteur : arrêt en fin de vidéo', Icons.bedtime_rounded);
        setState(() => _controles = true);
        return;
      }
      if (_aSuivant && _auto && !_compteAnnule && _compteur == null) {
        if (_audio) {
          _aller(_index + 1);
          return;
        }
        _demarrerCompte();
      }
    } else if (!fini && _compteur != null) {
      _annulerCompte();
    }
    setState(() {});
  }

  void _demarrerCompte() {
    _compte = 5;
    _controles = true;
    _compteur = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_compte <= 1) {
        _annulerCompte();
        _aller(_index + 1);
      } else {
        setState(() => _compte--);
      }
    });
  }

  void _annulerCompte() {
    _compteur?.cancel();
    _compteur = null;
  }

  void _memoriserPosition() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final positions = Map<String, dynamic>.of((reglages['positions'] as Map?)?.cast<String, dynamic>() ?? {});
    final p = c.value.position.inMilliseconds;
    if (p > c.value.duration.inMilliseconds * 0.95) {
      positions.remove(_tache.id);
    } else {
      positions.remove(_tache.id);
      positions[_tache.id] = p;
    }
    while (positions.length > 300) {
      positions.remove(positions.keys.first);
    }
    reglages.ecrireSansPrevenir('positions', positions);
  }

  void _effacerPosition() {
    final positions = Map<String, dynamic>.of((reglages['positions'] as Map?)?.cast<String, dynamic>() ?? {});
    if (positions.remove(_tache.id) != null) reglages.ecrireSansPrevenir('positions', positions);
  }

  void _aller(int i) {
    if (i < 0 || i >= _file.length) return;
    _memoriserPosition();
    _annulerCompte();
    _ctrl?.removeListener(_maj);
    _ctrl?.pause();
    setState(() => _index = i);
    _charger();
  }

  void _deplacerDansFile(int ancien, int nouveau) {
    if (ancien < 0 || ancien >= _file.length) return;
    nouveau = nouveau.clamp(0, _file.length - 1);
    if (ancien == nouveau) return;
    final idActuel = _tache.id;
    final item = _file.removeAt(ancien);
    _file.insert(nouveau, item);
    _index = _file.indexWhere((t) => t.id == idActuel).clamp(0, _file.length - 1);
    setState(() {});
  }

  void _lireEnsuite(int i) {
    if (i == _index || i == _index + 1 || i < 0 || i >= _file.length) return;
    final idActuel = _tache.id;
    final item = _file.removeAt(i);
    final idxActuel = _file.indexWhere((t) => t.id == idActuel);
    final dest = (idxActuel + 1).clamp(0, _file.length);
    _file.insert(dest, item);
    _index = _file.indexWhere((t) => t.id == idActuel).clamp(0, _file.length - 1);
    setState(() {});
    _indiquer('À suivre : ${item.titre}', Icons.playlist_play_rounded);
  }

  void _retirerDeFile(int i) {
    if (_file.length <= 1 || i == _index || i < 0 || i >= _file.length) return;
    final idActuel = _tache.id;
    _file.removeAt(i);
    _index = _file.indexWhere((t) => t.id == idActuel).clamp(0, _file.length - 1);
    setState(() {});
  }

  // ── contrôles & feedback ────────────────────────────────────────────
  void _programmerMasquage() {
    _masquer?.cancel();
    _masquer = Timer(const Duration(milliseconds: 3600), () {
      if (mounted && !_interaction && !_glisseBarre && (_ctrl?.value.isPlaying ?? false)) {
        setState(() => _controles = false);
      }
    });
  }

  void _basculerControles() {
    setState(() => _controles = !_controles);
    if (_controles) _programmerMasquage();
  }

  void _lecturePause({bool flashCentre = false}) {
    final c = _ctrl;
    if (c == null) return;
    final v = c.value;
    if (v.position >= v.duration && v.duration > Duration.zero) {
      _annulerCompte();
      c.seekTo(Duration.zero).then((_) => c.play());
    } else {
      v.isPlaying ? c.pause() : c.play();
    }
    if (flashCentre) {
      _finPoulsCentre?.cancel();
      setState(() => _poulsCentre = true);
      _finPoulsCentre = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _poulsCentre = false);
      });
    }
    if (v.isPlaying) _memoriserPosition();
    _programmerMasquage();
  }

  void _pasImage(int sens) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) c.pause();
    final d = c.value.duration;
    var cible = c.value.position + Duration(milliseconds: 33 * sens);
    if (cible < Duration.zero) cible = Duration.zero;
    if (cible > d) cible = d;
    c.seekTo(cible);
    HapticFeedback.selectionClick();
    _indiquer('${sens > 0 ? '+1' : '−1'} image · ${_temps(cible, ms: true)}',
        sens > 0 ? Icons.skip_next_rounded : Icons.skip_previous_rounded);
  }

  void _indiquer(String texte, IconData icone) {
    _finIndication?.cancel();
    setState(() {
      _indication = texte;
      _iconeIndication = icone;
    });
    _finIndication = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _indication = null);
    });
  }

  void _sauter(int sens, {bool onde = true}) {
    final c = _ctrl;
    if (c == null) return;
    _cumulSaut = (_cumulSaut.sign == sens ? _cumulSaut : 0) + _saut * sens;
    final d = c.value.duration;
    var cible = c.value.position + Duration(seconds: _saut * sens);
    if (cible < Duration.zero) cible = Duration.zero;
    if (cible > d) cible = d;
    c.seekTo(cible).then((_) => _synchro());
    HapticFeedback.selectionClick();
    if (onde) {
      _finOnde?.cancel();
      setState(() => _onde = sens);
      _finOnde = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _onde = 0);
      });
    } else {
      _indiquer('${_cumulSaut > 0 ? '+' : ''}$_cumulSaut s',
          sens > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
    }
    _finSaut?.cancel();
    _finSaut = Timer(const Duration(milliseconds: 900), () => _cumulSaut = 0);
  }

  void _montrerBarre(String type) {
    _finBarre?.cancel();
    setState(() => _barre = type);
    _finBarre = Timer(const Duration(milliseconds: 950), () {
      if (mounted) setState(() => _barre = null);
    });
  }

  void _changerVitesse(double v) {
    final vClamp = (v * 20).round() / 20.0;
    setState(() => _vitesse = vClamp);
    _retenir('lecteur_vitesse', vClamp);
    _ctrl?.setPlaybackSpeed(vClamp);
    _synchro();
  }

  void _changerFormat(int f) {
    setState(() {
      _format = f.clamp(0, _formats.length - 1);
      _zoom = 1.0;
      _panZoom = Offset.zero;
    });
    _retenir('lecteur_format', _format);
    _indiquer('Format · ${_formats[_format]}', Icons.aspect_ratio_rounded);
  }

  void _reinitialiserZoom() {
    setState(() {
      _zoom = 1.0;
      _panZoom = Offset.zero;
    });
    _indiquer('Zoom 1×', Icons.fit_screen_rounded);
  }

  void _boucleAB() {
    final c = _ctrl;
    if (c == null) return;
    final p = c.value.position;
    setState(() {
      if (_a == null) {
        _a = p;
        _indiquer('Point A · ${_temps(p)}', Icons.flag_rounded);
      } else if (_b == null) {
        if (p <= _a! + const Duration(milliseconds: 500)) {
          _indiquer('Place B après A', Icons.flag_outlined);
          return;
        }
        _b = p;
        c.seekTo(_a!);
        _indiquer('Boucle A→B active', Icons.repeat_on_rounded);
      } else {
        _a = _b = null;
        _indiquer('Boucle A-B retirée', Icons.repeat_rounded);
      }
    });
    _programmerMasquage();
  }

  // ── chapitres & signets ─────────────────────────────────────────────
  ChapitreVideo? _chapitrePour(Duration pos) {
    if (_chapitres.isEmpty) return null;
    final ms = pos.inMilliseconds;
    for (var i = _chapitres.length - 1; i >= 0; i--) {
      if (ms >= _chapitres[i].debutMs) return _chapitres[i];
    }
    return _chapitres.first;
  }

  void _sauterChapitre(int delta) {
    final c = _ctrl;
    if (c == null || _chapitres.isEmpty) return;
    final ms = c.value.position.inMilliseconds;
    var cur = 0;
    for (var i = _chapitres.length - 1; i >= 0; i--) {
      if (ms >= _chapitres[i].debutMs) {
        cur = i;
        break;
      }
    }
    // Si delta < 0 et déjà avancé de >3s dans le chapitre courant, revenir au début de ce chapitre
    final targetIdx = (delta < 0 && ms - _chapitres[cur].debutMs > 3000) ? cur : (cur + delta);
    if (targetIdx < 0 || targetIdx >= _chapitres.length) {
      _indiquer(delta < 0 ? 'Premier chapitre' : 'Dernier chapitre', Icons.menu_book_rounded);
      return;
    }
    final ch = _chapitres[targetIdx];
    c.seekTo(ch.debut).then((_) => _synchro());
    HapticFeedback.selectionClick();
    _indiquer(ch.titre, Icons.menu_book_rounded);
  }

  List<({int ms, String note})> _signetsVideo() {
    final map = (reglages['signets'] as Map?) ?? const {};
    final brut = map[_tache.id];
    if (brut is! List) return const [];
    final res = <({int ms, String note})>[];
    for (final e in brut) {
      if (e is Map && e['ms'] is num) {
        res.add((ms: (e['ms'] as num).toInt(), note: (e['note'] ?? '').toString()));
      }
    }
    res.sort((a, b) => a.ms.compareTo(b.ms));
    return res;
  }

  void _ajouterSignet([String? note]) {
    final c = _ctrl;
    if (c == null) return;
    final ms = c.value.position.inMilliseconds;
    final tout = Map<String, dynamic>.of((reglages['signets'] as Map?)?.cast<String, dynamic>() ?? {});
    final liste = [
      for (final s in _signetsVideo()) {'ms': s.ms, 'note': s.note},
    ];
    final libel = (note != null && note.trim().isNotEmpty)
        ? note.trim()
        : (_chapitrePour(c.value.position)?.titre ?? 'Moment ${_temps(Duration(milliseconds: ms))}');
    liste.add({'ms': ms, 'note': libel});
    liste.sort((a, b) => ((a['ms'] as int)).compareTo(b['ms'] as int));
    tout[_tache.id] = liste;
    _retenir('signets', tout);
    HapticFeedback.lightImpact();
    setState(() {});
    _indiquer('Signet ajouté · ${_temps(Duration(milliseconds: ms))}', Icons.bookmark_added_rounded);
  }

  void _supprimerSignet(int ms) {
    final tout = Map<String, dynamic>.of((reglages['signets'] as Map?)?.cast<String, dynamic>() ?? {});
    final liste = [
      for (final s in _signetsVideo())
        if (s.ms != ms) {'ms': s.ms, 'note': s.note},
    ];
    if (liste.isEmpty) {
      tout.remove(_tache.id);
    } else {
      tout[_tache.id] = liste;
    }
    _retenir('signets', tout);
    setState(() {});
  }

  LigneParole? _sousTitreActif(Duration pos) {
    final d = _donneesSt;
    if (!_sousTitresActifs || d == null || d.lignes.isEmpty) return null;
    final cible = pos + Duration(milliseconds: _stDecalageMs);
    if (cible < Duration.zero) return null;
    var bas = 0;
    var haut = d.lignes.length - 1;
    var cand = -1;
    while (bas <= haut) {
      final mid = (bas + haut) >> 1;
      if (d.lignes[mid].debut <= cible) {
        cand = mid;
        bas = mid + 1;
      } else {
        haut = mid - 1;
      }
    }
    if (cand < 0) return null;
    final l = d.lignes[cand];
    if (l.estPause || l.texte.trim().isEmpty) return null;
    if (cible <= l.fin + const Duration(milliseconds: 250)) return l;
    return null;
  }

  // ── feuilles Liquid-Glass ───────────────────────────────────────────
  Future<T?> _feuille<T>(Widget Function(BuildContext, StateSetter) contenu, {bool grande = false}) {
    _masquer?.cancel();
    return showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      isScrollControlled: grande,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xEC141932),
                    const Color(0xF00B0E1D),
                  ],
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(top: BorderSide(color: Colors.white.withAlpha(32))),
              ),
              child: SafeArea(top: false, child: StatefulBuilder(builder: contenu)),
            ),
          ),
        ),
      ),
    ).whenComplete(_programmerMasquage);
  }

  Widget _poignee(String titre, {Widget? action}) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Row(children: [
            Expanded(
              child: Text(titre, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.white)),
            ),
            ?action,
          ]),
        ]),
      );

  Future<void> _choisir<T>(String titre, List<(T, String, bool)> options, void Function(T) choix) async {
    final r = await _feuille<T>((ctx, _) => SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee(titre),
            for (final (v, l, actif) in options)
              ListTile(
                title: Text(l,
                    style: TextStyle(
                      color: actif ? context.c.indigo : Colors.white,
                      fontWeight: actif ? FontWeight.w700 : FontWeight.w400,
                    )),
                trailing: actif ? Icon(Icons.check_rounded, color: context.c.indigo) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ]),
        ));
    if (r != null && mounted) choix(r);
  }

  String _libVitesse(double v) => v == 1 ? 'Normale' : '${'$v'.replaceAll('.0', '').replaceAll('.', ',')}×';

  void _menuVitesse() => _feuille<void>((ctx, maj) {
        final c = context.c;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee(
              'Vitesse de lecture',
              action: _vitesse != 1.0
                  ? TextButton(
                      onPressed: () {
                        _changerVitesse(1.0);
                        maj(() {});
                      },
                      child: const Text('Réinitialiser'),
                    )
                  : null,
            ),
            Center(
              child: Text(
                _libVitesse(_vitesse),
                style: mono(context, taille: 32, couleur: Colors.white, poids: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: () {
                    _changerVitesse((_vitesse - 0.05).clamp(0.25, 4.0));
                    maj(() {});
                  },
                ),
                Expanded(
                  child: Slider(
                    min: 0.25,
                    max: 4.0,
                    divisions: 75,
                    value: _vitesse.clamp(0.25, 4.0),
                    activeColor: c.indigo,
                    inactiveColor: Colors.white12,
                    onChanged: (x) {
                      _changerVitesse(x);
                      maj(() {});
                    },
                  ),
                ),
                IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: () {
                    _changerVitesse((_vitesse + 0.05).clamp(0.25, 4.0));
                    maj(() {});
                  },
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
                  ChoiceChip(
                    label: Text('${'$v'.replaceAll('.0', '')}×'),
                    selected: (_vitesse - v).abs() < 0.02,
                    selectedColor: c.indigo.withAlpha(190),
                    backgroundColor: Colors.white10,
                    labelStyle: TextStyle(color: Colors.white, fontWeight: (_vitesse - v).abs() < 0.02 ? FontWeight.w700 : FontWeight.w400),
                    side: BorderSide(color: Colors.white.withAlpha(20)),
                    onSelected: (_) {
                      _changerVitesse(v);
                      maj(() {});
                    },
                  ),
              ]),
            ),
            const Divider(color: Colors.white12, height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                const Icon(Icons.touch_app_rounded, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Vitesse en appui maintenu', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
                Wrap(spacing: 6, children: [
                  for (final vm in const [1.5, 2.0, 2.5, 3.0])
                    ChoiceChip(
                      label: Text('${'$vm'.replaceAll('.0', '')}×'),
                      selected: (_vitesseMaintien - vm).abs() < 0.02,
                      selectedColor: c.cyan.withAlpha(170),
                      backgroundColor: Colors.white10,
                      labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                      side: BorderSide.none,
                      onSelected: (_) {
                        setState(() => _vitesseMaintien = vm);
                        _retenir('lecteur_vitesse_maintien', vm);
                        maj(() {});
                      },
                    ),
                ]),
              ]),
            ),
          ]),
        );
      }, grande: true);

  void _menuPistes() => _feuille<void>((ctx, maj) {
        final c = context.c;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Piste audio'),
            for (var i = 0; i < _pistes.length; i++)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: _pistes[i].isSelected ? c.indigo.withAlpha(60) : Colors.white10,
                  child: Icon(Icons.graphic_eq_rounded, color: _pistes[i].isSelected ? c.indigo : Colors.white60, size: 18),
                ),
                title: Text(
                  _nomPiste(_pistes[i], i),
                  style: TextStyle(
                    color: _pistes[i].isSelected ? c.indigo : Colors.white,
                    fontWeight: _pistes[i].isSelected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                subtitle: _pistes[i].channelCount != null
                    ? Text('${_pistes[i].channelCount} canaux', style: const TextStyle(color: Colors.white54, fontSize: 12))
                    : null,
                trailing: _pistes[i].isSelected ? Icon(Icons.check_rounded, color: c.indigo) : null,
                onTap: () async {
                  await _ctrl?.selectAudioTrack(_pistes[i].id);
                  final p = await _ctrl?.getAudioTracks();
                  if (mounted) {
                    setState(() => _pistes = p ?? _pistes);
                    maj(() {});
                  }
                },
              ),
          ]),
        );
      });

  String _nomPiste(VideoAudioTrack p, int i) {
    final l = p.language;
    final n = l != null && l != 'und' && l.isNotEmpty ? '${langues.drapeau(l)} ${langues.nom(l)}' : (p.label ?? 'Piste ${i + 1}');
    return '$n${p.bitrate != null ? ' · ${(p.bitrate! / 1000).round()} kbps' : ''}';
  }

  /// Studio Audio & Égaliseur 5 bandes + Bass Boost + Gain (+15 dB).
  void _menuStudioAudio() => _feuille<void>((ctx, maj) {
        final c = context.c;
        void appliquerProfil(String cle) {
          final p = profilsEgaliseur[cle];
          if (p == null) return;
          setState(() {
            _eqProfil = cle;
            if (cle != 'perso') {
              _bandes = List<double>.of(p.$3);
              _retenir('audio_eq_bandes', _bandes);
            }
            _eqActif = true;
          });
          _retenir('audio_eq_profil', cle);
          _retenir('audio_eq_actif', true);
          _appliquerEffetsAudio();
          maj(() {});
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee(
              'Studio Audio & Égaliseur',
              action: Switch(
                value: _eqActif,
                activeThumbColor: c.indigo,
                onChanged: (v) {
                  setState(() => _eqActif = v);
                  _retenir('audio_eq_actif', v);
                  _appliquerEffetsAudio();
                  maj(() {});
                },
              ),
            ),
            if (_pistes.length > 1) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(children: [
                  const Text('Piste audio', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _menuPistes();
                    },
                    icon: const Icon(Icons.translate_rounded, size: 17),
                    label: Text('${_pistes.length} pistes'),
                  ),
                ]),
              ),
              const Divider(color: Colors.white12),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in profilsEgaliseur.entries)
                  ChoiceChip(
                    avatar: Icon(e.value.$2, size: 16, color: Colors.white),
                    label: Text(e.value.$1),
                    selected: _eqActif && _eqProfil == e.key,
                    selectedColor: c.indigo.withAlpha(200),
                    backgroundColor: Colors.white10,
                    labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                    side: BorderSide(color: Colors.white.withAlpha(18)),
                    onSelected: (_) => appliquerProfil(e.key),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withAlpha(18)),
                ),
                child: Row(children: [
                  for (var i = 0; i < 5; i++)
                    Expanded(
                      child: Column(children: [
                        Text(
                          '${_bandes[i] >= 0 ? '+' : ''}${(_bandes[i] * 12).round()} dB',
                          style: mono(context, taille: 10, couleur: _eqActif ? c.cyan : Colors.white38),
                        ),
                        SizedBox(
                          height: 125,
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              min: -1.0,
                              max: 1.0,
                              value: _bandes[i].clamp(-1.0, 1.0),
                              activeColor: _eqActif ? c.indigo : Colors.white30,
                              inactiveColor: Colors.white12,
                              onChanged: (x) {
                                setState(() {
                                  _bandes[i] = x;
                                  _eqProfil = 'perso';
                                  _eqActif = true;
                                });
                                _retenir('audio_eq_bandes', _bandes);
                                _retenir('audio_eq_profil', 'perso');
                                _retenir('audio_eq_actif', true);
                                _appliquerEffetsAudio();
                                maj(() {});
                              },
                            ),
                          ),
                        ),
                        Text(frequencesBandes[i], style: const TextStyle(color: Colors.white70, fontSize: 11)),
                      ]),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(children: [
                Row(children: [
                  const Icon(Icons.speaker_rounded, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  const Text('Basses profondes', style: TextStyle(color: Colors.white, fontSize: 13)),
                  const Spacer(),
                  Text('${(_basses / 10).round()} %', style: mono(context, taille: 12, couleur: c.cyan)),
                ]),
                Slider(
                  min: 0,
                  max: 1000,
                  value: _basses.toDouble(),
                  activeColor: c.cyan,
                  inactiveColor: Colors.white12,
                  onChanged: (x) {
                    setState(() {
                      _basses = x.round();
                      _eqActif = true;
                    });
                    _retenir('audio_basses', _basses);
                    _retenir('audio_eq_actif', true);
                    _appliquerEffetsAudio();
                    maj(() {});
                  },
                ),
                Row(children: [
                  const Icon(Icons.volume_up_rounded, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  const Text('Amplificateur sonore (Gain)', style: TextStyle(color: Colors.white, fontSize: 13)),
                  const Spacer(),
                  Text('+${_gain.toStringAsFixed(1)} dB', style: mono(context, taille: 12, couleur: c.ambre)),
                ]),
                Slider(
                  min: 0,
                  max: 15,
                  divisions: 30,
                  value: _gain,
                  activeColor: c.ambre,
                  inactiveColor: Colors.white12,
                  onChanged: (x) {
                    setState(() {
                      _gain = x;
                      _eqActif = true;
                    });
                    _retenir('audio_gain', _gain);
                    _retenir('audio_eq_actif', true);
                    _appliquerEffetsAudio();
                    maj(() {});
                  },
                ),
              ]),
            ),
          ]),
        );
      }, grande: true);

  /// Feuille complète des sous-titres : pistes multiples, décalage synchro, style et transcription cliquable.
  void _menuSousTitres() {
    var onglet = 0; // 0 = Réglages, 1 = Transcription
    var recherche = '';
    _feuille<void>((ctx, maj) {
      final c = context.c;
      final lignes = (_donneesSt?.lignes ?? const [])
          .where((l) => !l.estPause && l.texte.trim().isNotEmpty)
          .where((l) => recherche.trim().isEmpty || l.texte.toLowerCase().contains(recherche.trim().toLowerCase()))
          .toList();
      final posActuelle = _ctrl?.value.position ?? Duration.zero;

      void ajusterDecalage(int deltaMs) {
        final decMap = Map<String, dynamic>.of((reglages['decalages_st'] as Map?)?.cast<String, dynamic>() ?? {});
        final nouveau = deltaMs == 0 ? 0 : (_stDecalageMs + deltaMs).clamp(-30000, 30000);
        setState(() => _stDecalageMs = nouveau);
        if (nouveau == 0) {
          decMap.remove(_tache.id);
        } else {
          decMap[_tache.id] = nouveau;
        }
        _retenir('decalages_st', decMap);
        maj(() {});
      }

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        _poignee(
          'Sous-titres',
          action: Switch(
            value: _sousTitresActifs,
            activeThumbColor: c.indigo,
            onChanged: (v) {
              setState(() => _sousTitresActifs = v);
              _retenir('lecteur_st', v);
              maj(() {});
            },
          ),
        ),
        if (_donneesSt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.tune_rounded, size: 17), label: Text('Pistes & style')),
                ButtonSegment(value: 1, icon: Icon(Icons.subtitles_rounded, size: 17), label: Text('Transcription')),
              ],
              selected: {onglet},
              onSelectionChanged: (s) => maj(() => onglet = s.first),
            ),
          ),
        if (onglet == 0)
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_sourcesSt.isNotEmpty) ...[
                  const Text('Piste disponible', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  for (final s in _sourcesSt)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      selected: _sousTitresActifs && _idStActif == s.id,
                      selectedTileColor: c.indigo.withAlpha(45),
                      leading: Icon(Icons.closed_caption_rounded,
                          color: _sousTitresActifs && _idStActif == s.id ? c.indigo : Colors.white60),
                      title: Text(s.label, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      trailing: _idStActif == s.id ? Icon(Icons.check_rounded, color: c.indigo) : null,
                      onTap: () async {
                        setState(() => _sousTitresActifs = true);
                        _retenir('lecteur_st', true);
                        await _chargerPisteSousTitres(s, _generation);
                        maj(() {});
                      },
                    ),
                  const Divider(color: Colors.white12, height: 22),
                ],
                // Synchro ±ms
                Row(children: [
                  const Text('Synchronisation', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  Text(
                    _stDecalageMs == 0
                        ? 'Synchronisé'
                        : '${_stDecalageMs > 0 ? '+' : ''}${(_stDecalageMs / 1000).toStringAsFixed(1)} s',
                    style: mono(context, taille: 13, couleur: _stDecalageMs == 0 ? c.vert : c.cyan),
                  ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final d in const [-500, -100, 0, 100, 500])
                    ActionChip(
                      label: Text(d == 0 ? '0 s' : '${d > 0 ? '+' : ''}${(d / 1000).toStringAsFixed(1)} s'),
                      backgroundColor: Colors.white10,
                      labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                      side: BorderSide(color: Colors.white.withAlpha(20)),
                      onPressed: () => ajusterDecalage(d),
                    ),
                ]),
                const SizedBox(height: 16),
                // Taille + Position
                Row(children: [
                  const Text('Taille du texte', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  Text('$_tailleSt pt', style: mono(context, taille: 13, couleur: c.indigo)),
                ]),
                Slider(
                  min: 12,
                  max: 30,
                  divisions: 18,
                  value: _tailleSt.toDouble().clamp(12, 30),
                  activeColor: c.indigo,
                  inactiveColor: Colors.white12,
                  onChanged: (x) {
                    setState(() => _tailleSt = x.round());
                    _retenir('lecteur_st_taille', _tailleSt);
                    maj(() {});
                  },
                ),
                Row(children: [
                  const Text('Hauteur depuis le bas', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  Text('$_margeSt px', style: mono(context, taille: 13, couleur: c.indigo)),
                ]),
                Slider(
                  min: 8,
                  max: 110,
                  divisions: 17,
                  value: _margeSt.toDouble().clamp(8, 110),
                  activeColor: c.indigo,
                  inactiveColor: Colors.white12,
                  onChanged: (x) {
                    setState(() => _margeSt = x.round());
                    _retenir('lecteur_st_marge', _margeSt);
                    maj(() {});
                  },
                ),
                const SizedBox(height: 6),
                Row(children: [
                  const Text('Couleur', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const Spacer(),
                  for (final e in _couleursSt.entries)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(e.value.$1),
                        selected: _couleurSt == e.key,
                        selectedColor: e.value.$2.withAlpha(70),
                        backgroundColor: Colors.white10,
                        labelStyle: TextStyle(color: e.value.$2, fontSize: 12, fontWeight: FontWeight.w700),
                        side: BorderSide(color: _couleurSt == e.key ? e.value.$2 : Colors.white12),
                        onSelected: (_) {
                          setState(() => _couleurSt = e.key);
                          _retenir('lecteur_st_couleur', e.key);
                          maj(() {});
                        },
                      ),
                    ),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fond pilule translucide', style: TextStyle(color: Colors.white, fontSize: 14)),
                  value: _fondSt,
                  activeThumbColor: c.indigo,
                  onChanged: (v) {
                    setState(() => _fondSt = v);
                    _retenir('lecteur_st_fond', v);
                    maj(() {});
                  },
                ),
              ]),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: TextField(
              style: const TextStyle(color: Colors.white, fontSize: 14),
              onChanged: (v) => maj(() => recherche = v),
              decoration: InputDecoration(
                hintText: 'Rechercher un mot ou une phrase…',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54, size: 20),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withAlpha(12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          Flexible(
            child: lignes.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: Text('Aucune réplique correspondante', style: TextStyle(color: Colors.white54))),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: lignes.length,
                    itemBuilder: (_, i) {
                      final l = lignes[i];
                      final decale = posActuelle + Duration(milliseconds: _stDecalageMs);
                      final actif = decale >= l.debut && decale <= l.fin;
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        selected: actif,
                        selectedTileColor: c.indigo.withAlpha(50),
                        leading: Text(_temps(l.debut), style: mono(context, taille: 12, couleur: actif ? c.cyan : Colors.white54)),
                        title: Text(l.texte,
                            style: TextStyle(
                              color: actif ? Colors.white : Colors.white70,
                              fontWeight: actif ? FontWeight.w700 : FontWeight.w400,
                              fontSize: 13,
                            )),
                        onTap: () async {
                          final cible = l.debut - Duration(milliseconds: _stDecalageMs);
                          await _ctrl?.seekTo(cible < Duration.zero ? Duration.zero : cible);
                          _synchro();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
          ),
        ],
      ]);
    }, grande: true);
  }

  /// Feuille Chapitres + Signets favoris.
  void _menuChapitres() => _feuille<void>((ctx, maj) {
        final c = context.c;
        final ctrl = _ctrl;
        final pos = ctrl?.value.position ?? Duration.zero;
        final actif = _chapitrePour(pos);
        final signets = _signetsVideo();

        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _poignee(
            'Chapitres & Signets',
            action: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton.icon(
                onPressed: () {
                  _ajouterSignet();
                  maj(() {});
                },
                icon: const Icon(Icons.bookmark_add_rounded, size: 18),
                label: const Text('Signet'),
              ),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (signets.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text('Signets enregistrés', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  for (final s in signets)
                    ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      leading: Icon(Icons.bookmark_rounded, color: c.ambre),
                      title: Text(s.note, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                      subtitle: Text(_temps(Duration(milliseconds: s.ms)), style: mono(context, taille: 11, couleur: c.cyan)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.white54, size: 18),
                        onPressed: () {
                          _supprimerSignet(s.ms);
                          maj(() {});
                        },
                      ),
                      onTap: () async {
                        await ctrl?.seekTo(Duration(milliseconds: s.ms));
                        _synchro();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                  const Divider(color: Colors.white12, height: 20),
                ],
                if (_chapitres.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text('${_chapitres.length} chapitres',
                        style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  for (var i = 0; i < _chapitres.length; i++) ...[
                    Builder(builder: (_) {
                      final ch = _chapitres[i];
                      final estActif = actif?.debutMs == ch.debutMs;
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        selected: estActif,
                        selectedTileColor: c.indigo.withAlpha(50),
                        leading: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: estActif ? c.indigo : Colors.white10,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('${i + 1}', style: mono(context, taille: 12, couleur: Colors.white, poids: FontWeight.w700)),
                        ),
                        title: Text(ch.titre,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: estActif ? Colors.white : Colors.white70,
                              fontWeight: estActif ? FontWeight.w700 : FontWeight.w400,
                              fontSize: 13.5,
                            )),
                        trailing: Text(_temps(ch.debut), style: mono(context, taille: 12, couleur: estActif ? c.cyan : Colors.white54)),
                        onTap: () async {
                          await ctrl?.seekTo(ch.debut);
                          _synchro();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    }),
                  ],
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(10),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white.withAlpha(18)),
                      ),
                      child: Column(children: [
                        const Icon(Icons.menu_book_rounded, color: Colors.white54, size: 30),
                        const SizedBox(height: 8),
                        const Text('Aucun chapitre enregistré pour cette vidéo.',
                            textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
                        if (_tache.url.startsWith('http')) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(backgroundColor: c.indigo),
                            onPressed: _chargeChapitresEnLigne ? null : () => _chargerChapitresEnLigne(majFeuille: maj),
                            icon: _chargeChapitresEnLigne
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.cloud_download_rounded, size: 18),
                            label: Text(_chargeChapitresEnLigne ? 'Recherche…' : 'Récupérer depuis YouTube'),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ]);
      }, grande: true);

  /// Format d'image, rotation, miroir horizontal, zoom et filtre nuit.
  void _menuImage() => _feuille<void>((ctx, maj) {
        final c = context.c;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Image & Confort visuel'),
            const Text('Format de cadrage', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < _formats.length; i++)
                ChoiceChip(
                  label: Text(_formats[i]),
                  selected: _format == i,
                  selectedColor: c.indigo.withAlpha(200),
                  backgroundColor: Colors.white10,
                  labelStyle: const TextStyle(color: Colors.white, fontSize: 13),
                  side: BorderSide(color: Colors.white.withAlpha(18)),
                  onSelected: (_) {
                    _changerFormat(i);
                    maj(() {});
                  },
                ),
            ]),
            const SizedBox(height: 16),
            const Text('Orientation', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < _orientations.length; i++)
                ChoiceChip(
                  label: Text(_orientations[i]),
                  selected: _orientation == i,
                  selectedColor: c.indigo.withAlpha(200),
                  backgroundColor: Colors.white10,
                  labelStyle: const TextStyle(color: Colors.white, fontSize: 13),
                  side: BorderSide(color: Colors.white.withAlpha(18)),
                  onSelected: (_) {
                    setState(() => _orientation = i);
                    _retenir('lecteur_orientation', i);
                    _orienter();
                    maj(() {});
                  },
                ),
            ]),
            const Divider(color: Colors.white12, height: 24),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.flip_rounded, color: Colors.white70),
              title: const Text('Effet miroir horizontal', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Pratique pour chorégraphies et tutoriels', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: _miroir,
              activeThumbColor: c.indigo,
              onChanged: (v) {
                setState(() => _miroir = v);
                _retenir('lecteur_miroir', v);
                maj(() {});
              },
            ),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.nightlight_round, color: Colors.amber, size: 18),
              const SizedBox(width: 8),
              const Text('Filtre confort nuit (anti-lumière bleue)', style: TextStyle(color: Colors.white, fontSize: 13)),
              const Spacer(),
              Text('${(_nuit * 100 / 0.6).round()} %', style: mono(context, taille: 12, couleur: c.ambre)),
            ]),
            Slider(
              min: 0.0,
              max: 0.6,
              divisions: 12,
              value: _nuit,
              activeColor: c.ambre,
              inactiveColor: Colors.white12,
              onChanged: (x) {
                setState(() => _nuit = x);
                _retenir('lecteur_nuit', x);
                maj(() {});
              },
            ),
            if (_zoom > 1.02) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _reinitialiserZoom();
                    maj(() {});
                  },
                  icon: const Icon(Icons.fit_screen_rounded),
                  label: Text('Réinitialiser le zoom (${_zoom.toStringAsFixed(1)}×)'),
                ),
              ),
            ],
          ]),
        );
      }, grande: true);

  /// Boucle A-B avec réglage fin ±0.5 s.
  void _menuBoucleAB() => _feuille<void>((ctx, maj) {
        final c = context.c;
        final dur = _ctrl?.value.duration ?? Duration.zero;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Boucle A-B précise'),
            Row(children: [
              Expanded(
                child: _CartePointAB(
                  titre: 'Point A (début)',
                  valeur: _a == null ? 'Non défini' : _temps(_a!, ms: true),
                  actif: _a != null,
                  couleur: c.indigo,
                  onMarquer: () {
                    setState(() => _a = _ctrl?.value.position);
                    maj(() {});
                  },
                  onReculer: _a == null
                      ? null
                      : () {
                          final na = _a! - const Duration(milliseconds: 500);
                          setState(() => _a = na < Duration.zero ? Duration.zero : na);
                          maj(() {});
                        },
                  onAvancer: _a == null
                      ? null
                      : () {
                          final na = _a! + const Duration(milliseconds: 500);
                          if (_b == null || na < _b! - const Duration(milliseconds: 500)) {
                            setState(() => _a = na > dur ? dur : na);
                            maj(() {});
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CartePointAB(
                  titre: 'Point B (fin)',
                  valeur: _b == null ? 'Non défini' : _temps(_b!, ms: true),
                  actif: _b != null,
                  couleur: c.ambre,
                  onMarquer: () {
                    final p = _ctrl?.value.position ?? Duration.zero;
                    if (_a != null && p <= _a! + const Duration(milliseconds: 500)) {
                      toast(context, 'Place B après A', erreur: true);
                      return;
                    }
                    setState(() => _b = p);
                    maj(() {});
                  },
                  onReculer: _b == null
                      ? null
                      : () {
                          final nb = _b! - const Duration(milliseconds: 500);
                          if (_a == null || nb > _a! + const Duration(milliseconds: 500)) {
                            setState(() => _b = nb < Duration.zero ? Duration.zero : nb);
                            maj(() {});
                          }
                        },
                  onAvancer: _b == null
                      ? null
                      : () {
                          final nb = _b! + const Duration(milliseconds: 500);
                          setState(() => _b = nb > dur ? dur : nb);
                          maj(() {});
                        },
                ),
              ),
            ]),
            if (_a != null || _b != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => _a = _b = null);
                    maj(() {});
                  },
                  icon: const Icon(Icons.clear_rounded),
                  label: const Text('Retirer la boucle A-B'),
                ),
              ),
            ],
          ]),
        );
      });

  void _menuSommeil() => _choisir<int>(
        'Minuteur de sommeil',
        [
          (0, 'Désactivé', _sommeilMin == 0),
          (-1, 'À la fin de cette vidéo', _sommeilMin == -1),
          for (final m in const [10, 15, 20, 30, 45, 60, 90]) (m, '$m minutes', m == _sommeilMin),
        ],
        (m) {
          _sommeil?.cancel();
          _sommeilMin = m;
          _finSommeil = m > 0 ? DateTime.now().add(Duration(minutes: m)) : null;
          if (m > 0) {
            _sommeil = Timer(Duration(minutes: m), () {
              if (!mounted) return;
              _ctrl?.pause();
              _sommeilMin = 0;
              _finSommeil = null;
              _indiquer('Minuteur : lecture en pause', Icons.bedtime_rounded);
            });
            _indiquer('Arrêt dans $m min', Icons.bedtime_rounded);
          } else if (m == -1) {
            _indiquer('Arrêt en fin de vidéo', Icons.bedtime_rounded);
          } else {
            _indiquer('Minuteur désactivé', Icons.bedtime_off_rounded);
          }
        },
      );

  void _menuSaut() => _choisir<int>(
        'Durée des sauts',
        [for (final s in const [5, 10, 15, 30, 60]) (s, '$s secondes', s == _saut)],
        (s) {
          setState(() => _saut = s);
          _retenir('lecteur_saut', s);
        },
      );

  /// File d'attente réorganisable, avec « Lire ensuite » et suppression.
  void _menuFile() => _feuille<void>((ctx, maj) {
        final c = context.c;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _poignee('File d’attente · ${_index + 1}/${_file.length}'),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 14),
              proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
              itemCount: _file.length,
              onReorderItem: (a, b) {
                _deplacerDansFile(a, b);
                maj(() {});
              },
              itemBuilder: (_, i) {
                final t = _file[i];
                final actuel = i == _index;
                return ListTile(
                  key: ValueKey('q_${t.id}_$i'),
                  selected: actuel,
                  selectedTileColor: c.indigo.withAlpha(45),
                  leading: Row(mainAxisSize: MainAxisSize.min, children: [
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.drag_handle_rounded, color: Colors.white38, size: 20),
                      ),
                    ),
                    Miniature(t.miniature, largeur: 68, rayon: 8),
                  ]),
                  title: Text(
                    t.titre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: actuel ? c.indigo : Colors.white,
                      fontWeight: actuel ? FontWeight.w700 : FontWeight.w400,
                      fontSize: 13.5,
                    ),
                  ),
                  subtitle: t.chaine == null
                      ? null
                      : Text(t.chaine!, maxLines: 1, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  trailing: actuel
                      ? Icon(Icons.equalizer_rounded, color: c.indigo)
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          if (i != _index + 1)
                            IconButton(
                              tooltip: 'Lire ensuite',
                              icon: const Icon(Icons.playlist_play_rounded, color: Colors.white60, size: 20),
                              onPressed: () {
                                _lireEnsuite(i);
                                maj(() {});
                              },
                            ),
                          if (_file.length > 1)
                            IconButton(
                              tooltip: 'Retirer de la file',
                              icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                              onPressed: () {
                                _retirerDeFile(i);
                                maj(() {});
                              },
                            ),
                        ]),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (!actuel) _aller(i);
                  },
                );
              },
            ),
          ),
        ]);
      }, grande: true);

  void _menuInfos() {
    final c = _ctrl;
    final f = _tache.fichierPrincipal;
    final t = c?.value.size ?? Size.zero;
    String taille(int o) => o > 1 << 30 ? '${(o / (1 << 30)).toStringAsFixed(2)} Go' : '${(o / (1 << 20)).toStringAsFixed(1)} Mo';
    final durS = c?.value.duration.inSeconds ?? 0;
    final debit = (f != null && f.taille > 0 && durS > 0) ? '${(f.taille * 8 / durS / 1000).round()} kbps' : null;
    final lignes = <(String, String)>[
      ('Titre', _tache.titre),
      if (_tache.chaine != null) ('Chaîne', _tache.chaine!),
      if (c != null) ('Durée', _temps(c.value.duration)),
      if (!_audio && t.width > 0) ('Résolution', '${t.width.round()} × ${t.height.round()}'),
      if (debit != null) ('Débit moyen', debit),
      if (_tache.pistes.isNotEmpty) ('Pistes prévues', _tache.pistes),
      if (f != null) ('Format', f.mime),
      if (f != null && f.taille > 0) ('Taille', taille(f.taille)),
      if (_pistes.isNotEmpty) ('Pistes audio', '${_pistes.length}'),
      if (_sourcesSt.isNotEmpty) ('Sous-titres', '${_sourcesSt.length} fichier(s)'),
      if (_chapitres.isNotEmpty) ('Chapitres', '${_chapitres.length}'),
      ('Source', _tache.url),
    ];
    _feuille<void>((ctx, _) => SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee(
              'Informations techniques',
              action: f != null
                  ? IconButton(
                      tooltip: 'Partager le fichier',
                      color: Colors.white70,
                      icon: const Icon(Icons.share_rounded),
                      onPressed: () => Natif.partager(f.uri, f.mime),
                    )
                  : null,
            ),
            for (final (k, v) in lignes)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 112, child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13))),
                  Expanded(child: SelectableText(v, style: const TextStyle(color: Colors.white, fontSize: 13))),
                ]),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                if (f != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Natif.ouvrir(f.uri, f.mime),
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: const Text('Lecteur externe'),
                    ),
                  ),
                if (f != null && _tache.url.startsWith('http')) const SizedBox(width: 10),
                if (_tache.url.startsWith('http'))
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _tache.url));
                        toast(context, 'Lien copié');
                      },
                      icon: const Icon(Icons.link_rounded, size: 17),
                      label: const Text('Copier le lien'),
                    ),
                  ),
              ]),
            ),
          ]),
        ));
  }

  void _aideGestes() => _feuille<void>((ctx, _) => SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _poignee('Gestes du lecteur'),
          for (final (ic, t, d) in [
            (Icons.touch_app_rounded, 'Double appui gauche / droite', 'Reculer ou avancer de $_saut s (cumulatif)'),
            (Icons.play_circle_outline_rounded, 'Double appui au centre', 'Lecture / Pause rapide'),
            (Icons.speed_rounded, 'Appui long maintenu', 'Accélérer à ${_libVitesse(_vitesseMaintien)} tant que tu maintiens'),
            (Icons.swap_horiz_rounded, 'Glisser horizontalement', 'Chercher précisément dans la vidéo avec aperçu du chapitre'),
            (Icons.brightness_6_rounded, 'Glisser à gauche', 'Régler la luminosité de l’écran'),
            (Icons.volume_up_rounded, 'Glisser à droite', 'Régler le volume sonore'),
            (Icons.pinch_rounded, 'Pincer à deux doigts', 'Zoom libre jusqu’à 3,5× et déplacement dans l’image'),
          ])
            ListTile(
              dense: true,
              leading: CircleAvatar(
                backgroundColor: context.c.indigo.withAlpha(40),
                child: Icon(ic, color: context.c.indigo, size: 19),
              ),
              title: Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(d, style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ),
        ]),
      ));

  Future<void> _basculerVersOnde() async {
    final c = _ctrl;
    final pos = c?.value.position ?? Duration.zero;
    _memoriserPosition();
    c?.pause();
    if (!mounted) return;
    final nav = Navigator.of(context);
    final tache = _tache;
    nav.pop();
    await ouvrirLecteurAudio(
      nav.context,
      liste: [tache],
      index: 0,
      departPosition: pos,
    );
  }

  /// Menu « Studio & Réglages » liquid-glass unifié.
  void _menuReglages() => _feuille<void>((ctx, maj) {
        final c = context.c;
        final ctrl = _ctrl;
        final f = _tache.fichierPrincipal;
        String libSommeil() {
          if (_sommeilMin == 0) return 'Désactivé';
          if (_sommeilMin == -1) return 'Fin vidéo';
          if (_finSommeil != null) {
            final rest = _finSommeil!.difference(DateTime.now()).inMinutes + 1;
            return '${rest.clamp(1, 90)} min';
          }
          return '$_sommeilMin min';
        }

        Widget tuileAction(IconData ic, String label, {bool actif = false, required VoidCallback onTap}) => InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: actif ? c.indigo.withAlpha(55) : Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: actif ? c.indigo.withAlpha(140) : Colors.white.withAlpha(16)),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(ic, color: actif ? c.cyan : Colors.white, size: 21),
                  const SizedBox(height: 5),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: actif ? Colors.white : Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              ),
            );

        Widget ligne(IconData ic, String titre, String? valeur, VoidCallback tap, {Color? badge}) => ListTile(
              dense: true,
              leading: Icon(ic, color: badge ?? Colors.white70),
              title: Text(titre, style: const TextStyle(color: Colors.white, fontSize: 14)),
              trailing: valeur == null
                  ? const Icon(Icons.chevron_right_rounded, color: Colors.white30, size: 18)
                  : Text(valeur, style: TextStyle(color: badge ?? c.cyan, fontWeight: FontWeight.w700, fontSize: 13)),
              onTap: () {
                Navigator.pop(ctx);
                tap();
              },
            );

        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Studio Vidéo'),
            // Actions rapides en grille
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
              child: Row(children: [
                if (!_audio) ...[
                  Expanded(
                    child: tuileAction(Icons.picture_in_picture_alt_rounded, 'PiP', onTap: () {
                      Navigator.pop(ctx);
                      _entrerPip();
                    }),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: tuileAction(
                    Icons.repeat_one_rounded,
                    'Répéter',
                    actif: _boucle,
                    onTap: () {
                      setState(() => _boucle = !_boucle);
                      ctrl?.setLooping(_boucle);
                      maj(() {});
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (!_audio) ...[
                  Expanded(
                    child: tuileAction(
                      Icons.headphones_rounded,
                      'Mode Onde',
                      onTap: () {
                        Navigator.pop(ctx);
                        _basculerVersOnde();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (f != null)
                  Expanded(
                    child: tuileAction(
                      Icons.share_rounded,
                      'Partager',
                      onTap: () {
                        Navigator.pop(ctx);
                        Natif.partager(f.uri, f.mime);
                      },
                    ),
                  ),
              ]),
            ),
            if (!_audio && ctrl != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withAlpha(16)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.photo_filter_rounded, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Image par image', style: TextStyle(color: Colors.white, fontSize: 13))),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '−1 image',
                      color: Colors.white,
                      icon: const Icon(Icons.fast_rewind_rounded, size: 20),
                      onPressed: () {
                        _pasImage(-1);
                        maj(() {});
                      },
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '+1 image',
                      color: Colors.white,
                      icon: const Icon(Icons.fast_forward_rounded, size: 20),
                      onPressed: () {
                        _pasImage(1);
                        maj(() {});
                      },
                    ),
                  ]),
                ),
              ),
            ligne(Icons.graphic_eq_rounded, 'Studio Audio & Égaliseur',
                _eqActif ? '${profilsEgaliseur[_eqProfil]?.$1 ?? 'Actif'}${_gain > 0 ? ' +${_gain.round()}dB' : ''}' : 'Neutre',
                _menuStudioAudio,
                badge: _eqActif ? c.cyan : null),
            ligne(Icons.speed_rounded, 'Vitesse de lecture', _libVitesse(_vitesse), _menuVitesse),
            if (_aSousTitres)
              ligne(
                Icons.closed_caption_rounded,
                'Sous-titres & transcription',
                _sousTitresActifs ? '$_tailleSt pt' : 'Désactivés',
                _menuSousTitres,
                badge: _sousTitresActifs ? c.indigo : null,
              ),
            ligne(
              Icons.menu_book_rounded,
              'Chapitres & signets',
              _chapitres.isNotEmpty ? '${_chapitres.length} ch.' : (_signetsVideo().isNotEmpty ? '${_signetsVideo().length} sig.' : null),
              _menuChapitres,
            ),
            if (!_audio)
              ligne(
                Icons.display_settings_rounded,
                'Image, miroir & confort nuit',
                _formats[_format],
                _menuImage,
              ),
            ligne(Icons.repeat_rounded, 'Boucle A-B précise', _b != null ? 'Active' : (_a != null ? 'Point A' : null), _menuBoucleAB),
            ligne(Icons.my_location_rounded, 'Aller à un moment', null, _allerAuTemps),
            ligne(Icons.forward_10_rounded, 'Durée des sauts', '$_saut s', _menuSaut),
            ligne(Icons.bedtime_outlined, 'Minuteur de sommeil', libSommeil(), _menuSommeil),
            if (_pistes.length > 1) ligne(Icons.translate_rounded, 'Piste audio', '${_pistes.length}', _menuPistes),
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.playlist_play_rounded, color: Colors.white70),
              title: const Text('Lecture automatique du suivant', style: TextStyle(color: Colors.white, fontSize: 14)),
              value: _auto,
              activeThumbColor: c.indigo,
              onChanged: (x) {
                setState(() => _auto = x);
                _retenir('lecteur_auto', x);
                maj(() {});
              },
            ),
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.swipe_vertical_rounded, color: Colors.white70),
              title: const Text('Gestes glisser (luminosité / volume / saut)', style: TextStyle(color: Colors.white, fontSize: 14)),
              value: _gestes,
              activeThumbColor: c.indigo,
              onChanged: (x) {
                setState(() => _gestes = x);
                _retenir('lecteur_gestes', x);
                maj(() {});
              },
            ),
            ligne(Icons.queue_music_rounded, 'File d’attente', '${_file.length}', _menuFile),
            ligne(Icons.touch_app_rounded, 'Guide des gestes', null, _aideGestes),
            ligne(Icons.info_outline_rounded, 'Informations techniques', null, _menuInfos),
          ]),
        );
      }, grande: true);

  // ── formatage temps ─────────────────────────────────────────────────
  String _temps(Duration d, {bool ms = false}) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    final base = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
    if (!ms) return base;
    final dix = (d.inMilliseconds % 1000) ~/ 100;
    return '$base.$dix';
  }

  String _heureFin(VideoPlayerValue v) {
    final restant = v.duration - v.position;
    final fin = DateTime.now().add(Duration(milliseconds: (restant.inMilliseconds / _vitesse).round()));
    return '${fin.hour.toString().padLeft(2, '0')}:${fin.minute.toString().padLeft(2, '0')}';
  }

  // ── zoom & pincement 2 doigts ───────────────────────────────────────
  void _gererPointeur(PointerEvent e) {
    if (_verrou || _audio) {
      _pointeurs.clear();
      _distanceDebutPince = 0;
      return;
    }
    if (e is PointerDownEvent) {
      _pointeurs[e.pointer] = e.position;
      if (_pointeurs.length == 2) {
        final p = _pointeurs.values.toList();
        _distanceDebutPince = (p[0] - p[1]).distance;
        _zoomDebutPince = _zoom;
        _milieuPincePrecedent = (p[0] + p[1]) / 2;
      }
    } else if (e is PointerMoveEvent) {
      _pointeurs[e.pointer] = e.position;
      if (_pointeurs.length == 2 && _distanceDebutPince > 12) {
        final p = _pointeurs.values.toList();
        final d = (p[0] - p[1]).distance;
        final milieu = (p[0] + p[1]) / 2;
        final facteur = d / _distanceDebutPince;
        final nouveauZoom = (_zoomDebutPince * facteur).clamp(1.0, 3.5);
        final taille = MediaQuery.sizeOf(context);
        final deltaPan = milieu - _milieuPincePrecedent;
        _milieuPincePrecedent = milieu;
        setState(() {
          if (nouveauZoom < 1.04 && _zoomDebutPince > 1.04) {
            _zoom = 1.0;
            _panZoom = Offset.zero;
          } else {
            _zoom = nouveauZoom;
            final maxDx = (taille.width * (_zoom - 1)) / 2;
            final maxDy = (taille.height * (_zoom - 1)) / 2;
            _panZoom = Offset(
              (_panZoom.dx + deltaPan.dx).clamp(-maxDx, maxDx),
              (_panZoom.dy + deltaPan.dy).clamp(-maxDy, maxDy),
            );
          }
        });
      }
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointeurs.remove(e.pointer);
      if (_pointeurs.length < 2) {
        _distanceDebutPince = 0;
        if (_zoom < 1.06) {
          setState(() {
            _zoom = 1.0;
            _panZoom = Offset.zero;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final taille = MediaQuery.sizeOf(context);
    if (_pip && ctrl != null) {
      return Scaffold(backgroundColor: Colors.black, body: _image(ctrl));
    }
    final ligneSt = (ctrl != null && ctrl.value.isInitialized) ? _sousTitreActif(ctrl.value.position) : null;
    final zoome = _zoom > 1.04 && !_audio;

    return PopScope(
      canPop: !_verrou,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _erreur != null
            ? _vueErreur()
            : ctrl == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Stack(fit: StackFit.expand, children: [
                    // Zone vidéo + gestes tactiles dédiés
                    Listener(
                      onPointerDown: _gererPointeur,
                      onPointerMove: _gererPointeur,
                      onPointerUp: _gererPointeur,
                      onPointerCancel: _gererPointeur,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _basculerControles,
                        onDoubleTapDown: _verrou
                            ? null
                            : (d) {
                                final x = d.localPosition.dx / taille.width;
                                if (x < 0.36) {
                                  _sauter(-1);
                                } else if (x > 0.64) {
                                  _sauter(1);
                                } else {
                                  _lecturePause(flashCentre: true);
                                }
                              },
                        onDoubleTap: _verrou ? null : () {},
                        onLongPressStart: _verrou
                            ? null
                            : (_) {
                                _interaction = true;
                                _masquer?.cancel();
                                _vitesseAvantAppuiLong = _vitesse;
                                ctrl.setPlaybackSpeed(_vitesseMaintien);
                                HapticFeedback.mediumImpact();
                                setState(() {
                                  _indication = '${_libVitesse(_vitesseMaintien)} ▶▶';
                                  _iconeIndication = Icons.speed_rounded;
                                });
                              },
                        onLongPressEnd: _verrou
                            ? null
                            : (_) {
                                _interaction = false;
                                _programmerMasquage();
                                ctrl.setPlaybackSpeed(_vitesseAvantAppuiLong ?? _vitesse);
                                setState(() => _indication = null);
                              },
                        onPanUpdate: (zoome && !_verrou)
                            ? (d) {
                                final maxDx = (taille.width * (_zoom - 1)) / 2;
                                final maxDy = (taille.height * (_zoom - 1)) / 2;
                                setState(() {
                                  _panZoom = Offset(
                                    (_panZoom.dx + d.delta.dx).clamp(-maxDx, maxDx),
                                    (_panZoom.dy + d.delta.dy).clamp(-maxDy, maxDy),
                                  );
                                });
                              }
                            : null,
                        onHorizontalDragStart: (_verrou || !_gestes || zoome || _pointeurs.length > 1)
                            ? null
                            : (d) {
                                _interaction = true;
                                _masquer?.cancel();
                                _debutGlisse = d.localPosition.dx;
                                _positionDebut = ctrl.value.position;
                              },
                        onHorizontalDragUpdate: (_verrou || !_gestes || zoome || _pointeurs.length > 1)
                            ? null
                            : (d) {
                                final total = ctrl.value.duration;
                                final portee = total.inSeconds < 90 ? total.inMilliseconds : 90000;
                                final delta = (d.localPosition.dx - _debutGlisse) / taille.width * portee;
                                var cible = _positionDebut + Duration(milliseconds: delta.round());
                                if (cible < Duration.zero) cible = Duration.zero;
                                if (cible > total) cible = total;
                                final ecart = cible - _positionDebut;
                                final ch = _chapitrePour(cible);
                                setState(() {
                                  _cible = cible;
                                  _indication =
                                      '${_temps(cible)}  (${ecart.isNegative ? '−' : '+'}${_temps(ecart.abs())})${ch != null ? '\n${ch.titre}' : ''}';
                                  _iconeIndication = ecart.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded;
                                });
                              },
                        onHorizontalDragEnd: (_verrou || !_gestes || zoome)
                            ? null
                            : (_) {
                                _interaction = false;
                                _programmerMasquage();
                                final c = _cible;
                                setState(() {
                                  _cible = null;
                                  _indication = null;
                                });
                                if (c != null) ctrl.seekTo(c).then((_) => _synchro());
                              },
                        onVerticalDragUpdate: (_verrou || !_gestes || _audio || zoome || _pointeurs.length > 1)
                            ? null
                            : (d) {
                                _interaction = true;
                                _masquer?.cancel();
                                final variation = -d.delta.dy / (taille.height * 0.55);
                                if (d.localPosition.dx < taille.width / 2) {
                                  _luminosite = (_luminosite + variation).clamp(0.0, 1.0);
                                  Natif.luminosite(_luminosite);
                                  _montrerBarre('lum');
                                } else {
                                  _volume = (_volume + variation).clamp(0.0, 1.0);
                                  ctrl.setVolume(_volume);
                                  _montrerBarre('vol');
                                }
                              },
                        onVerticalDragEnd: (_verrou || !_gestes || _audio || zoome)
                            ? null
                            : (_) {
                                _interaction = false;
                                _programmerMasquage();
                              },
                        child: SizedBox.expand(
                          child: _imageTransformee(ctrl),
                        ),
                      ),
                    ),

                    // Filtre nuit anti-lumière bleue
                    if (_nuit > 0.01 && !_audio)
                      IgnorePointer(
                        child: ColoredBox(color: const Color(0xFFFF9329).withAlpha((_nuit * 180).round())),
                      ),

                    // Sous-titres stylisés
                    if (ligneSt != null)
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: (_controles ? 124.0 : _margeSt.toDouble()),
                        child: IgnorePointer(
                          child: Center(
                            child: _bulleSousTitre(ligneSt.texte),
                          ),
                        ),
                      ),

                    if (ctrl.value.isBuffering && ctrl.value.isPlaying)
                      const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),

                    _ondeSaut(taille),
                    if (_poulsCentre) _flashPlayPause(ctrl.value.isPlaying),
                    if (_barre != null) _barreLateral(),
                    if (_indication != null) Center(child: _bulle()),
                    if (zoome && !_verrou)
                      Positioned(
                        top: 12,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          child: Center(
                            child: GestureDetector(
                              onTap: _reinitialiserZoom,
                              child: _piluleVerre(
                                icone: Icons.fit_screen_rounded,
                                texte: 'Zoom ${_zoom.toStringAsFixed(1)}× · Réinitialiser',
                              ),
                            ),
                          ),
                        ),
                      ),
                    _surcouche(ctrl),
                    if (_compteur != null) _carteSuivant(),
                  ]),
      ),
    );
  }

  Widget _bulleSousTitre(String texte) {
    final couleur = (_couleursSt[_couleurSt] ?? _couleursSt['blanc']!).$2;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.symmetric(horizontal: _fondSt ? 14 : 6, vertical: _fondSt ? 6 : 2),
      decoration: _fondSt
          ? BoxDecoration(
              color: const Color(0xBD090B16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(24)),
            )
          : null,
      child: Text(
        texte,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: _tailleSt.toDouble(),
          color: couleur,
          fontWeight: FontWeight.w600,
          height: 1.32,
          shadows: const [Shadow(blurRadius: 6, color: Colors.black), Shadow(blurRadius: 2, color: Colors.black)],
        ),
      ),
    );
  }

  Widget _vueErreur() => SafeArea(
        child: Stack(children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, color: Colors.white70, size: 46),
                const SizedBox(height: 12),
                Text(_erreur!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: _charger, icon: const Icon(Icons.refresh_rounded), label: const Text('Réessayer')),
                if (_tache.fichierPrincipal != null)
                  TextButton(
                    onPressed: () => Natif.ouvrir(_tache.fichierPrincipal!.uri, _tache.fichierPrincipal!.mime),
                    child: const Text('Ouvrir avec une autre application'),
                  ),
                if (_aSuivant)
                  TextButton(onPressed: () => _aller(_index + 1), child: const Text('Passer au suivant')),
              ]),
            ),
          ),
          IconButton(
            color: Colors.white,
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      );

  Widget _imageTransformee(VideoPlayerController ctrl) {
    Widget contenu = _image(ctrl);
    if (_miroir && !_audio) {
      contenu = Transform.flip(flipX: true, child: contenu);
    }
    if (_zoom > 1.01 && !_audio) {
      contenu = ClipRect(
        child: Transform.translate(
          offset: _panZoom,
          child: Transform.scale(scale: _zoom, child: contenu),
        ),
      );
    }
    return contenu;
  }

  Widget _image(VideoPlayerController ctrl) {
    if (_audio) {
      final m = _tache.miniature;
      return Stack(fit: StackFit.expand, children: [
        if (m != null)
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Opacity(
                opacity: 0.5,
                child: Image(image: ResizeImage(miniatures.image(m), width: 240), fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: AnimatedBuilder(
              animation: _pouls,
              builder: (_, child) =>
                  Transform.scale(scale: 0.96 + 0.05 * Curves.easeInOut.transform(_pouls.value), child: child),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [BoxShadow(color: context.c.indigo.withAlpha(110), blurRadius: 50, spreadRadius: 2)],
                ),
                child: Miniature(m, largeur: 320, rayon: 22),
              ),
            ),
          ),
        ),
      ]);
    }
    final t = ctrl.value.size;
    switch (_format) {
      case 2:
        return Center(child: AspectRatio(aspectRatio: 16 / 9, child: VideoPlayer(ctrl)));
      case 3:
        return Center(child: AspectRatio(aspectRatio: 4 / 3, child: VideoPlayer(ctrl)));
      case 4:
        return Center(child: AspectRatio(aspectRatio: 21 / 9, child: VideoPlayer(ctrl)));
      case 5:
        return SizedBox.expand(child: VideoPlayer(ctrl));
      default:
        return ClipRect(
          child: FittedBox(
            fit: _format == 1 ? BoxFit.cover : BoxFit.contain,
            child: SizedBox(
              width: t.width > 0 ? t.width : 16,
              height: t.height > 0 ? t.height : 9,
              child: VideoPlayer(ctrl),
            ),
          ),
        );
    }
  }

  Widget _piluleVerre({IconData? icone, required String texte}) => ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xBB0D1123),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withAlpha(30)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icone != null) ...[
                Icon(icone, color: context.c.cyan, size: 17),
                const SizedBox(width: 7),
              ],
              Text(texte, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12.5)),
            ]),
          ),
        ),
      );

  Widget _bulle() => IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xC80D1123),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withAlpha(32)),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(90), blurRadius: 24)],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_iconeIndication != null) ...[
                  Icon(_iconeIndication, color: context.c.cyan, size: 22),
                  const SizedBox(width: 10),
                ],
                Text(
                  _indication!,
                  textAlign: TextAlign.center,
                  style: mono(context, taille: 14.5, couleur: Colors.white, poids: FontWeight.w700),
                ),
              ]),
            ),
          ),
        ),
      );

  Widget _flashPlayPause(bool lecture) => IgnorePointer(
        child: Center(
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xAA0E1226),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withAlpha(36)),
                ),
                child: Icon(lecture ? Icons.play_arrow_rounded : Icons.pause_rounded, color: Colors.white, size: 38),
              ),
            ),
          ),
        ),
      );

  Widget _ondeSaut(Size taille) {
    final gauche = _onde < 0;
    return Positioned(
      top: 0,
      bottom: 0,
      left: gauche ? 0 : null,
      right: gauche ? null : 0,
      width: taille.width * 0.36,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _onde == 0 ? 0 : 1,
          duration: const Duration(milliseconds: 180),
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: gauche ? Alignment.centerLeft : Alignment.centerRight,
                radius: 1.0,
                colors: [Colors.white.withAlpha(58), Colors.white.withAlpha(8)],
              ),
              borderRadius: BorderRadius.horizontal(
                left: gauche ? Radius.zero : const Radius.circular(420),
                right: gauche ? const Radius.circular(420) : Radius.zero,
              ),
            ),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(gauche ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded, color: Colors.white, size: 36),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xB00E1226),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '${_cumulSaut.abs()} s',
                  style: mono(context, taille: 14, couleur: Colors.white, poids: FontWeight.w800),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _barreLateral() {
    final lum = _barre == 'lum';
    final val = lum ? _luminosite : _volume;
    final c = context.c;
    final couleur = lum ? c.ambre : c.cyan;
    return Positioned(
      top: 0,
      bottom: 0,
      left: lum ? 24 : null,
      right: lum ? null : 24,
      child: SafeArea(
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 48,
                height: 200,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xBA0D1123),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withAlpha(28)),
                ),
                child: Column(children: [
                  Text('${(val * 100).round()}', style: mono(context, taille: 12, couleur: Colors.white, poids: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        width: 7,
                        child: Stack(alignment: Alignment.bottomCenter, children: [
                          Container(color: Colors.white24),
                          FractionallySizedBox(
                            heightFactor: val.clamp(0.0, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [c.indigo, couleur],
                                ),
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Icon(
                    lum
                        ? Icons.brightness_6_rounded
                        : val == 0
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                    color: couleur,
                    size: 19,
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _carteSuivant() {
    final suivant = _file[_index + 1];
    final c = context.c;
    return Positioned(
      right: 20,
      bottom: 98,
      child: SafeArea(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: (MediaQuery.sizeOf(context).width - 40).clamp(0, 310).toDouble(),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xD8111528),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withAlpha(30)),
              ),
              child: Row(children: [
                Miniature(suivant.miniature, largeur: 84, rayon: 12),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('Suivant dans $_compte s', style: TextStyle(color: c.cyan, fontWeight: FontWeight.w700, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(suivant.titre,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    Row(children: [
                      TextButton(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 32)),
                        onPressed: () {
                          _annulerCompte();
                          setState(() => _compteAnnule = true);
                        },
                        child: const Text('Annuler'),
                      ),
                      const Spacer(),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: c.indigo,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(0, 32)),
                        onPressed: () {
                          _annulerCompte();
                          _aller(_index + 1);
                        },
                        child: const Text('Lire'),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _surcouche(VideoPlayerController ctrl) {
    final c = context.c;
    final accent = c.indigo;
    const blanc = Colors.white;
    final v = ctrl.value;
    final dureeMs = v.duration.inMilliseconds.clamp(1, 1 << 31);
    final brut = (_cible ?? v.position).inMilliseconds / dureeMs;
    final avancement = (_glisseBarre && _ratioGlisseBarre != null ? _ratioGlisseBarre! : brut).clamp(0.0, 1.0);
    final posAffichee = Duration(milliseconds: (avancement * dureeMs).round());
    final restant = v.duration - posAffichee;
    final compact = MediaQuery.sizeOf(context).width < 390;
    final fin = v.duration > Duration.zero && posAffichee >= v.duration;
    final chapActif = _chapitrePour(posAffichee);
    final qualiteBadge = _qualiteBadge(v);

    if (_verrou) {
      return IgnorePointer(
        ignoring: !_controles,
        child: AnimatedOpacity(
          opacity: _controles ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xC8111528),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: Colors.white.withAlpha(36)),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(28),
                        onLongPress: () {
                          HapticFeedback.mediumImpact();
                          setState(() => _verrou = false);
                          _programmerMasquage();
                        },
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _verrou = false);
                          _programmerMasquage();
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.lock_open_rounded, color: blanc, size: 18),
                            SizedBox(width: 8),
                            Text('Écran verrouillé · Déverrouiller',
                                style: TextStyle(color: blanc, fontWeight: FontWeight.w700, fontSize: 13)),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return IgnorePointer(
      ignoring: !_controles,
      child: AnimatedOpacity(
        opacity: _controles ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC060812), Color(0x18000000), Color(0x18000000), Color(0xE2060812)],
              stops: [0, 0.25, 0.62, 1],
            ),
          ),
          child: SafeArea(
            child: Stack(children: [
              // Barre du haut (Liquid Glass)
              Positioned(
                left: 6,
                right: 6,
                top: 4,
                child: Row(children: [
                  _ib(Icons.arrow_back_rounded, 'Retour', () => Navigator.of(context).pop()),
                  const SizedBox(width: 4),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _menuInfos,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text(
                              _tache.titre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: blanc, fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ),
                          if (qualiteBadge != null && !compact) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.indigo.withAlpha(70),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: c.indigo.withAlpha(120)),
                              ),
                              child: Text(qualiteBadge, style: mono(context, taille: 10, couleur: blanc, poids: FontWeight.w700)),
                            ),
                          ],
                        ]),
                        const SizedBox(height: 1),
                        Text(
                          [
                            if (_tache.chaine != null) _tache.chaine!,
                            if (_file.length > 1) '${_index + 1}/${_file.length}',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ]),
                    ),
                  ),
                  if (!_audio) _ib(Icons.picture_in_picture_alt_rounded, 'Image dans l’image', _entrerPip),
                  if (_aSousTitres && !compact)
                    GestureDetector(
                      onLongPress: _menuSousTitres,
                      child: _ib(
                        _sousTitresActifs ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined,
                        'Sous-titres (appui long : options)',
                        () {
                          setState(() => _sousTitresActifs = !_sousTitresActifs);
                          _retenir('lecteur_st', _sousTitresActifs);
                          _programmerMasquage();
                        },
                        actif: _sousTitresActifs,
                      ),
                    ),
                  if (!compact)
                    _ib(Icons.graphic_eq_rounded, 'Studio Audio & Égaliseur', _menuStudioAudio, actif: _eqActif),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(38, 38), padding: const EdgeInsets.symmetric(horizontal: 6)),
                    onPressed: _menuVitesse,
                    child: Text(
                      _libVitesse(_vitesse) == 'Normale' ? '1×' : _libVitesse(_vitesse),
                      style: mono(context, taille: 13, couleur: _vitesse == 1 ? blanc : c.cyan, poids: FontWeight.w800),
                    ),
                  ),
                  _ib(Icons.tune_rounded, 'Studio & réglages', _menuReglages),
                ]),
              ),

              // Pilule de chapitre courant (si la vidéo a des chapitres)
              if (chapActif != null)
                Positioned(
                  top: 56,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: GestureDetector(
                      onTap: _menuChapitres,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0x9E0D1123),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white.withAlpha(24)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _sauterChapitre(-1),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.chevron_left_rounded, color: Colors.white70, size: 18),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.menu_book_rounded, color: c.cyan, size: 14),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 150).clamp(80, 260)),
                                child: Text(
                                  chapActif.titre,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 4),
                              InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _sauterChapitre(1),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 18),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // Commandes centrales entre le titre et la barre du bas
              Positioned(
                top: chapActif != null ? 88 : 58,
                bottom: 98,
                left: 0,
                right: 0,
                child: LayoutBuilder(
                  builder: (ctx, box) => Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_file.length > 1 && box.maxWidth >= 320)
                        _ib(Icons.skip_previous_rounded, 'Précédent', _index > 0 ? () => _aller(_index - 1) : null, taille: 30),
                      _boutonSaut(-1),
                      const SizedBox(width: 12),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [accent.withAlpha(235), c.violet.withAlpha(220)],
                          ),
                          boxShadow: [BoxShadow(color: accent.withAlpha(90), blurRadius: 28, spreadRadius: 1)],
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withAlpha(70), width: 1.2),
                        ),
                        child: IconButton(
                          iconSize: 52,
                          tooltip: fin ? 'Relire' : v.isPlaying ? 'Pause' : 'Lire',
                          color: blanc,
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (w, a) => ScaleTransition(scale: a, child: w),
                            child: Icon(
                              fin
                                  ? Icons.replay_rounded
                                  : v.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                              key: ValueKey(fin ? 2 : v.isPlaying ? 1 : 0),
                            ),
                          ),
                          onPressed: _lecturePause,
                        ),
                      ),
                      const SizedBox(width: 12),
                      _boutonSaut(1),
                      if (_file.length > 1 && box.maxWidth >= 320)
                        _ib(Icons.skip_next_rounded, 'Suivant', _aSuivant ? () => _aller(_index + 1) : null, taille: 30),
                    ]),
                  ),
                ),
              ),

              // Barre du bas — DISPOSITION STRICTE :
              // Ligne 1 : Temps à gauche + (Format, Rotation, Boucle A-B, File, Verrou) alignés tout à droite.
              // Ligne 2 (juste dessous) : Barre de progression tout près du bord inférieur.
              Positioned(
                left: 12,
                right: 12,
                bottom: 4,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  LayoutBuilder(builder: (ctx, box) {
                    final largeurActions = (_audio ? 144.0 : 240.0)
                        .clamp(0.0, (box.maxWidth - 88).clamp(0.0, double.infinity));
                    return Row(children: [
                      Expanded(
                        child: Semantics(
                          button: true,
                          label: 'Position de lecture. Appuyer pour choisir un moment',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _allerAuTemps,
                            onLongPress: () => setState(() => _reste = !_reste),
                            child: SizedBox(
                              height: 46,
                              child: Row(children: [
                                Flexible(
                                  child: Text(
                                    '${_temps(posAffichee)} / ${_reste ? '−${_temps(restant < Duration.zero ? Duration.zero : restant)}' : _temps(v.duration)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: mono(context, taille: 12.5, couleur: blanc, poids: FontWeight.w600),
                                  ),
                                ),
                                if (!compact && v.isPlaying) ...[
                                  const SizedBox(width: 6),
                                  Text('· fin ${_heureFin(v)}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                ],
                                if (_a != null) ...[
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: _menuBoucleAB,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: c.ambre.withAlpha(65), borderRadius: BorderRadius.circular(6)),
                                      child: Text(
                                        _b == null ? 'A ${_temps(_a!)}' : 'A→B',
                                        style: mono(context, taille: 10.5, couleur: blanc, poids: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: largeurActions),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (!_audio) ...[
                              GestureDetector(
                                onLongPress: _menuImage,
                                child: _ib(
                                  _format == 1 ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded,
                                  'Format : ${_formats[_format]}',
                                  () => _changerFormat((_format + 1) % _formats.length),
                                  taille: 22,
                                ),
                              ),
                              GestureDetector(
                                onLongPress: _menuOrientation,
                                child: _ib(
                                  Icons.screen_rotation_rounded,
                                  'Pivoter · paysage dans les deux sens',
                                  _pivoter,
                                  taille: 22,
                                ),
                              ),
                            ],
                            GestureDetector(
                              onLongPress: _menuBoucleAB,
                              child: _ib(
                                _b != null ? Icons.repeat_on_rounded : Icons.flag_outlined,
                                _a == null ? 'Boucle A-B : définir A' : _b == null ? 'Définir B' : 'Retirer la boucle',
                                _boucleAB,
                                actif: _a != null,
                                taille: 22,
                              ),
                            ),
                            _ib(Icons.queue_music_rounded, 'File d’attente', _menuFile, taille: 22),
                            _ib(Icons.lock_open_rounded, 'Verrouiller l’écran', () {
                              HapticFeedback.lightImpact();
                              setState(() {
                                _verrou = true;
                                _controles = true;
                              });
                              _programmerMasquage();
                            }, taille: 22),
                          ]),
                        ),
                      ),
                    ]);
                  }),
                  SizedBox(
                    height: 38,
                    child: LayoutBuilder(builder: (ctx, box) {
                      final largeur = box.maxWidth;
                      double x(Duration d) => 16 + (d.inMilliseconds / dureeMs).clamp(0.0, 1.0) * (largeur - 32);
                      double bufRatio() {
                        if (v.buffered.isEmpty) return 0;
                        final fin = v.buffered.last.end.inMilliseconds / dureeMs;
                        return fin.clamp(0.0, 1.0);
                      }

                      return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
                        // Fond de piste + tampon + intervalle A-B + repères chapitres
                        Positioned(
                          left: 16,
                          right: 16,
                          child: SizedBox(
                            height: 5,
                            child: Stack(clipBehavior: Clip.none, children: [
                              Container(
                                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3)),
                              ),
                              FractionallySizedBox(
                                widthFactor: bufRatio(),
                                child: Container(
                                  decoration: BoxDecoration(color: Colors.white.withAlpha(75), borderRadius: BorderRadius.circular(3)),
                                ),
                              ),
                              if (_a != null && _b != null)
                                Positioned(
                                  left: ((_a!.inMilliseconds / dureeMs).clamp(0.0, 1.0)) * (largeur - 32),
                                  width: (((_b!.inMilliseconds - _a!.inMilliseconds) / dureeMs).clamp(0.0, 1.0)) * (largeur - 32),
                                  top: 0,
                                  bottom: 0,
                                  child: Container(
                                    decoration: BoxDecoration(color: c.ambre.withAlpha(190), borderRadius: BorderRadius.circular(3)),
                                  ),
                                ),
                              for (final ch in _chapitres)
                                if (ch.debutMs > 0 && ch.debutMs < dureeMs)
                                  Positioned(
                                    left: ((ch.debutMs / dureeMs).clamp(0.0, 1.0)) * (largeur - 32) - 1,
                                    top: -1,
                                    bottom: -1,
                                    child: Container(width: 2, color: Colors.black87),
                                  ),
                            ]),
                          ),
                        ),
                        if (_a != null) Positioned(left: x(_a!) - 2, top: 8, bottom: 8, child: Container(width: 3, color: blanc)),
                        if (_b != null) Positioned(left: x(_b!) - 2, top: 8, bottom: 8, child: Container(width: 3, color: c.ambre)),
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4.5,
                            activeTrackColor: accent,
                            inactiveTrackColor: Colors.transparent,
                            thumbColor: blanc,
                            overlayColor: accent.withAlpha(55),
                            thumbShape: RoundSliderThumbShape(enabledThumbRadius: _glisseBarre ? 9 : 6.5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                          ),
                          child: Slider(
                            value: avancement,
                            onChangeStart: (x) {
                              _glisseBarre = true;
                              _ratioGlisseBarre = x;
                              _masquer?.cancel();
                              setState(() {});
                            },
                            onChanged: (x) => setState(() => _ratioGlisseBarre = x),
                            onChangeEnd: (x) async {
                              final cible = Duration(milliseconds: (x * dureeMs).round());
                              await ctrl.seekTo(cible);
                              _glisseBarre = false;
                              _ratioGlisseBarre = null;
                              _synchro();
                              _programmerMasquage();
                            },
                          ),
                        ),
                        if (_glisseBarre)
                          Positioned(
                            left: (16 + avancement * (largeur - 32) - 65).clamp(4.0, math.max(4.0, largeur - 134)),
                            top: chapActif != null ? -54 : -38,
                            child: IgnorePointer(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                                  child: Container(
                                    constraints: const BoxConstraints(maxWidth: 150),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xDC111528),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.white.withAlpha(32)),
                                    ),
                                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                                      Text(_temps(posAffichee), style: mono(context, taille: 12.5, couleur: blanc, poids: FontWeight.w800)),
                                      if (chapActif != null)
                                        Text(
                                          chapActif.titre,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: c.cyan, fontSize: 10, fontWeight: FontWeight.w600),
                                        ),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ]);
                    }),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  String? _qualiteBadge(VideoPlayerValue v) {
    if (_audio) return 'AUDIO';
    final h = math.min(v.size.width.round(), v.size.height.round());
    if (h <= 0) return null;
    if (h >= 2100) return '4K';
    if (h >= 1400) return '1440p';
    if (h >= 1000) return '1080p';
    if (h >= 700) return '720p';
    if (h >= 460) return '480p';
    return '${h}p';
  }

  Widget _boutonSaut(int sens) {
    final icone = switch (_saut) {
      5 => sens > 0 ? Icons.forward_5_rounded : Icons.replay_5_rounded,
      10 => sens > 0 ? Icons.forward_10_rounded : Icons.replay_10_rounded,
      30 => sens > 0 ? Icons.forward_30_rounded : Icons.replay_30_rounded,
      _ => sens > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
    };
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(80),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withAlpha(24)),
          ),
          child: _ib(icone, '${sens > 0 ? 'Avancer' : 'Reculer'} de $_saut s', () => _sauter(sens, onde: false), taille: 32),
        ),
      ),
    );
  }

  Widget _ib(IconData icone, String aide, VoidCallback? tap, {bool actif = false, double taille = 24}) => IconButton(
        tooltip: aide,
        icon: Icon(icone, size: taille),
        color: actif ? context.c.cyan : Colors.white,
        disabledColor: Colors.white30,
        onPressed: tap == null
            ? null
            : () {
                tap();
                _programmerMasquage();
              },
      );
}

class _CartePointAB extends StatelessWidget {
  final String titre, valeur;
  final bool actif;
  final Color couleur;
  final VoidCallback onMarquer;
  final VoidCallback? onReculer, onAvancer;

  const _CartePointAB({
    required this.titre,
    required this.valeur,
    required this.actif,
    required this.couleur,
    required this.onMarquer,
    this.onReculer,
    this.onAvancer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: actif ? couleur.withAlpha(32) : Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: actif ? couleur.withAlpha(130) : Colors.white.withAlpha(18)),
      ),
      child: Column(children: [
        Text(titre, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(valeur, style: mono(context, taille: 17, couleur: actif ? Colors.white : Colors.white38, poids: FontWeight.w800)),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove_rounded, color: Colors.white70, size: 18),
            onPressed: onReculer,
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: couleur,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
            ),
            onPressed: onMarquer,
            child: const Text('Ici', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_rounded, color: Colors.white70, size: 18),
            onPressed: onAvancer,
          ),
        ]),
      ]),
    );
  }
}
