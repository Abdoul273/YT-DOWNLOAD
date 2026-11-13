/// Aperçu d'une vidéo avant téléchargement : lecture en streaming du flux direct
/// (manifeste HLS adaptatif ou format vidéo+audio) trouvé par yt-dlp lors de l'analyse,
/// avec passage instantané sans coupure vers le lecteur plein écran unifié [Lecteur].
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
import 'lecteur.dart';
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
  analyse.SourceApercu? _source;
  List<analyse.SourceApercu> _qualites = const [];
  Map<String, dynamic>? _infoActif;
  bool _charge = false, _controles = true, _enPleinEcran = false;
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
    final c = _ctrl;
    if (!_enPleinEcran) {
      c?.removeListener(_majCtrl);
      c?.dispose();
    }
    super.dispose();
  }

  void _majCtrl() {
    if (mounted) setState(() {});
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
        final info = await etape();
        final sources = analyse.sourcesApercu(info);
        if (sources.isNotEmpty) aucunFlux = false;
        for (final src in sources) {
          if (!mounted) return;
          if (await _essayer(src, info, sources)) return;
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
  Future<bool> _essayer(
    analyse.SourceApercu src,
    Map<String, dynamic> info,
    List<analyse.SourceApercu> sourcesBase,
  ) async {
    final playUrl = await src.urlExecutable();
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(playUrl),
      httpHeaders: src.entetes,
      formatHint: src.hls ? VideoFormat.hls : null,
    );
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
    ctrl.addListener(_majCtrl);
    setState(() {
      _ctrl = ctrl;
      _source = src;
      _qualites = sourcesBase;
      _infoActif = info;
      _charge = false;
    });
    await ctrl.play();
    _programmerMasquage();
    final v = widget.v;
    gouts.signal('apercu', url: v.url, titre: v.titre, chaine: v.chaine, chaineId: v.info['channel_id'] as String?);
    unawaited(_enrichirQualites(info, ctrl));
    return true;
  }

  Future<void> _enrichirQualites(Map<String, dynamic> info, VideoPlayerController ctrlActif) async {
    final resolues = await analyse.resoudreQualitesStreaming(info);
    if (!mounted || _ctrl != ctrlActif || resolues.isEmpty) return;
    setState(() => _qualites = resolues);
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
    if (_enPleinEcran) return;
    final c = _ctrl;
    final v = widget.v;
    final resume = _infoActif == null ? v : analyse.resumeVideo(_infoActif!);

    if (c == null || !c.value.isInitialized) {
      await ouvrirLecteurStream(context, entrees: const [], resumeInitial: resume);
      await Natif.orientationLecteur(0);
      return;
    }

    c.removeListener(_majCtrl);
    _masquer?.cancel();
    VideoPlayerController? retourCtrl;
    analyse.SourceApercu? retourSrc;
    setState(() {
      _enPleinEcran = true;
      _ctrl = null;
    });

    await ouvrirLecteurStream(
      context,
      entrees: const [],
      resumeInitial: resume,
      controleurInitial: c,
      sourceInitiale: _source,
      qualitesInitiales: _qualites,
      surRetourControleur: (ctrl, src) {
        retourCtrl = ctrl;
        retourSrc = src;
      },
    );
    await Natif.orientationLecteur(0);
    if (!mounted) {
      retourCtrl?.dispose();
      return;
    }
    setState(() {
      _enPleinEcran = false;
      _ctrl = retourCtrl;
      if (retourSrc != null) _source = retourSrc;
    });
    if (retourCtrl != null) {
      retourCtrl!.addListener(_majCtrl);
      _programmerMasquage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = widget.v;
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: _enPleinEcran || _charge || v.direct ? null : _lancer,
          child: Stack(alignment: Alignment.center, children: [
            Miniature(
              v.miniature,
              largeur: double.infinity,
              rayon: 16,
              texteDuree: v.direct ? 'DIRECT' : formaterDuree(v.duree),
            ),
            if (!_enPleinEcran)
              ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: GestureDetector(
                    onTap: v.direct ? _pleinEcran : (_charge ? null : _lancer),
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
              ),
            if (!_charge && _erreur == null && !_enPleinEcran)
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
                      child: Text(v.direct ? 'Flux en direct' : 'Aperçu streaming',
                          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            if (!_charge && !_enPleinEcran)
              Positioned(
                right: 10,
                top: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: _pleinEcran,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xB80C1022),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white.withAlpha(32)),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.fullscreen_rounded, color: Colors.white, size: 15),
                          SizedBox(width: 4),
                          Text('Plein écran', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                        ]),
                      ),
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
          child: _LecteurInline(
            ctrl,
            controles: _controles,
            badgeQualite: _source?.adaptatif == true ? 'Auto' : _source?.libelle,
            onToucher: _toucher,
            onLecturePause: _lecturePause,
            onPleinEcran: _pleinEcran,
            onInteraction: _programmerMasquage,
          ),
        ),
      ),
    );
  }
}

class _LecteurInline extends StatefulWidget {
  final VideoPlayerController ctrl;
  final bool controles;
  final String? badgeQualite;
  final VoidCallback onToucher, onLecturePause, onPleinEcran, onInteraction;

  const _LecteurInline(
    this.ctrl, {
    required this.controles,
    this.badgeQualite,
    required this.onToucher,
    required this.onLecturePause,
    required this.onPleinEcran,
    required this.onInteraction,
  });

  @override
  State<_LecteurInline> createState() => _LecteurInlineState();
}

class _LecteurInlineState extends State<_LecteurInline> {
  static const _vitesses = [1.0, 1.25, 1.5, 2.0];
  int _onde = 0;
  int _cumul = 0;
  Timer? _finOnde;
  double? _glisseRatio;
  String? _bulle;
  Timer? _finBulle;
  double? _vitesseAvant;

  @override
  void dispose() {
    _finOnde?.cancel();
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ctrl = widget.ctrl;
    final val = ctrl.value;
    final dureeMs = val.duration.inMilliseconds.clamp(1, 1 << 31);
    final brut = val.position.inMilliseconds / dureeMs;
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
          child: Center(
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
              child: Stack(children: [
                Positioned(
                  right: 8,
                  top: 6,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (widget.badgeQualite != null) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: widget.onPleinEcran,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0x9E0D1123),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withAlpha(28)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(widget.badgeQualite!,
                                style: mono(context, taille: 11, couleur: c.cyan, poids: FontWeight.w800)),
                            const SizedBox(width: 2),
                            Icon(Icons.hd_rounded, size: 13, color: c.cyan),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
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
                        child: Text(
                          vLib,
                          style: mono(context,
                              taille: 12, couleur: vitesse == 1.0 ? Colors.white : c.cyan, poids: FontWeight.w800),
                        ),
                      ),
                    ),
                  ]),
                ),
                Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (taille.width >= 260) ...[
                      IconButton(
                        color: Colors.white,
                        iconSize: 26,
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
                        iconSize: 38,
                        color: Colors.white,
                        onPressed: fin ? () => ctrl.seekTo(Duration.zero).then((_) => ctrl.play()) : widget.onLecturePause,
                        icon: Icon(fin
                            ? Icons.replay_rounded
                            : val.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded),
                      ),
                    ),
                    if (taille.width >= 260) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        color: Colors.white,
                        iconSize: 26,
                        icon: const Icon(Icons.forward_10_rounded),
                        onPressed: () => _sauter(1),
                      ),
                    ],
                  ]),
                ),
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
                        ctrl.setVolume(val.volume > 0 ? 0.0 : 1.0);
                        widget.onInteraction();
                      },
                      icon: Icon(val.volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded, size: 20),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Ouvrir dans le lecteur complet',
                      color: Colors.white,
                      onPressed: widget.onPleinEcran,
                      icon: const Icon(Icons.fullscreen_rounded, size: 22),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ]);
    });
  }
}
