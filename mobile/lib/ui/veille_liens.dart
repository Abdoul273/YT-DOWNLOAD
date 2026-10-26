/// Presse-papiers intelligent : si un lien YouTube vient d'être copié, propose de l'ouvrir.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/reglages.dart';
import 'etat.dart';
import 'theme.dart';

bool _lienYoutube(String l) {
  final h = Uri.tryParse(l)?.host.toLowerCase() ?? '';
  return h == 'youtu.be' || h == 'youtube.com' || h.endsWith('.youtube.com');
}

class VeilleLiens extends StatefulWidget {
  final Widget child;
  const VeilleLiens({super.key, required this.child});
  @override
  State<VeilleLiens> createState() => _VeilleLiensState();
}

class _VeilleLiensState extends State<VeilleLiens> with WidgetsBindingObserver {
  String? _texteLien;
  int _nbLiens = 0;
  Timer? _minuteur;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controler();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _minuteur?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (etat == AppLifecycleState.resumed) _controler();
  }

  Future<void> _controler() async {
    if (reglages['presse_papiers_auto'] != true) return;
    // Android 10+ ne laisse lire le presse-papiers qu'une fois l'app réellement au premier plan.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final ClipboardData? d;
    try {
      d = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return;
    }
    final texte = d?.text?.trim() ?? '';
    if (texte.isEmpty || texte.length > 2000 || !mounted) return;
    final liens = extraireLiens(texte).where(_lienYoutube).toList();
    if (liens.isEmpty || reglages['dernier_lien_propose'] == texte) return;
    reglages.ecrireSansPrevenir('dernier_lien_propose', texte); // une seule proposition par copie

    setState(() {
      _texteLien = texte;
      _nbLiens = liens.length;
    });

    _minuteur?.cancel();
    _minuteur = Timer(const Duration(seconds: 10), _fermer);
  }

  void _fermer() {
    _minuteur?.cancel();
    if (mounted && _texteLien != null) {
      setState(() => _texteLien = null);
    }
  }

  void _telecharger() {
    final t = _texteLien;
    _fermer();
    if (t != null) {
      HapticFeedback.mediumImpact();
      ouvrirLien(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bas = MediaQuery.paddingOf(context).bottom;
    final clavier = MediaQuery.viewInsetsOf(context).bottom;
    final positionBas = clavier > 0 ? clavier + 12 : bas + 88;

    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 14,
          right: 14,
          bottom: positionBas,
          child: IgnorePointer(
            ignoring: _texteLien == null,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.4),
                  end: Offset.zero,
                ).animate(animation),
                child: FadeTransition(
                  opacity: animation,
                  child: child,
                ),
              ),
              child: _texteLien != null
                  ? Dismissible(
                      key: ValueKey(_texteLien),
                      direction: DismissDirection.down,
                      onDismissed: (_) => _fermer(),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(c.sombre ? 110 : 35),
                              blurRadius: 28,
                              offset: const Offset(0, 10),
                              spreadRadius: -4,
                            ),
                            BoxShadow(
                              color: const Color(0xFF6366F1).withAlpha(c.sombre ? 55 : 35),
                              blurRadius: 24,
                              offset: const Offset(0, 4),
                              spreadRadius: -6,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                              decoration: BoxDecoration(
                                color: c.sombre ? const Color(0xE0101222) : const Color(0xF2FFFFFF),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: c.sombre ? c.indigo.withAlpha(90) : c.indigo.withAlpha(60),
                                  width: 1.2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      gradient: gradBouton,
                                      borderRadius: BorderRadius.circular(13),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Color(0x606366F1),
                                          blurRadius: 10,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(Icons.link_rounded, color: Colors.white, size: 22),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                _nbLiens > 1 ? '$_nbLiens liens détectés' : 'Lien YouTube copié',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  color: c.t1,
                                                  fontSize: 14.5,
                                                  letterSpacing: -0.2,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                              decoration: BoxDecoration(
                                                color: c.vert.withAlpha(35),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: c.vert.withAlpha(90)),
                                              ),
                                              child: Text(
                                                'Prêt',
                                                style: TextStyle(
                                                  color: c.vert,
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _nbLiens > 1
                                              ? 'Appuyez pour tout ajouter'
                                              : (Uri.tryParse(_texteLien!)?.host.isNotEmpty == true
                                                  ? (Uri.tryParse(_texteLien!)?.host ?? 'YouTube')
                                                  : 'Prêt à télécharger'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: mono(context, taille: 11, couleur: c.t3),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: gradBouton,
                                      borderRadius: BorderRadius.circular(13),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Color(0x606366F1),
                                          blurRadius: 14,
                                          offset: Offset(0, 4),
                                          spreadRadius: -2,
                                        ),
                                      ],
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(13),
                                        onTap: _telecharger,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.download_rounded, color: Colors.white, size: 16),
                                              SizedBox(width: 5),
                                              Text(
                                                'Télécharger',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  IconButton(
                                    icon: Icon(Icons.close_rounded, size: 18, color: c.t3),
                                    padding: const EdgeInsets.all(6),
                                    constraints: const BoxConstraints(),
                                    tooltip: 'Fermer',
                                    onPressed: _fermer,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
