/// Lecteur intégré pour les vidéos et musiques téléchargées.
///
/// Gestes : double appui à gauche/droite = ±N s (avec onde animée), double appui au centre = lecture/pause,
/// glisser horizontalement = avancer, glisser verticalement à gauche = luminosité, à droite = volume,
/// appui long = vitesse ×2, pincer = remplir/ajuster l'image.
/// Réglages : vitesse, pistes audio (doublage/VO), sous-titres (taille), format d'image, boucle A-B,
/// répétition, minuteur de sommeil, saut configurable, lecture automatique, file d'attente, infos.
/// La lecture continue en arrière-plan (notification média, écran verrouillé), une vidéo passe en
/// image dans l'image quand on quitte l'app, l'écran reste allumé et la position est mémorisée.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../moteur/gouts.dart';
import '../moteur/langues.dart' as langues;
import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'theme.dart';

Future<void> ouvrirLecteur(BuildContext context, List<Tache> liste, int index) =>
    Navigator.of(context).push(PageRouteBuilder(
      pageBuilder: (_, _, _) => Lecteur(liste, index),
      transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
    ));

const _formats = ['Ajuster', 'Remplir', '16:9', '4:3', 'Étirer'];

class Lecteur extends StatefulWidget {
  final List<Tache> liste;
  final int index;
  const Lecteur(this.liste, this.index, {super.key});
  @override
  State<Lecteur> createState() => _LecteurState();
}

class _LecteurState extends State<Lecteur> with SingleTickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  int _generation = 0; // chargement en cours : un « suivant » rapide annule le précédent
  late int _index = widget.index;
  String? _erreur;
  bool _controles = true, _verrou = false, _boucle = false;
  bool _aSousTitres = false, _signale = false, _pip = false, _enLecture = false;
  bool _glisseBarre = false, _reste = false;
  final _abos = <StreamSubscription>[];
  List<VideoAudioTrack> _pistes = [];
  Timer? _masquer, _sommeil;
  int _sommeilMin = 0;

  // Préférences mémorisées entre deux lectures
  double _vitesse = _pref<num>('lecteur_vitesse', 1).toDouble();
  bool _sousTitresActifs = _pref<bool>('lecteur_st', true);
  int _tailleSt = _pref<num>('lecteur_st_taille', 17).toInt();
  int _format = _pref<num>('lecteur_format', 0).toInt();
  int _saut = _pref<num>('lecteur_saut', 10).toInt();
  bool _auto = _pref<bool>('lecteur_auto', true);

  static T _pref<T>(String cle, T defaut) {
    final v = reglages[cle];
    return v is T ? v : defaut;
  }

  void _retenir(String cle, dynamic v) => reglages.ecrireSansPrevenir(cle, v);

  // Boucle A-B
  Duration? _a, _b;

  // Enchaînement
  Timer? _compteur;
  int _compte = 0;
  bool _compteAnnule = false;

  // Gestes
  String? _indication;
  IconData? _iconeIndication;
  Timer? _finIndication;
  int _cumulSaut = 0;
  Timer? _finSaut;
  int _onde = 0; // -1 gauche, 1 droite, 0 aucune
  Timer? _finOnde;
  Duration? _cible; // pendant un glissement
  double _debutGlisse = 0;
  Duration _positionDebut = Duration.zero;
  double _luminosite = 0.5, _volume = 1;
  double? _vitesseAvantAppuiLong;
  String? _barre; // 'lum' | 'vol' pendant un glissement vertical
  Timer? _finBarre;
  final _pointeurs = <int, Offset>{};
  double _distancePincement = 0;
  late final AnimationController _pouls =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  Tache get _tache => widget.liste[_index];
  bool get _audio => _tache.fichierPrincipal?.mime.startsWith('audio') ?? false;
  bool get _aSuivant => _index < widget.liste.length - 1;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Natif.luminosite().then((v) => _luminosite = v);
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
    setState(() {
      _ctrl = null;
      _erreur = null;
      _pistes = [];
      _aSousTitres = false;
      _signale = false;
      _compteAnnule = false;
      _a = _b = null;
    });
    await ancien?.dispose();
    if (perime()) return;
    final f = _tache.fichierPrincipal;
    if (f == null) {
      setState(() => _erreur = 'Fichier introuvable');
      return;
    }
    final uri = Uri.parse(f.uri);
    final sousTitres = _chargerSousTitres();
    final ctrl = uri.scheme == 'content'
        ? VideoPlayerController.contentUri(uri, closedCaptionFile: sousTitres)
        : VideoPlayerController.file(File(f.chemin.isNotEmpty ? f.chemin : uri.toFilePath()),
            closedCaptionFile: sousTitres);
    try {
      await ctrl.initialize();
    } catch (e) {
      ctrl.dispose();
      if (!perime()) setState(() => _erreur = 'Lecture impossible : fichier déplacé, supprimé ou format non pris en charge.');
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
    if (pos is int && pos > 10000 && pos < ctrl.value.duration.inMilliseconds * 0.95) {
      await ctrl.seekTo(Duration(milliseconds: pos));
    }
    if (perime()) {
      ctrl.dispose();
      return;
    }
    if (pos is int && ctrl.value.position.inMilliseconds > 10000) {
      _indiquer('Reprise à ${_temps(Duration(milliseconds: pos))}', Icons.history_rounded);
    }
    ctrl.addListener(_maj);
    setState(() => _ctrl = ctrl);
    _orienter();
    await ctrl.play();
    if (perime()) return;
    _synchro();
    _programmerMasquage();
    try {
      final p = await ctrl.getAudioTracks();
      if (!perime()) setState(() => _pistes = p);
    } catch (_) {}
  }

  Future<ClosedCaptionFile>? _chargerSousTitres() {
    final st = _tache.fichiers.where((f) => f.nom.endsWith('.srt') || f.nom.endsWith('.vtt')).toList();
    if (st.isEmpty) return null;
    // Français d'abord s'il existe
    st.sort((a, b) => (b.nom.contains('.fr') ? 1 : 0).compareTo(a.nom.contains('.fr') ? 1 : 0));
    final f = st.first;
    _aSousTitres = true;
    return () async {
      final texte = await Natif.lireTexte(f.uri) ?? '';
      final ClosedCaptionFile r = f.nom.endsWith('.vtt') ? WebVTTCaptionFile(texte) : SubRipCaptionFile(texte);
      return r;
    }();
  }

  void _orienter() {
    final c = _ctrl;
    if (c == null || _audio) return;
    SystemChrome.setPreferredOrientations(c.value.aspectRatio >= 1
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
  }

  void _pivoter() {
    final paysage = MediaQuery.orientationOf(context) == Orientation.landscape;
    SystemChrome.setPreferredOrientations(paysage
        ? [DeviceOrientation.portraitUp]
        : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  /// Notification média + image dans l'image automatique + écran allumé : à appeler quand l'état de lecture change.
  void _synchro() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    _enLecture = v.isPlaying;
    if (v.isPlaying) {
      // la pochette ne pulse qu'en musique
      _audio ? _pouls.repeat(reverse: true) : _pouls.stop();
      if (!_pip) WakelockPlus.enable();
    } else {
      _pouls.stop();
      WakelockPlus.disable();
    }
    Natif.media(
      titre: _tache.titre,
      artiste: _tache.chaine ?? '',
      image: _tache.miniature,
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

  /// Boutons de la notification média.
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
    if (v.isInitialized && v.isPlaying != _enLecture) _synchro();
    if (!_signale && v.duration > Duration.zero &&
        (v.position.inSeconds > 60 || v.position.inMilliseconds > v.duration.inMilliseconds * 0.3)) {
      _signale = true;
      gouts.signal('lecture', url: _tache.url, titre: _tache.titre, chaine: _tache.chaine);
    }
    // Boucle A-B
    final b = _b;
    if (b != null && v.isPlaying && v.position >= b) {
      c.seekTo(_a ?? Duration.zero);
    }
    // Fin : morceau suivant (avec compte à rebours pour les vidéos)
    final fini = !_boucle && v.isInitialized && v.duration > Duration.zero && v.position >= v.duration && !v.isPlaying;
    if (fini && _aSuivant && _auto && !_compteAnnule && _compteur == null) {
      _effacerPosition();
      if (_audio) {
        _aller(_index + 1);
        return;
      }
      _demarrerCompte();
    } else if (!fini && _compteur != null) {
      _annulerCompte();
    }
    setState(() {});
  }

  void _demarrerCompte() {
    _compte = 5;
    _controles = true;
    _compteur = Timer.periodic(const Duration(seconds: 1), (t) {
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
      positions[_tache.id] = p; // en dernier : les plus anciennes partent d'abord
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
    if (i < 0 || i >= widget.liste.length) return;
    _memoriserPosition();
    _annulerCompte();
    _ctrl?.removeListener(_maj);
    _ctrl?.pause();
    setState(() => _index = i);
    _charger();
  }

  // ── contrôles ───────────────────────────────────────────────────────
  void _programmerMasquage() {
    _masquer?.cancel();
    _masquer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && (_ctrl?.value.isPlaying ?? false)) setState(() => _controles = false);
    });
  }

  void _basculerControles() {
    setState(() => _controles = !_controles);
    if (_controles) _programmerMasquage();
  }

  void _lecturePause() {
    final c = _ctrl;
    if (c == null) return;
    final v = c.value;
    if (v.position >= v.duration && v.duration > Duration.zero) {
      _annulerCompte();
      c.seekTo(Duration.zero).then((_) => c.play());
    } else {
      v.isPlaying ? c.pause() : c.play();
    }
    if (v.isPlaying) _memoriserPosition();
    _programmerMasquage();
  }

  void _indiquer(String texte, IconData icone) {
    _finIndication?.cancel();
    setState(() {
      _indication = texte;
      _iconeIndication = icone;
    });
    _finIndication = Timer(const Duration(milliseconds: 1000), () {
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
      _indiquer('${_cumulSaut > 0 ? '+' : ''}$_cumulSaut s', sens > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
    }
    _finSaut?.cancel();
    _finSaut = Timer(const Duration(milliseconds: 900), () => _cumulSaut = 0);
  }

  void _montrerBarre(String type) {
    _finBarre?.cancel();
    setState(() => _barre = type);
    _finBarre = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _barre = null);
    });
  }

  void _changerVitesse(double v) {
    setState(() => _vitesse = v);
    _retenir('lecteur_vitesse', v);
    _ctrl?.setPlaybackSpeed(v);
    _synchro();
  }

  void _changerFormat(int f) {
    setState(() => _format = f);
    _retenir('lecteur_format', f);
    _indiquer(_formats[f], Icons.aspect_ratio_rounded);
  }

  void _boucleAB() {
    final c = _ctrl;
    if (c == null) return;
    final p = c.value.position;
    setState(() {
      if (_a == null) {
        _a = p;
        _indiquer('Début de boucle A · ${_temps(p)}', Icons.flag_rounded);
      } else if (_b == null) {
        if (p <= _a! + const Duration(seconds: 1)) {
          _indiquer('Choisis un point B après A', Icons.flag_outlined);
          return;
        }
        _b = p;
        _indiquer('Boucle A-B active', Icons.repeat_rounded);
      } else {
        _a = _b = null;
        _indiquer('Boucle A-B retirée', Icons.repeat_rounded);
      }
    });
    _programmerMasquage();
  }

  // ── feuilles ────────────────────────────────────────────────────────
  Future<T?> _feuille<T>(Widget Function(BuildContext, StateSetter) contenu, {bool grande = false}) {
    _masquer?.cancel();
    return showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      isScrollControlled: grande,
      backgroundColor: const Color(0xF2121426),
      barrierColor: Colors.black38,
      constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => SafeArea(child: StatefulBuilder(builder: contenu)),
    ).whenComplete(_programmerMasquage);
  }

  Widget _poignee(String titre) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
                width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          ),
          Text(titre, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: Colors.white)),
        ]),
      );

  Future<void> _choisir<T>(String titre, List<(T, String, bool)> options, void Function(T) choix) async {
    final r = await _feuille<T>((ctx, _) => SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee(titre),
            for (final (v, l, actif) in options)
              ListTile(
                title: Text(l, style: TextStyle(color: actif ? context.c.indigo : Colors.white, fontWeight: actif ? FontWeight.w700 : FontWeight.w400)),
                trailing: actif ? Icon(Icons.check_rounded, color: context.c.indigo) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ]),
        ));
    if (r != null) choix(r);
  }

  String _libVitesse(double v) => v == 1 ? 'Normale' : '${'$v'.replaceAll('.0', '').replaceAll('.', ',')}×';

  void _menuVitesse() => _feuille<void>((ctx, maj) {
        final c = context.c;
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Vitesse de lecture'),
            Center(
              child: Text(_libVitesse(_vitesse),
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: () {
                      _changerVitesse(((_vitesse - 0.05).clamp(0.25, 3.0) * 20).round() / 20);
                      maj(() {});
                    }),
                Expanded(
                  child: Slider(
                    min: 0.25,
                    max: 3,
                    divisions: 55,
                    value: _vitesse.clamp(0.25, 3.0),
                    activeColor: c.indigo,
                    onChanged: (x) {
                      _changerVitesse((x * 20).round() / 20);
                      maj(() {});
                    },
                  ),
                ),
                IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: () {
                      _changerVitesse(((_vitesse + 0.05).clamp(0.25, 3.0) * 20).round() / 20);
                      maj(() {});
                    }),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
                  ChoiceChip(
                    label: Text(v == 1 ? '1×' : '${'$v'.replaceAll('.0', '').replaceAll('.', ',')}×'),
                    selected: (v - _vitesse).abs() < 0.001,
                    onSelected: (_) {
                      _changerVitesse(v);
                      maj(() {});
                    },
                  ),
              ]),
            ),
          ]),
        );
      });

  void _menuSommeil() => _choisir<int>('Minuteur de sommeil', [
        for (final m in const [0, 10, 20, 30, 45, 60, 90])
          (m, m == 0 ? 'Désactivé' : '$m minutes', m == _sommeilMin),
      ], (m) {
        _sommeil?.cancel();
        setState(() => _sommeilMin = m);
        if (m == 0) return;
        _sommeil = Timer(Duration(minutes: m), () {
          _ctrl?.pause();
          if (mounted) setState(() => _sommeilMin = 0);
        });
        _indiquer('La lecture s’arrêtera dans $m min', Icons.bedtime_rounded);
      });

  String _nomPiste(VideoAudioTrack p, int i) {
    final code = p.language;
    final nom = code != null && code != 'und' ? '${langues.drapeau(code)} ${langues.nom(code)}' : null;
    return [nom ?? 'Piste ${i + 1}', if (p.label != null && p.label!.isNotEmpty && p.label != nom) p.label!].join(' · ');
  }

  void _menuPistes() => _choisir<String>('Piste audio', [
        for (var i = 0; i < _pistes.length; i++) (_pistes[i].id, _nomPiste(_pistes[i], i), _pistes[i].isSelected),
      ], (id) async {
        final c = _ctrl;
        if (c == null) return;
        await c.selectAudioTrack(id);
        final p = await c.getAudioTracks();
        if (mounted) setState(() => _pistes = p);
      });

  void _menuSousTitres() => _choisir<int>('Sous-titres', [
        (0, 'Désactivés', !_sousTitresActifs),
        for (final (t, n) in const [(14, 'Petits'), (17, 'Moyens'), (21, 'Grands'), (26, 'Très grands')])
          (t, n, _sousTitresActifs && t == _tailleSt),
      ], (t) {
        setState(() {
          _sousTitresActifs = t != 0;
          if (t != 0) _tailleSt = t;
        });
        _retenir('lecteur_st', _sousTitresActifs);
        _retenir('lecteur_st_taille', _tailleSt);
      });

  void _menuFormat() => _choisir<int>('Format de l’image', [
        for (var i = 0; i < _formats.length; i++) (i, _formats[i], i == _format),
      ], _changerFormat);

  void _menuSaut() => _choisir<int>('Durée des sauts', [
        for (final s in const [5, 10, 15, 30, 60]) (s, '$s secondes', s == _saut),
      ], (s) {
        setState(() => _saut = s);
        _retenir('lecteur_saut', s);
      });

  void _menuFile() {
    _feuille<void>((ctx, _) {
      final c = context.c;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        _poignee('File d’attente · ${_index + 1}/${widget.liste.length}'),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: widget.liste.length,
            itemBuilder: (_, i) {
              final t = widget.liste[i];
              final actuel = i == _index;
              return ListTile(
                selected: actuel,
                selectedTileColor: c.indigo.withAlpha(40),
                leading: Miniature(t.miniature, largeur: 72, rayon: 8),
                title: Text(t.titre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: actuel ? c.indigo : Colors.white, fontWeight: actuel ? FontWeight.w700 : FontWeight.w400, fontSize: 14)),
                subtitle: t.chaine == null ? null : Text(t.chaine!, maxLines: 1, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: actuel ? Icon(Icons.equalizer_rounded, color: c.indigo) : null,
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
  }

  void _menuInfos() {
    final c = _ctrl;
    final f = _tache.fichierPrincipal;
    final t = c?.value.size ?? Size.zero;
    String taille(int o) => o > 1 << 30 ? '${(o / (1 << 30)).toStringAsFixed(2)} Go' : '${(o / (1 << 20)).toStringAsFixed(1)} Mo';
    final lignes = <(String, String)>[
      ('Titre', _tache.titre),
      if (_tache.chaine != null) ('Chaîne', _tache.chaine!),
      if (c != null) ('Durée', _temps(c.value.duration)),
      if (!_audio && t.width > 0) ('Résolution', '${t.width.round()} × ${t.height.round()}'),
      if (f != null) ('Format', f.mime),
      if (f != null && f.taille > 0) ('Taille', taille(f.taille)),
      if (_pistes.isNotEmpty) ('Pistes audio', '${_pistes.length}'),
      ('Source', _tache.url),
    ];
    _feuille<void>((ctx, _) => SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Informations'),
            for (final (k, v) in lignes)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 96, child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13))),
                  Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 13))),
                ]),
              ),
          ]),
        ));
  }

  /// Menu principal « Réglages » : tout le reste est rangé ici pour garder un écran épuré.
  void _menuReglages() => _feuille<void>((ctx, maj) {
        final c = context.c;
        Widget ligne(IconData ic, String titre, String? valeur, VoidCallback tap) => ListTile(
              dense: true,
              leading: Icon(ic, color: Colors.white70),
              title: Text(titre, style: const TextStyle(color: Colors.white)),
              trailing: valeur == null ? null : Text(valeur, style: TextStyle(color: c.indigo, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(ctx);
                tap();
              },
            );
        Widget bascule(IconData ic, String titre, bool val, ValueChanged<bool> ch) => SwitchListTile(
              dense: true,
              secondary: Icon(ic, color: Colors.white70),
              title: Text(titre, style: const TextStyle(color: Colors.white)),
              value: val,
              activeThumbColor: c.indigo,
              onChanged: (x) {
                ch(x);
                maj(() {});
              },
            );
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _poignee('Réglages du lecteur'),
            ligne(Icons.speed_rounded, 'Vitesse de lecture', _libVitesse(_vitesse), _menuVitesse),
            if (_pistes.length > 1) ligne(Icons.translate_rounded, 'Piste audio', null, _menuPistes),
            if (_aSousTitres)
              ligne(Icons.closed_caption_rounded, 'Sous-titres', _sousTitresActifs ? '$_tailleSt pt' : 'Désactivés', _menuSousTitres),
            if (!_audio) ligne(Icons.aspect_ratio_rounded, 'Format de l’image', _formats[_format], _menuFormat),
            ligne(Icons.forward_10_rounded, 'Durée des sauts', '$_saut s', _menuSaut),
            ligne(Icons.bedtime_outlined, 'Minuteur de sommeil', _sommeilMin > 0 ? '$_sommeilMin min' : 'Désactivé', _menuSommeil),
            bascule(Icons.repeat_one_rounded, 'Répéter ce titre', _boucle, (x) {
              setState(() => _boucle = x);
              _ctrl?.setLooping(x);
            }),
            bascule(Icons.playlist_play_rounded, 'Lecture automatique du suivant', _auto, (x) {
              setState(() => _auto = x);
              _retenir('lecteur_auto', x);
            }),
            if (widget.liste.length > 1) ligne(Icons.queue_music_rounded, 'File d’attente', '${widget.liste.length}', _menuFile),
            ligne(Icons.info_outline_rounded, 'Informations', null, _menuInfos),
          ]),
        );
      }, grande: true);

  // ── interface ───────────────────────────────────────────────────────
  String _temps(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  String _heureFin(VideoPlayerValue v) {
    final restant = v.duration - v.position;
    final fin = DateTime.now().add(Duration(milliseconds: (restant.inMilliseconds / _vitesse).round()));
    return '${fin.hour.toString().padLeft(2, '0')}:${fin.minute.toString().padLeft(2, '0')}';
  }

  void _pincement(PointerEvent e) {
    if (e is PointerDownEvent || e is PointerMoveEvent) _pointeurs[e.pointer] = e.position;
    if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointeurs.remove(e.pointer);
      _distancePincement = 0;
      return;
    }
    if (_pointeurs.length == 2 && !_audio) {
      final p = _pointeurs.values.toList();
      final d = (p[0] - p[1]).distance;
      if (_distancePincement == 0) {
        _distancePincement = d;
      } else if (d / _distancePincement > 1.25 && _format != 1) {
        _changerFormat(1);
        _distancePincement = d;
        HapticFeedback.lightImpact();
      } else if (d / _distancePincement < 0.8 && _format != 0) {
        _changerFormat(0);
        _distancePincement = d;
        HapticFeedback.lightImpact();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final taille = MediaQuery.sizeOf(context);
    // Fenêtre flottante : l'image seule, sans contrôles
    if (_pip && ctrl != null) return Scaffold(backgroundColor: Colors.black, body: _image(ctrl));
    return PopScope(
      canPop: !_verrou,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _erreur != null
            ? _vueErreur()
            : ctrl == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : Listener(
                    onPointerDown: _pincement,
                    onPointerMove: _pincement,
                    onPointerUp: _pincement,
                    onPointerCancel: _pincement,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _basculerControles,
                      onDoubleTapDown: _verrou
                          ? null
                          : (d) {
                              final x = d.localPosition.dx / taille.width;
                              if (x < 0.38) {
                                _sauter(-1);
                              } else if (x > 0.62) {
                                _sauter(1);
                              } else {
                                _lecturePause();
                              }
                            },
                      onDoubleTap: _verrou ? null : () {},
                      onLongPressStart: _verrou
                          ? null
                          : (_) {
                              _vitesseAvantAppuiLong = _vitesse;
                              ctrl.setPlaybackSpeed(2);
                              HapticFeedback.mediumImpact();
                              setState(() {
                                _indication = '2× ▶▶';
                                _iconeIndication = Icons.speed_rounded;
                              });
                            },
                      onLongPressEnd: _verrou
                          ? null
                          : (_) {
                              ctrl.setPlaybackSpeed(_vitesseAvantAppuiLong ?? 1);
                              setState(() => _indication = null);
                            },
                      onHorizontalDragStart: _verrou || _pointeurs.length > 1
                          ? null
                          : (d) {
                              _debutGlisse = d.localPosition.dx;
                              _positionDebut = ctrl.value.position;
                            },
                      onHorizontalDragUpdate: _verrou || _pointeurs.length > 1
                          ? null
                          : (d) {
                              final total = ctrl.value.duration;
                              // Toute la largeur = 90 s, ou la durée si plus courte
                              final portee = total.inSeconds < 90 ? total.inMilliseconds : 90000;
                              final delta = (d.localPosition.dx - _debutGlisse) / taille.width * portee;
                              var cible = _positionDebut + Duration(milliseconds: delta.round());
                              if (cible < Duration.zero) cible = Duration.zero;
                              if (cible > total) cible = total;
                              final ecart = cible - _positionDebut;
                              setState(() {
                                _cible = cible;
                                _indication = '${_temps(cible)}  (${ecart.isNegative ? '−' : '+'}${_temps(ecart.abs())})';
                                _iconeIndication = ecart.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded;
                              });
                            },
                      onHorizontalDragEnd: _verrou
                          ? null
                          : (_) {
                              if (_cible != null) ctrl.seekTo(_cible!).then((_) => _synchro());
                              setState(() {
                                _cible = null;
                                _indication = null;
                              });
                            },
                      onVerticalDragUpdate: _verrou || _pointeurs.length > 1
                          ? null
                          : (d) {
                              final pas = -d.delta.dy / (taille.height * 0.7);
                              if (d.localPosition.dx < taille.width / 2) {
                                _luminosite = (_luminosite + pas).clamp(0.01, 1.0);
                                Natif.luminosite(_luminosite);
                                _montrerBarre('lum');
                              } else {
                                _volume = (_volume + pas).clamp(0.0, 1.0);
                                ctrl.setVolume(_volume);
                                _montrerBarre('vol');
                              }
                            },
                      child: Stack(fit: StackFit.expand, children: [
                        RepaintBoundary(child: _image(ctrl)),
                        if (_sousTitresActifs && _aSousTitres && ctrl.value.caption.text.isNotEmpty)
                          Positioned(
                            left: 24,
                            right: 24,
                            bottom: _controles ? 112 : 30,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: Colors.black.withAlpha(150), borderRadius: BorderRadius.circular(8)),
                                child: Text(ctrl.value.caption.text,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: _tailleSt.toDouble(),
                                        color: Colors.white,
                                        height: 1.3,
                                        shadows: const [Shadow(blurRadius: 3, color: Colors.black)])),
                              ),
                            ),
                          ),
                        if (ctrl.value.isBuffering && ctrl.value.isPlaying)
                          const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
                        _ondeSaut(taille),
                        if (_barre != null) _barreLateral(),
                        if (_indication != null) Center(child: _bulle()),
                        _surcouche(ctrl),
                        if (_compteur != null) _carteSuivant(),
                      ]),
                    ),
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
                const Icon(Icons.error_outline_rounded, color: Colors.white70, size: 44),
                const SizedBox(height: 12),
                Text(_erreur!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 16),
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

  Widget _image(VideoPlayerController ctrl) {
    if (_audio) {
      // Musique : pochette qui pulse doucement sur fond flouté
      final m = _tache.miniature;
      return Stack(fit: StackFit.expand, children: [
        if (m != null)
          // Isolé et en basse définition : de toute façon flouté, il n'est plus recalculé à chaque pulsation
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: Opacity(
                  opacity: 0.5,
                  child: Image.network(m, fit: BoxFit.cover, cacheWidth: 240, errorBuilder: (_, _, _) => const SizedBox())),
            ),
          ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: AnimatedBuilder(
              animation: _pouls,
              builder: (_, child) => Transform.scale(
                  scale: 0.96 + 0.05 * Curves.easeInOut.transform(_pouls.value), child: child),
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
      case 3:
        return Center(child: AspectRatio(aspectRatio: _format == 2 ? 16 / 9 : 4 / 3, child: VideoPlayer(ctrl)));
      case 4:
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

  Widget _bulle() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(color: Colors.black.withAlpha(170), borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (_iconeIndication != null) Icon(_iconeIndication, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Text(_indication!, style: mono(context, taille: 15, couleur: Colors.white)),
        ]),
      );

  /// Onde animée lors d'un double appui sur le côté gauche/droit.
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
              color: Colors.white.withAlpha(36),
              borderRadius: BorderRadius.horizontal(
                left: gauche ? Radius.zero : const Radius.circular(400),
                right: gauche ? const Radius.circular(400) : Radius.zero,
              ),
            ),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(gauche ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded, color: Colors.white, size: 34),
              const SizedBox(height: 4),
              Text('${_cumulSaut.abs()} s', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
          ),
        ),
      ),
    );
  }

  /// Jauge verticale de luminosité (gauche) ou de volume (droite) pendant le glissement.
  Widget _barreLateral() {
    final lum = _barre == 'lum';
    final val = lum ? _luminosite : _volume;
    return Positioned(
      top: 0,
      bottom: 0,
      left: lum ? 28 : null,
      right: lum ? null : 28,
      child: SafeArea(
        child: Center(
          child: Container(
            width: 44,
            height: 190,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: Colors.black.withAlpha(150), borderRadius: BorderRadius.circular(22)),
            child: Column(children: [
              Text('${(val * 100).round()}', style: mono(context, taille: 12, couleur: Colors.white)),
              const SizedBox(height: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 6,
                    child: Stack(alignment: Alignment.bottomCenter, children: [
                      Container(color: Colors.white24),
                      FractionallySizedBox(heightFactor: val.clamp(0.0, 1.0), child: Container(color: context.c.indigo)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Icon(
                  lum
                      ? Icons.brightness_6_rounded
                      : val == 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                  color: Colors.white,
                  size: 18),
            ]),
          ),
        ),
      ),
    );
  }

  /// Carte « Suivant dans N s » à la fin d'une vidéo de la file.
  Widget _carteSuivant() {
    final suivant = widget.liste[_index + 1];
    final c = context.c;
    return Positioned(
      right: 20,
      bottom: 90,
      child: SafeArea(
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xEE14162A),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(children: [
            Miniature(suivant.miniature, largeur: 84, rayon: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Suivant dans $_compte s', style: TextStyle(color: c.indigo, fontWeight: FontWeight.w700, fontSize: 12)),
                const SizedBox(height: 2),
                Text(suivant.titre, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
                Row(children: [
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(60, 30)),
                    onPressed: () {
                      _annulerCompte();
                      _aller(_index + 1);
                    },
                    child: const Text('Lire'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(60, 30), foregroundColor: Colors.white70),
                    onPressed: () {
                      _compteAnnule = true;
                      setState(_annulerCompte);
                    },
                    child: const Text('Annuler'),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _ib(IconData icone, String info, VoidCallback? tap, {bool actif = false, double taille = 24}) => IconButton(
        color: actif ? context.c.indigo : Colors.white,
        tooltip: info,
        iconSize: taille,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
        padding: EdgeInsets.zero,
        icon: Icon(icone),
        onPressed: tap,
      );

  Widget _surcouche(VideoPlayerController ctrl) {
    final v = ctrl.value;
    final visible = _controles || !v.isPlaying || _audio;
    const blanc = Colors.white;
    if (_verrou) {
      return AnimatedOpacity(
        opacity: _controles ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controles,
          child: SafeArea(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.white24),
                  color: blanc,
                  tooltip: 'Déverrouiller',
                  icon: const Icon(Icons.lock_rounded),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    setState(() => _verrou = false);
                    _programmerMasquage();
                  },
                ),
              ),
            ),
          ),
        ),
      );
    }
    final fin = v.duration > Duration.zero && v.position >= v.duration;
    final position = _cible ?? v.position;
    final dureeMs = v.duration.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
    final accent = context.c.indigo;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xBB000000), Color(0x22000000), Color(0x22000000), Color(0xDD000000)],
              stops: [0, 0.25, 0.65, 1],
            ),
          ),
          child: SafeArea(
            child: Stack(children: [
              // Barre du haut
              Positioned(
                left: 4,
                right: 4,
                top: 4,
                child: Row(children: [
                  _ib(Icons.arrow_back_rounded, 'Retour', () => Navigator.of(context).pop()),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_tache.titre,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: blanc, fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                          [if (_tache.chaine != null) _tache.chaine!, if (widget.liste.length > 1) '${_index + 1}/${widget.liste.length}']
                              .join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
                  ),
                  if (!_audio) _ib(Icons.picture_in_picture_alt_rounded, 'Image dans l’image', _entrerPip),
                  if (_aSousTitres)
                    _ib(_sousTitresActifs ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined, 'Sous-titres',
                        () {
                      setState(() => _sousTitresActifs = !_sousTitresActifs);
                      _retenir('lecteur_st', _sousTitresActifs);
                    }, actif: _sousTitresActifs),
                  if (_pistes.length > 1) _ib(Icons.translate_rounded, 'Piste audio', _menuPistes),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(40, 40), padding: const EdgeInsets.symmetric(horizontal: 6)),
                    onPressed: _menuVitesse,
                    child: Text(_libVitesse(_vitesse) == 'Normale' ? '1×' : _libVitesse(_vitesse),
                        style: TextStyle(color: _vitesse == 1 ? blanc : accent, fontWeight: FontWeight.w800)),
                  ),
                  _ib(Icons.tune_rounded, 'Réglages', _menuReglages),
                ]),
              ),
              // Centre
              Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _ib(Icons.skip_previous_rounded, 'Précédent', _index > 0 ? () => _aller(_index - 1) : null, taille: 36),
                  _ib(Icons.replay_10_rounded, 'Reculer', () => _sauter(-1, onde: false), taille: 34),
                  const SizedBox(width: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30),
                    ),
                    child: IconButton(
                      iconSize: 54,
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
                  const SizedBox(width: 10),
                  _ib(Icons.forward_10_rounded, 'Avancer', () => _sauter(1, onde: false), taille: 34),
                  _ib(Icons.skip_next_rounded, 'Suivant', _aSuivant ? () => _aller(_index + 1) : null, taille: 36),
                ]),
              ),
              // Barre du bas
              Positioned(
                left: 12,
                right: 12,
                bottom: 4,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    height: 40,
                    child: LayoutBuilder(builder: (ctx, box) {
                      final largeur = box.maxWidth;
                      double x(Duration d) => 16 + d.inMilliseconds / dureeMs * (largeur - 32);
                      return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: _glisseBarre ? 5 : 3,
                            thumbShape: RoundSliderThumbShape(enabledThumbRadius: _glisseBarre ? 9 : 6.5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                            activeTrackColor: accent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: blanc,
                            overlayColor: accent.withAlpha(50),
                            secondaryActiveTrackColor: Colors.white38,
                          ),
                          child: Slider(
                            min: 0,
                            max: dureeMs,
                            value: position.inMilliseconds.toDouble().clamp(0, dureeMs),
                            secondaryTrackValue: v.buffered.isEmpty ? null : v.buffered.last.end.inMilliseconds.toDouble().clamp(0, dureeMs),
                            onChangeStart: (_) {
                              _masquer?.cancel();
                              setState(() => _glisseBarre = true);
                            },
                            onChanged: (x) => setState(() => _cible = Duration(milliseconds: x.round())),
                            onChangeEnd: (x) {
                              ctrl.seekTo(Duration(milliseconds: x.round())).then((_) => _synchro());
                              setState(() {
                                _cible = null;
                                _glisseBarre = false;
                              });
                              _programmerMasquage();
                            },
                          ),
                        ),
                        // Repères de la boucle A-B
                        if (_a != null) Positioned(left: x(_a!) - 1, child: IgnorePointer(child: Container(width: 3, height: 14, color: Colors.amberAccent))),
                        if (_b != null) Positioned(left: x(_b!) - 1, child: IgnorePointer(child: Container(width: 3, height: 14, color: Colors.amberAccent))),
                        if (_glisseBarre && _cible != null)
                          Positioned(
                            left: (x(_cible!) - 30).clamp(0.0, largeur - 60),
                            top: -34,
                            child: Container(
                              width: 60,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(8)),
                              child: Text(_temps(_cible!), textAlign: TextAlign.center, style: mono(context, taille: 12, couleur: blanc)),
                            ),
                          ),
                      ]);
                    }),
                  ),
                  Row(children: [
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _reste = !_reste),
                      child: Text(
                          _reste
                              ? '−${_temps(v.duration - position)} / ${_temps(v.duration)}'
                              : '${_temps(position)} / ${_temps(v.duration)}',
                          style: mono(context, taille: 12, couleur: blanc)),
                    ),
                    if (!_audio && v.duration > Duration.zero) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text('· fin ${_heureFin(v)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, taille: 11, couleur: Colors.white54)),
                      ),
                    ],
                    const Spacer(),
                    _ib(_b != null ? Icons.repeat_on_rounded : Icons.flag_outlined,
                        _a == null ? 'Boucle A-B : définir A' : _b == null ? 'Définir B' : 'Retirer la boucle',
                        _boucleAB, actif: _a != null, taille: 22),
                    if (widget.liste.length > 1) _ib(Icons.queue_music_rounded, 'File d’attente', _menuFile, taille: 22),
                    _ib(Icons.lock_open_rounded, 'Verrouiller', () {
                      HapticFeedback.mediumImpact();
                      setState(() {
                        _verrou = true;
                        _controles = false;
                      });
                      _indiquer('Écran verrouillé', Icons.lock_rounded);
                    }, taille: 22),
                    if (!_audio) ...[
                      _ib(_format == 1 ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded, 'Format : ${_formats[_format]}', () => _changerFormat((_format + 1) % _formats.length), taille: 22),
                      _ib(Icons.screen_rotation_rounded, 'Pivoter', _pivoter, taille: 22),
                    ],
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
