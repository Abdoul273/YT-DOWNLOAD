/// Aperçu d'une vidéo avant téléchargement : lecture en streaming du flux direct
/// (manifeste HLS adaptatif ou format vidéo+audio) trouvé par yt-dlp lors de l'analyse.
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../moteur/analyse.dart' as analyse;
import '../moteur/gouts.dart';
import '../moteur/natif.dart';
import '../moteur/taches.dart' show formaterDuree;
import 'etat.dart';
import 'theme.dart';

class Apercu extends StatefulWidget {
  final analyse.ResumeVideo v;
  /// Lance la lecture dès l'affichage.
  final bool auto;
  /// Onglet qui affiche l'aperçu : la lecture se met en pause quand on le quitte.
  final int ongletParent;
  const Apercu(this.v, {super.key, this.auto = false, this.ongletParent = 0});
  @override
  State<Apercu> createState() => _ApercuState();
}

class _ApercuState extends State<Apercu> {
  VideoPlayerController? _ctrl;
  bool _charge = false, _controles = true;
  String? _erreur;
  Timer? _masquer;

  @override
  void initState() {
    super.initState();
    onglet.addListener(_ongletChange);
    if (widget.auto && !widget.v.direct) WidgetsBinding.instance.addPostFrameCallback((_) => _lancer());
  }

  @override
  void dispose() {
    onglet.removeListener(_ongletChange);
    _masquer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  void _ongletChange() {
    if (onglet.value != widget.ongletParent) _ctrl?.pause();
  }

  Future<void> _lancer() async {
    setState(() {
      _charge = true;
      _erreur = null;
    });
    // Les liens directs expirent : en cas d'échec on réessaie avec des infos fraîches,
    // puis avec d'autres clients YouTube.
    final url = widget.v.url;
    final etapes = <Future<Map<String, dynamic>> Function()>[
      () async => widget.v.info,
      () => analyse.infoComplete(url, frais: true),
      () => analyse.infoApercuSecours(url),
    ];
    Object? derniere;
    var aucunFlux = true;
    for (final etape in etapes) {
      try {
        final sources = analyse.sourcesApercu(await etape());
        if (sources.isNotEmpty) aucunFlux = false;
        for (final src in sources) {
          if (!mounted) return;
          if (await _essayer(src)) return;
        }
      } catch (e) {
        derniere = e;
      }
    }
    if (mounted) {
      setState(() {
        _charge = false;
        _erreur = aucunFlux && derniere == null
            ? 'Aucun flux lisible directement pour cette vidéo.'
            : 'Lecture impossible${derniere == null ? '' : ' (${'$derniere'.split('\n').first})'}.';
      });
    }
  }

  /// Ouvre [src] dans le lecteur ; false si le flux ne se lance pas.
  Future<bool> _essayer(analyse.SourceApercu src) async {
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(src.url),
        httpHeaders: src.entetes, formatHint: src.hls ? VideoFormat.hls : null);
    try {
      await ctrl.initialize().timeout(const Duration(seconds: 20));
    } catch (_) {
      ctrl.dispose();
      return false;
    }
    if (!mounted) {
      ctrl.dispose();
      return true;
    }
    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() {
      _ctrl = ctrl;
      _charge = false;
    });
    await ctrl.play();
    _programmerMasquage();
    final v = widget.v;
    gouts.signal('apercu', url: v.url, titre: v.titre, chaine: v.chaine, chaineId: v.info['channel_id'] as String?);
    return true;
  }

  void _programmerMasquage() {
    _masquer?.cancel();
    _masquer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_ctrl?.value.isPlaying ?? false)) setState(() => _controles = false);
    });
  }

  void _toucher() {
    setState(() => _controles = !_controles);
    if (_controles) _programmerMasquage();
  }

  void _lecturePause() {
    final c = _ctrl!;
    c.value.isPlaying ? c.pause() : c.play();
    _programmerMasquage();
  }

  Future<void> _pleinEcran() async {
    final c = _ctrl!;
    final paysage = c.value.aspectRatio >= 1;
    await Natif.orientationLecteur(paysage ? 2 : 0);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, _, _) => _PleinEcran(c, titre: widget.v.titre, chaine: widget.v.chaine, paysageInitial: paysage),
      transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
    ));
    await Natif.orientationLecteur(0);
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = widget.v;
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: _charge || v.direct ? null : _lancer,
          child: Stack(alignment: Alignment.center, children: [
            Miniature(v.miniature, largeur: double.infinity, rayon: 16, texteDuree: formaterDuree(v.duree)),
            if (!v.direct)
              ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [c.indigo.withAlpha(220), c.violet.withAlpha(200)],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withAlpha(65)),
                      boxShadow: [BoxShadow(color: c.indigo.withAlpha(90), blurRadius: 20)],
                    ),
                    child: _charge
                        ? const Padding(
                            padding: EdgeInsets.all(19),
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
                  ),
                ),
              ),
            if (!v.direct && !_charge && _erreur == null)
              Positioned(
                left: 10,
                top: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xAA0C1022),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white.withAlpha(28)),
                      ),
                      child: const Text('Aperçu streaming',
                          style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        if (_erreur != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.error_outline_rounded, size: 18, color: c.rouge),
              const SizedBox(width: 8),
              Expanded(child: Text(_erreur!, style: TextStyle(color: c.t2, fontSize: 12.5))),
              TextButton(onPressed: () => Natif.ouvrirLien(v.url), child: const Text('Ouvrir sur YouTube')),
            ]),
          ),
      ]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: _Lecteur(
            ctrl,
            controles: _controles,
            onToucher: _toucher,
            onLecturePause: _lecturePause,
            icone: Icons.fullscreen_rounded,
            onEcran: _pleinEcran,
            onInteraction: _programmerMasquage,
          ),
        ),
      ),
    );
  }
}

class _PleinEcran extends StatefulWidget {
  final VideoPlayerController ctrl;
  final String titre;
  final String? chaine;
  final bool paysageInitial;
  const _PleinEcran(this.ctrl, {required this.titre, this.chaine, required this.paysageInitial});
  @override
  State<_PleinEcran> createState() => _PleinEcranState();
}

class _PleinEcranState extends State<_PleinEcran> {
  bool _controles = true;
  bool _remplir = false;
  late bool _paysage = widget.paysageInitial;
  Timer? _masquer;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_maj);
    _programmer();
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_maj);
    _masquer?.cancel();
    Natif.luminosite(-1);
    super.dispose();
  }

  void _maj() {
    if (mounted) setState(() {});
  }

  void _programmer() {
    _masquer?.cancel();
    _masquer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.ctrl.value.isPlaying) setState(() => _controles = false);
    });
  }

  void _basculerRotation() {
    setState(() => _paysage = !_paysage);
    Natif.orientationLecteur(_paysage ? 2 : 1);
    _programmer();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _Lecteur(
        c,
        pleinEcran: true,
        titre: widget.titre,
        chaine: widget.chaine,
        remplir: _remplir,
        onBasculerRemplir: () {
          setState(() => _remplir = !_remplir);
          _programmer();
        },
        onPivoter: _basculerRotation,
        controles: _controles,
        onInteraction: _programmer,
        onToucher: () {
          setState(() => _controles = !_controles);
          if (_controles) _programmer();
        },
        onLecturePause: () {
          c.value.isPlaying ? c.pause() : c.play();
          _programmer();
        },
        icone: Icons.fullscreen_exit_rounded,
        onEcran: () => Navigator.of(context).pop(),
      ),
    );
  }
}

class _Lecteur extends StatefulWidget {
  final VideoPlayerController ctrl;
  final bool controles;
  final bool pleinEcran;
  final bool remplir;
  final String? titre;
  final String? chaine;
  final VoidCallback onToucher, onLecturePause, onEcran, onInteraction;
  final VoidCallback? onBasculerRemplir, onPivoter;
  final IconData icone;

  const _Lecteur(
    this.ctrl, {
    required this.controles,
    required this.onToucher,
    required this.onLecturePause,
    required this.icone,
    required this.onEcran,
    required this.onInteraction,
    this.pleinEcran = false,
    this.remplir = false,
    this.titre,
    this.chaine,
    this.onBasculerRemplir,
    this.onPivoter,
  });

  @override
  State<_Lecteur> createState() => _LecteurState();
}

class _LecteurState extends State<_Lecteur> {
  static const _vitesses = [1.0, 1.25, 1.5, 2.0];
  int _onde = 0;
  int _cumul = 0;
  Timer? _finOnde;
  double? _glisseRatio;
  double _luminosite = 0.5;
  double _volume = 1.0;
  String? _barre;
  Timer? _finBarre;
  String? _bulle;
  Timer? _finBulle;
  double _debutX = 0;
  Duration _debutPos = Duration.zero;
  Duration? _cible;
  double? _vitesseAvant;

  @override
  void initState() {
    super.initState();
    _volume = widget.ctrl.value.volume;
    if (widget.pleinEcran) {
      Natif.luminosite().then((v) {
        if (mounted) _luminosite = v.clamp(0.0, 1.0);
      });
    }
  }

  @override
  void dispose() {
    _finOnde?.cancel();
    _finBarre?.cancel();
    _finBulle?.cancel();
    super.dispose();
  }

  String _temps(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  void _sauter(int sens) {
    final c = widget.ctrl;
    final dur = c.value.duration;
    _cumul = (_cumul.sign == sens ? _cumul : 0) + 10 * sens;
    var cible = c.value.position + Duration(seconds: 10 * sens);
    if (cible < Duration.zero) cible = Duration.zero;
    if (cible > dur) cible = dur;
    c.seekTo(cible);
    HapticFeedback.selectionClick();
    _finOnde?.cancel();
    setState(() => _onde = sens);
    _finOnde = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() {
          _onde = 0;
          _cumul = 0;
        });
      }
    });
    widget.onInteraction();
  }

  void _cyclerVitesse() {
    final v = widget.ctrl.value.playbackSpeed;
    final idx = _vitesses.indexWhere((e) => (e - v).abs() < 0.05);
    final suiv = _vitesses[(idx + 1) % _vitesses.length];
    widget.ctrl.setPlaybackSpeed(suiv);
    setState(() {});
    widget.onInteraction();
  }

  void _montrerBulle(String s) {
    _finBulle?.cancel();
    setState(() => _bulle = s);
    _finBulle = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _bulle = null);
    });
  }

  void _montrerBarre(String type) {
    _finBarre?.cancel();
    setState(() => _barre = type);
    _finBarre = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _barre = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ctrl = widget.ctrl;
    final val = ctrl.value;
    final dureeMs = val.duration.inMilliseconds.clamp(1, 1 << 31);
    final brut = (_cible ?? val.position).inMilliseconds / dureeMs;
    final avancement = (_glisseRatio ?? brut).clamp(0.0, 1.0);
    final posAffichee = Duration(milliseconds: (avancement * dureeMs).round());
    final fin = val.duration > Duration.zero && posAffichee >= val.duration;
    final vitesse = val.playbackSpeed;
    final vLib = vitesse == 1.0 ? '1×' : '${'$vitesse'.replaceAll('.0', '').replaceAll('.', ',')}×';
    final visible = widget.controles || !val.isPlaying;

    return LayoutBuilder(builder: (ctx, box) {
      final taille = box.biggest;
      return Stack(fit: StackFit.expand, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToucher,
          onDoubleTapDown: (d) {
            final x = d.localPosition.dx / taille.width;
            if (x < 0.36) {
              _sauter(-1);
            } else if (x > 0.64) {
              _sauter(1);
            } else {
              widget.onLecturePause();
            }
          },
          onDoubleTap: () {},
          onLongPressStart: (_) {
            _vitesseAvant = ctrl.value.playbackSpeed;
            ctrl.setPlaybackSpeed(2.0);
            HapticFeedback.mediumImpact();
            setState(() => _bulle = '2× ▶▶');
          },
          onLongPressEnd: (_) {
            ctrl.setPlaybackSpeed(_vitesseAvant ?? 1.0);
            setState(() => _bulle = null);
          },
          onHorizontalDragStart: !widget.pleinEcran
              ? null
              : (d) {
                  _debutX = d.localPosition.dx;
                  _debutPos = val.position;
                },
          onHorizontalDragUpdate: !widget.pleinEcran
              ? null
              : (d) {
                  final portee = val.duration.inSeconds < 90 ? val.duration.inMilliseconds : 90000;
                  final delta = (d.localPosition.dx - _debutX) / taille.width * portee;
                  var cible = _debutPos + Duration(milliseconds: delta.round());
                  if (cible < Duration.zero) cible = Duration.zero;
                  if (cible > val.duration) cible = val.duration;
                  final ecart = cible - _debutPos;
                  setState(() {
                    _cible = cible;
                    _bulle = '${_temps(cible)} (${ecart.isNegative ? '−' : '+'}${_temps(ecart.abs())})';
                  });
                },
          onHorizontalDragEnd: !widget.pleinEcran
              ? null
              : (_) {
                  final cible = _cible;
                  setState(() {
                    _cible = null;
                    _bulle = null;
                  });
                  if (cible != null) ctrl.seekTo(cible);
                },
          onVerticalDragUpdate: !widget.pleinEcran
              ? null
              : (d) {
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
          child: widget.remplir
              ? ClipRect(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: val.size.width > 0 ? val.size.width : 16,
                      height: val.size.height > 0 ? val.size.height : 9,
                      child: RepaintBoundary(child: VideoPlayer(ctrl)),
                    ),
                  ),
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: val.aspectRatio,
                    child: RepaintBoundary(child: VideoPlayer(ctrl)),
                  ),
                ),
        ),
        if (val.isBuffering && val.isPlaying)
          const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
        if (_onde != 0)
          Positioned(
            top: 0,
            bottom: 0,
            left: _onde < 0 ? 0 : null,
            right: _onde < 0 ? null : 0,
            width: taille.width * 0.36,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(38),
                  borderRadius: BorderRadius.horizontal(
                    left: _onde < 0 ? Radius.zero : const Radius.circular(300),
                    right: _onde < 0 ? const Radius.circular(300) : Radius.zero,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${_cumul.abs()} s',
                  style: mono(context, taille: 14, couleur: Colors.white, poids: FontWeight.w800),
                ),
              ),
            ),
          ),
        if (_barre != null && widget.pleinEcran)
          Positioned(
            top: 0,
            bottom: 0,
            left: _barre == 'lum' ? 22 : null,
            right: _barre == 'lum' ? null : 22,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    width: 44,
                    height: 165,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xBB0D1123),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withAlpha(28)),
                    ),
                    child: Column(children: [
                      Text('${((_barre == 'lum' ? _luminosite : _volume) * 100).round()}',
                          style: mono(context, taille: 11, couleur: Colors.white, poids: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            width: 6,
                            child: Stack(alignment: Alignment.bottomCenter, children: [
                              Container(color: Colors.white24),
                              FractionallySizedBox(
                                heightFactor: (_barre == 'lum' ? _luminosite : _volume).clamp(0.0, 1.0),
                                child: Container(color: _barre == 'lum' ? c.ambre : c.cyan),
                              ),
                            ]),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Icon(
                        _barre == 'lum'
                            ? Icons.brightness_6_rounded
                            : _volume == 0
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        if (_bulle != null)
          Center(
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xC80D1123),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withAlpha(28)),
                ),
                child: Text(_bulle!, style: mono(context, taille: 13.5, couleur: Colors.white, poids: FontWeight.w700)),
              ),
            ),
          ),
        AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 190),
          child: IgnorePointer(
            ignoring: !visible,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xA6060812), Color(0x16000000), Color(0xD2060812)],
                  stops: [0, 0.45, 1],
                ),
              ),
              child: SafeArea(
                top: widget.pleinEcran,
                bottom: widget.pleinEcran,
                child: Stack(children: [
                  // Barre haute (titre en plein écran + vitesse)
                  Positioned(
                    left: 8,
                    right: 8,
                    top: widget.pleinEcran ? 4 : 6,
                    child: Row(children: [
                      if (widget.pleinEcran) ...[
                        IconButton(
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_back_rounded),
                          onPressed: widget.onEcran,
                        ),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            if (widget.titre != null)
                              Text(widget.titre!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5)),
                            if (widget.chaine != null)
                              Text(widget.chaine!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                          ]),
                        ),
                        if (widget.onBasculerRemplir != null)
                          IconButton(
                            tooltip: widget.remplir ? 'Ajuster' : 'Remplir',
                            color: Colors.white,
                            icon: Icon(widget.remplir ? Icons.fit_screen_rounded : Icons.aspect_ratio_rounded, size: 22),
                            onPressed: () {
                              widget.onBasculerRemplir!();
                              _montrerBulle(!widget.remplir ? 'Remplir' : 'Ajuster');
                            },
                          ),
                        if (widget.onPivoter != null)
                          IconButton(
                            tooltip: 'Pivoter',
                            color: Colors.white,
                            icon: const Icon(Icons.screen_rotation_rounded, size: 21),
                            onPressed: widget.onPivoter,
                          ),
                      ] else
                        const Spacer(),
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _cyclerVitesse,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0x9E0D1123),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withAlpha(28)),
                          ),
                          child: Text(vLib,
                              style: mono(context,
                                  taille: 12, couleur: vitesse == 1.0 ? Colors.white : c.cyan, poids: FontWeight.w800)),
                        ),
                      ),
                    ]),
                  ),

                  // Commandes centrales (Reculer 10s · Play/Pause · Avancer 10s)
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (widget.pleinEcran || taille.width >= 260) ...[
                        IconButton(
                          color: Colors.white,
                          iconSize: widget.pleinEcran ? 32 : 26,
                          icon: const Icon(Icons.replay_10_rounded),
                          onPressed: () => _sauter(-1),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [c.indigo.withAlpha(225), c.violet.withAlpha(210)]),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withAlpha(65)),
                          boxShadow: [BoxShadow(color: c.indigo.withAlpha(80), blurRadius: 22)],
                        ),
                        child: IconButton(
                          iconSize: widget.pleinEcran ? 48 : 38,
                          color: Colors.white,
                          onPressed: fin
                              ? () => ctrl.seekTo(Duration.zero).then((_) => ctrl.play())
                              : widget.onLecturePause,
                          icon: Icon(fin
                              ? Icons.replay_rounded
                              : val.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded),
                        ),
                      ),
                      if (widget.pleinEcran || taille.width >= 260) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          color: Colors.white,
                          iconSize: widget.pleinEcran ? 32 : 26,
                          icon: const Icon(Icons.forward_10_rounded),
                          onPressed: () => _sauter(1),
                        ),
                      ],
                    ]),
                  ),

                  // Barre basse avec slider fluide
                  Positioned(
                    left: 10,
                    right: 6,
                    bottom: 2,
                    child: Row(children: [
                      Text('${_temps(posAffichee)} / ${_temps(val.duration)}',
                          style: mono(context, taille: 11, couleur: Colors.white, poids: FontWeight.w600)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3.5,
                            activeTrackColor: c.indigo,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayColor: c.indigo.withAlpha(45),
                            thumbShape: RoundSliderThumbShape(enabledThumbRadius: _glisseRatio != null ? 7.5 : 5.5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
                          ),
                          child: Slider(
                            value: avancement,
                            onChangeStart: (x) {
                              setState(() => _glisseRatio = x);
                              widget.onInteraction();
                            },
                            onChanged: (x) => setState(() => _glisseRatio = x),
                            onChangeEnd: (x) {
                              ctrl.seekTo(Duration(milliseconds: (x * dureeMs).round()));
                              setState(() => _glisseRatio = null);
                              widget.onInteraction();
                            },
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        onPressed: () {
                          final nv = val.volume > 0 ? 0.0 : 1.0;
                          _volume = nv;
                          ctrl.setVolume(nv);
                          widget.onInteraction();
                        },
                        icon: Icon(val.volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded, size: 20),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        onPressed: widget.onEcran,
                        icon: Icon(widget.icone, size: 22),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}
