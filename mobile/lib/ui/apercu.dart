/// Aperçu d'une vidéo avant téléchargement : lecture en streaming du flux direct
/// (format vidéo+audio ≤ 720p ou HLS) trouvé par yt-dlp lors de l'analyse.
library;

import 'dart:async';

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
    // Les liens directs expirent : en cas d'échec on réessaie avec des infos fraîches
    for (final frais in [false, true]) {
      try {
        final info = frais ? await analyse.infoComplete(widget.v.url, frais: true) : widget.v.info;
        final src = analyse.sourceApercu(info);
        if (src == null) throw 'Aucun flux lisible directement pour cette vidéo.';
        final ctrl = VideoPlayerController.networkUrl(Uri.parse(src.url),
            httpHeaders: src.entetes, formatHint: src.hls ? VideoFormat.hls : null);
        await ctrl.initialize();
        if (!mounted) {
          ctrl.dispose();
          return;
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
        return;
      } catch (e) {
        if (frais || e is String) {
          if (mounted) {
            setState(() {
              _charge = false;
              _erreur = e is String ? e : 'Lecture impossible (${'$e'.split('\n').first}).';
            });
          }
          return;
        }
      }
    }
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
    if (paysage) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, _, _) => _PleinEcran(c),
      transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
    ));
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
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(color: Colors.black.withAlpha(150), shape: BoxShape.circle),
                child: _charge
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
              ),
            if (!v.direct && !_charge && _erreur == null)
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black.withAlpha(170), borderRadius: BorderRadius.circular(8)),
                  child: const Text('Aperçu', style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
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
          child: _Lecteur(ctrl,
              controles: _controles,
              onToucher: _toucher,
              onLecturePause: _lecturePause,
              icone: Icons.fullscreen_rounded,
              onEcran: _pleinEcran),
        ),
      ),
    );
  }
}

class _PleinEcran extends StatefulWidget {
  final VideoPlayerController ctrl;
  const _PleinEcran(this.ctrl);
  @override
  State<_PleinEcran> createState() => _PleinEcranState();
}

class _PleinEcranState extends State<_PleinEcran> {
  bool _controles = true;
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

  @override
  Widget build(BuildContext context) {
    final c = widget.ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _Lecteur(c,
          controles: _controles,
          onToucher: () {
            setState(() => _controles = !_controles);
            if (_controles) _programmer();
          },
          onLecturePause: () {
            c.value.isPlaying ? c.pause() : c.play();
            _programmer();
          },
          icone: Icons.fullscreen_exit_rounded,
          onEcran: () => Navigator.of(context).pop()),
    );
  }
}

class _Lecteur extends StatelessWidget {
  final VideoPlayerController ctrl;
  final bool controles;
  final VoidCallback onToucher, onLecturePause, onEcran;
  final IconData icone;
  const _Lecteur(this.ctrl,
      {required this.controles,
      required this.onToucher,
      required this.onLecturePause,
      required this.icone,
      required this.onEcran});

  String _temps(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final val = ctrl.value;
    final fin = val.duration > Duration.zero && val.position >= val.duration;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToucher,
      child: Stack(fit: StackFit.expand, children: [
        Center(child: AspectRatio(aspectRatio: val.aspectRatio, child: VideoPlayer(ctrl))),
        if (val.isBuffering && val.isPlaying)
          const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
        AnimatedOpacity(
          opacity: controles || !val.isPlaying ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !(controles || !val.isPlaying),
            child: Container(
              color: Colors.black.withAlpha(90),
              child: Stack(children: [
                Center(
                  child: IconButton(
                    iconSize: 54,
                    color: Colors.white,
                    onPressed: fin
                        ? () => ctrl.seekTo(Duration.zero).then((_) => ctrl.play())
                        : onLecturePause,
                    icon: Icon(fin
                        ? Icons.replay_rounded
                        : val.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 4, 2),
                      child: Row(children: [
                        Text('${_temps(val.position)} / ${_temps(val.duration)}',
                            style: mono(context, taille: 11, couleur: Colors.white)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: VideoProgressIndicator(ctrl,
                              allowScrubbing: true,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              colors: VideoProgressColors(
                                  playedColor: context.c.indigo,
                                  bufferedColor: Colors.white38,
                                  backgroundColor: Colors.white12)),
                        ),
                        IconButton(
                          color: Colors.white,
                          onPressed: () => ctrl.setVolume(val.volume > 0 ? 0 : 1),
                          icon: Icon(val.volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded, size: 20),
                        ),
                        IconButton(color: Colors.white, onPressed: onEcran, icon: Icon(icone)),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
