/// Lecteur intégré pour les vidéos et musiques téléchargées.
///
/// Gestes : double appui à gauche/droite = ±10 s, glisser horizontalement = avancer,
/// glisser verticalement à gauche = luminosité, à droite = volume, appui long = vitesse ×2. Pistes audio (doublage/VO), sous-titres .srt, vitesse,
/// répétition, verrouillage, enchaînement et reprise là où on s'était arrêté.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

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

class Lecteur extends StatefulWidget {
  final List<Tache> liste;
  final int index;
  const Lecteur(this.liste, this.index, {super.key});
  @override
  State<Lecteur> createState() => _LecteurState();
}

class _LecteurState extends State<Lecteur> {
  VideoPlayerController? _ctrl;
  late int _index = widget.index;
  String? _erreur;
  bool _controles = true, _verrou = false, _remplir = false, _boucle = false, _sousTitresActifs = true;
  bool _aSousTitres = false, _signale = false;
  double _vitesse = 1;
  List<VideoAudioTrack> _pistes = [];
  Timer? _masquer;

  // Gestes
  String? _indication; // texte affiché au centre (±10 s, 2×, volume…)
  IconData? _iconeIndication;
  Timer? _finIndication;
  int _cumulSaut = 0;
  Timer? _finSaut;
  Duration? _cible; // pendant un glissement horizontal
  double _debutGlisse = 0;
  Duration _positionDebut = Duration.zero;
  double _luminosite = 0.5, _volume = 1;
  double? _vitesseAvantAppuiLong;

  Tache get _tache => widget.liste[_index];
  bool get _audio => _tache.fichierPrincipal?.mime.startsWith('audio') ?? false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Natif.luminosite().then((v) => _luminosite = v);
    _charger();
  }

  @override
  void dispose() {
    _memoriserPosition();
    _masquer?.cancel();
    _finIndication?.cancel();
    _finSaut?.cancel();
    _ctrl?.dispose();
    Natif.luminosite(-1);
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── chargement ──────────────────────────────────────────────────────
  Future<void> _charger() async {
    _memoriserPosition();
    final ancien = _ctrl;
    ancien?.removeListener(_maj);
    setState(() {
      _ctrl = null;
      _erreur = null;
      _pistes = [];
      _aSousTitres = false;
      _signale = false;
    });
    await ancien?.dispose();
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
      if (mounted) setState(() => _erreur = 'Lecture impossible : fichier déplacé, supprimé ou format non pris en charge.');
      return;
    }
    if (!mounted) {
      ctrl.dispose();
      return;
    }
    ctrl.addListener(_maj);
    await ctrl.setLooping(_boucle);
    await ctrl.setPlaybackSpeed(_vitesse);
    await ctrl.setVolume(_volume);
    final pos = ((reglages['positions'] as Map?) ?? {})[_tache.id];
    if (pos is int && pos > 10000 && pos < ctrl.value.duration.inMilliseconds * 0.95) {
      await ctrl.seekTo(Duration(milliseconds: pos));
      _indiquer('Reprise à ${_temps(Duration(milliseconds: pos))}', Icons.history_rounded);
    }
    setState(() => _ctrl = ctrl);
    _orienter();
    await ctrl.play();
    _programmerMasquage();
    try {
      final p = await ctrl.getAudioTracks();
      if (mounted) setState(() => _pistes = p);
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

  void _maj() {
    final c = _ctrl;
    if (!mounted || c == null) return;
    final v = c.value;
    if (!_signale && v.duration > Duration.zero &&
        (v.position.inSeconds > 60 || v.position.inMilliseconds > v.duration.inMilliseconds * 0.3)) {
      _signale = true;
      gouts.signal('lecture', url: _tache.url, titre: _tache.titre, chaine: _tache.chaine);
    }
    // Fin : morceau suivant
    if (!_boucle && v.isInitialized && v.duration > Duration.zero && v.position >= v.duration && !v.isPlaying) {
      if (_index < widget.liste.length - 1) {
        _effacerPosition();
        _aller(_index + 1);
        return;
      }
    }
    setState(() {});
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
    _ctrl?.removeListener(_maj);
    _ctrl?.pause();
    setState(() => _index = i);
    _charger();
  }

  // ── contrôles ───────────────────────────────────────────────────────
  void _programmerMasquage() {
    _masquer?.cancel();
    _masquer = Timer(const Duration(milliseconds: 3200), () {
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
    _finIndication = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _indication = null);
    });
  }

  void _sauter(int sens) {
    final c = _ctrl;
    if (c == null) return;
    _cumulSaut = (_cumulSaut.sign == sens ? _cumulSaut : 0) + 10 * sens;
    final d = c.value.duration;
    var cible = c.value.position + Duration(seconds: 10 * sens);
    if (cible < Duration.zero) cible = Duration.zero;
    if (cible > d) cible = d;
    c.seekTo(cible);
    _indiquer('${_cumulSaut > 0 ? '+' : ''}$_cumulSaut s', sens > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
    _finSaut?.cancel();
    _finSaut = Timer(const Duration(milliseconds: 900), () => _cumulSaut = 0);
  }

  Future<void> _choisir<T>(String titre, List<(T, String, bool)> options, void Function(T) choix) async {
    final c = context.c;
    final r = await showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(titre, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.t1)),
            ),
            for (final (v, l, actif) in options)
              ListTile(
                title: Text(l, style: TextStyle(color: c.t1, fontWeight: actif ? FontWeight.w700 : FontWeight.w400)),
                trailing: actif ? Icon(Icons.check_rounded, color: c.indigo) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ]),
        ),
      ),
    );
    if (r != null) choix(r);
  }

  void _menuVitesse() => _choisir<double>('Vitesse de lecture', [
        for (final v in const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
          (v, v == 1 ? 'Normale' : '${'$v'.replaceAll('.', ',')}×', v == _vitesse),
      ], (v) {
        setState(() => _vitesse = v);
        _ctrl?.setPlaybackSpeed(v);
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

  // ── interface ───────────────────────────────────────────────────────
  String _temps(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final taille = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !_verrou,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _erreur != null
            ? _vueErreur()
            : ctrl == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white))
                : GestureDetector(
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
                    onHorizontalDragStart: _verrou
                        ? null
                        : (d) {
                            _debutGlisse = d.localPosition.dx;
                            _positionDebut = ctrl.value.position;
                          },
                    onHorizontalDragUpdate: _verrou
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
                            if (_cible != null) ctrl.seekTo(_cible!);
                            setState(() {
                              _cible = null;
                              _indication = null;
                            });
                          },
                    onVerticalDragUpdate: _verrou
                        ? null
                        : (d) {
                            final pas = -d.delta.dy / (taille.height * 0.7);
                            if (d.localPosition.dx < taille.width / 2) {
                              _luminosite = (_luminosite + pas).clamp(0.01, 1.0);
                              Natif.luminosite(_luminosite);
                              _indiquer('${(_luminosite * 100).round()} %', Icons.brightness_6_rounded);
                            } else {
                              _volume = (_volume + pas).clamp(0.0, 1.0);
                              ctrl.setVolume(_volume);
                              _indiquer('${(_volume * 100).round()} %',
                                  _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded);
                            }
                          },
                    child: Stack(fit: StackFit.expand, children: [
                      _image(ctrl),
                      if (_sousTitresActifs && _aSousTitres)
                        Positioned(
                          left: 24,
                          right: 24,
                          bottom: _controles ? 96 : 28,
                          child: ClosedCaption(
                            text: ctrl.value.caption.text,
                            textStyle: const TextStyle(fontSize: 17, color: Colors.white, height: 1.3),
                          ),
                        ),
                      if (ctrl.value.isBuffering && ctrl.value.isPlaying)
                        const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
                      if (_indication != null) Center(child: _bulle()),
                      _surcouche(ctrl),
                    ]),
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
      // Musique : pochette sur fond flouté
      final m = _tache.miniature;
      return Stack(fit: StackFit.expand, children: [
        if (m != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Opacity(opacity: 0.5, child: Image.network(m, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox())),
          ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Miniature(m, largeur: 320, rayon: 20),
          ),
        ),
      ]);
    }
    final t = ctrl.value.size;
    return ClipRect(
        child: FittedBox(
          fit: _remplir ? BoxFit.cover : BoxFit.contain,
          child: SizedBox(
            width: t.width > 0 ? t.width : 16,
            height: t.height > 0 ? t.height : 9,
            child: VideoPlayer(ctrl),
          ),
        ),
    );
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

  Widget _surcouche(VideoPlayerController ctrl) {
    final v = ctrl.value;
    final visible = _controles || !v.isPlaying;
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
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xAA000000), Color(0x33000000), Color(0x33000000), Color(0xCC000000)],
              stops: [0, 0.25, 0.7, 1],
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
                  IconButton(color: blanc, icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.of(context).pop()),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_tache.titre,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: blanc, fontWeight: FontWeight.w700, fontSize: 15)),
                      if (_tache.chaine != null)
                        Text(_tache.chaine!, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ]),
                  ),
                  if (_pistes.length > 1)
                    IconButton(color: blanc, tooltip: 'Piste audio', icon: const Icon(Icons.translate_rounded), onPressed: _menuPistes),
                  if (_aSousTitres)
                    IconButton(
                      color: blanc,
                      tooltip: 'Sous-titres',
                      icon: Icon(_sousTitresActifs ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined),
                      onPressed: () => setState(() => _sousTitresActifs = !_sousTitresActifs),
                    ),
                  TextButton(
                    onPressed: _menuVitesse,
                    child: Text('${'$_vitesse'.replaceAll('.0', '').replaceAll('.', ',')}×',
                        style: const TextStyle(color: blanc, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    color: _boucle ? context.c.indigo : blanc,
                    tooltip: 'Répéter',
                    icon: const Icon(Icons.repeat_one_rounded),
                    onPressed: () {
                      setState(() => _boucle = !_boucle);
                      ctrl.setLooping(_boucle);
                      _indiquer(_boucle ? 'Répétition activée' : 'Répétition désactivée', Icons.repeat_one_rounded);
                    },
                  ),
                ]),
              ),
              // Centre
              Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    iconSize: 36,
                    color: _index > 0 ? blanc : Colors.white24,
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: _index > 0 ? () => _aller(_index - 1) : null,
                  ),
                  const SizedBox(width: 24),
                  Container(
                    decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                    child: IconButton(
                      iconSize: 52,
                      color: blanc,
                      icon: Icon(fin
                          ? Icons.replay_rounded
                          : v.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                      onPressed: _lecturePause,
                    ),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    iconSize: 36,
                    color: _index < widget.liste.length - 1 ? blanc : Colors.white24,
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: _index < widget.liste.length - 1 ? () => _aller(_index + 1) : null,
                  ),
                ]),
              ),
              // Barre du bas
              Positioned(
                left: 12,
                right: 12,
                bottom: 4,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: context.c.indigo,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: blanc,
                      secondaryActiveTrackColor: Colors.white38,
                    ),
                    child: Slider(
                      min: 0,
                      max: v.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                      value: position.inMilliseconds.toDouble().clamp(0, v.duration.inMilliseconds.toDouble().clamp(1, double.infinity)),
                      secondaryTrackValue: v.buffered.isEmpty
                          ? null
                          : v.buffered.last.end.inMilliseconds.toDouble().clamp(0, v.duration.inMilliseconds.toDouble().clamp(1, double.infinity)),
                      onChangeStart: (_) => _masquer?.cancel(),
                      onChanged: (x) => setState(() => _cible = Duration(milliseconds: x.round())),
                      onChangeEnd: (x) {
                        ctrl.seekTo(Duration(milliseconds: x.round()));
                        setState(() => _cible = null);
                        _programmerMasquage();
                      },
                    ),
                  ),
                  Row(children: [
                    const SizedBox(width: 12),
                    Text('${_temps(position)} / ${_temps(v.duration)}', style: mono(context, taille: 12, couleur: blanc)),
                    const Spacer(),
                    IconButton(
                      color: blanc,
                      tooltip: 'Verrouiller',
                      icon: const Icon(Icons.lock_open_rounded),
                      onPressed: () {
                        setState(() {
                          _verrou = true;
                          _controles = false;
                        });
                        _indiquer('Écran verrouillé', Icons.lock_rounded);
                      },
                    ),
                    if (!_audio) ...[
                      IconButton(
                        color: blanc,
                        tooltip: _remplir ? 'Image entière' : 'Remplir l’écran',
                        icon: Icon(_remplir ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded),
                        onPressed: () => setState(() => _remplir = !_remplir),
                      ),
                      IconButton(color: blanc, tooltip: 'Pivoter', icon: const Icon(Icons.screen_rotation_rounded), onPressed: _pivoter),
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
