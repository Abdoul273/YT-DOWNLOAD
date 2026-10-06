/// Verrouillage de l'app par code PIN (bibliothèque privée).
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/reglages.dart';
import 'theme.dart';

String _hacher(String sel, String code) {
  var h = 0xcbf29ce484222325;
  for (final u in '$sel:$code'.codeUnits) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h.toRadixString(16);
}

bool get verrouActif => (reglages['pin_hash'] as String).isNotEmpty;

bool verifierCode(String code) => _hacher(reglages['pin_sel'] as String, code) == reglages['pin_hash'];

void definirCode(String? code) {
  if (code == null) {
    reglages['pin_hash'] = '';
    reglages['pin_sel'] = '';
    return;
  }
  final sel = Random.secure().nextInt(1 << 30).toRadixString(16);
  reglages['pin_sel'] = sel;
  reglages['pin_hash'] = _hacher(sel, code);
}

/// Verrouille au lancement, puis après [delai] passé hors de l'app.
class VerrouApp extends StatefulWidget {
  final Widget child;
  const VerrouApp({super.key, required this.child});
  @override
  State<VerrouApp> createState() => _VerrouAppState();
}

class _VerrouAppState extends State<VerrouApp> with WidgetsBindingObserver {
  static const delai = Duration(seconds: 20);
  late bool _verrouille = verrouActif;
  DateTime? _sortie;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (etat == AppLifecycleState.paused) _sortie ??= DateTime.now();
    if (etat == AppLifecycleState.resumed) {
      if (_sortie != null && verrouActif && DateTime.now().difference(_sortie!) > delai) {
        setState(() => _verrouille = true);
      }
      _sortie = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_verrouille) Positioned.fill(child: EcranCode(onOk: () => setState(() => _verrouille = false))),
    ]);
  }
}

class EcranCode extends StatefulWidget {
  final VoidCallback onOk;
  const EcranCode({super.key, required this.onOk});
  @override
  State<EcranCode> createState() => _EcranCodeState();
}

class _EcranCodeState extends State<EcranCode> {
  String _saisie = '';
  bool _faux = false;

  void _touche(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      _faux = false;
      if (k == '<') {
        if (_saisie.isNotEmpty) _saisie = _saisie.substring(0, _saisie.length - 1);
      } else if (_saisie.length < 6) {
        _saisie += k;
      }
    });
    if (_saisie.length >= 4 && verifierCode(_saisie)) {
      widget.onOk();
    } else if (_saisie.length == 6) {
      setState(() {
        _saisie = '';
        _faux = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PopScope(
      canPop: false,
      child: Material(
        color: c.sombre ? const Color(0xFF0A0B14) : const Color(0xFFF4F5FB),
        child: SafeArea(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_rounded, size: 40, color: c.indigo),
            const SizedBox(height: 16),
            Text(_faux ? 'Code incorrect' : 'Entre ton code',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _faux ? c.rouge : c.t1)),
            const SizedBox(height: 18),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < max(4, _saisie.length); i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _saisie.length ? c.indigo : Colors.transparent,
                    border: Border.all(color: c.indigo, width: 1.6),
                  ),
                ),
            ]),
            const SizedBox(height: 28),
            for (final ligne in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['', '0', '<']])
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final k in ligne)
                  SizedBox(
                    width: 84,
                    height: 72,
                    child: k.isEmpty
                        ? const SizedBox()
                        : TextButton(
                            onPressed: () => _touche(k),
                            child: k == '<'
                                ? Icon(Icons.backspace_outlined, color: c.t2)
                                : Text(k, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: c.t1)),
                          ),
                  ),
              ]),
          ]),
        ),
      ),
    );
  }
}

/// Demande un nouveau code (4 à 6 chiffres) ; null si annulé.
Future<String?> demanderNouveauCode(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Nouveau code'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(hintText: '4 à 6 chiffres'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        TextButton(
          onPressed: () => ctrl.text.length >= 4 ? Navigator.pop(ctx, ctrl.text) : null,
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
}
