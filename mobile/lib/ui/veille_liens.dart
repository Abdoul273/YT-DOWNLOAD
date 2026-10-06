/// Presse-papiers intelligent : si un lien YouTube vient d'être copié, propose de l'ouvrir.
library;

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controler();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final c = context.c;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        content: Row(children: [
          Icon(Icons.link_rounded, color: c.vert, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(liens.length > 1 ? '${liens.length} liens YouTube copiés' : 'Lien YouTube copié',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
        action: SnackBarAction(label: 'Télécharger', onPressed: () => ouvrirLien(texte)),
      ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
