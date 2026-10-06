/// Annonce et installation d'une nouvelle version de l'app.
library;

import 'package:flutter/material.dart';

import '../moteur/maj.dart';
import '../moteur/natif.dart';
import '../moteur/taches.dart' show formaterTaille;
import 'theme.dart';

/// Surveille les nouvelles versions (au lancement et à chaque retour dans l'app) et affiche
/// l'écran de mise à jour obligatoire : on ne peut pas l'ignorer, l'installation démarre toute seule.
class VeilleMaj extends StatefulWidget {
  final Widget child;
  const VeilleMaj({super.key, required this.child});
  @override
  State<VeilleMaj> createState() => _VeilleMajState();
}

class _VeilleMajState extends State<VeilleMaj> with WidgetsBindingObserver {
  bool _ouvert = false, _ignore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    maj.addListener(_ecouter);
    _controler();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    maj.removeListener(_ecouter);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (etat == AppLifecycleState.resumed) _controler();
  }

  Future<void> _controler() async {
    await maj.verifier();
    _ecouter();
  }

  void _ecouter() {
    if (!mounted || _ouvert || _ignore || maj.dispo == null) return;
    _ouvert = true;
    Navigator.of(context)
        .push<String>(PageRouteBuilder(
          opaque: true,
          pageBuilder: (_, _, _) => const _EcranMajObligatoire(),
          transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
        ))
        .then((r) {
      _ouvert = false;
      if (r == 'ignorer') _ignore = true;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _EcranMajObligatoire extends StatefulWidget {
  const _EcranMajObligatoire();
  @override
  State<_EcranMajObligatoire> createState() => _EcranMajObligatoireState();
}

class _EcranMajObligatoireState extends State<_EcranMajObligatoire> {
  @override
  void initState() {
    super.initState();
    maj.addListener(_ecouter);
    // Téléchargement puis installation lancés tout de suite, sans rien demander
    if (maj.dispo != null && maj.erreur == null) maj.installer();
  }

  @override
  void dispose() {
    maj.removeListener(_ecouter);
    super.dispose();
  }

  void _ecouter() {
    if (maj.dispo == null && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: maj.dispo == null,
        child: Scaffold(
          body: Stack(children: [
            const Positioned.fill(child: Aurore()),
            Align(
              alignment: Alignment.bottomCenter,
              child: SingleChildScrollView(child: const _FenetreMaj(obligatoire: true)),
            ),
          ]),
        ),
      );
}

/// Pastille « Mise à jour » de l'en-tête (état de la mise à jour en cours).
class BoutonMaj extends StatelessWidget {
  const BoutonMaj({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: maj,
      builder: (context, _) {
        if (maj.dispo == null) return const SizedBox();
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => ouvrirFenetreMaj(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.system_update_rounded, size: 14, color: Colors.white),
                const SizedBox(width: 4),
                Text(maj.progression != null ? '${(maj.progression! * 100).round()} %' : 'Mise à jour',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

void ouvrirFenetreMaj(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.c.fond,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _FenetreMaj(),
    );

class _FenetreMaj extends StatelessWidget {
  final bool obligatoire;
  const _FenetreMaj({this.obligatoire = false});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: maj,
      builder: (context, _) {
        final v = maj.dispo;
        final p = maj.progression;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + MediaQuery.paddingOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                  width: 40, height: 4, decoration: BoxDecoration(color: c.t3, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.system_update_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v == null ? 'Application à jour' : 'Nouvelle version ${v.version}',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: c.t1)),
                  Text(
                      'Version installée : ${Natif.versionApp}'
                      '${v != null && v.taille > 0 ? ' · ${formaterTaille(v.taille)}' : ''}',
                      style: TextStyle(color: c.t2, fontSize: 12.5)),
                ]),
              ),
            ]),
            if (v != null && v.notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: Text(v.notes, style: TextStyle(color: c.t1, height: 1.45))),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              obligatoire
                  ? 'Cette mise à jour est nécessaire pour continuer. Tes vidéos et réglages sont conservés. '
                      'Android peut demander de confirmer l’installation (la première fois, autorise YT-NEXUS '
                      'à installer des applications puis reviens ici) ; les suivantes se font toutes seules.'
                  : 'Tes vidéos et réglages sont conservés. Android te demandera de confirmer l’installation'
                      ' (la première fois, autorise YT-NEXUS à installer des applications puis reviens ici).',
              style: TextStyle(color: c.t3, fontSize: 12),
            ),
            if (maj.erreur != null) ...[
              const SizedBox(height: 10),
              Text(maj.erreur!, style: TextStyle(color: c.rouge, fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            if (p != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: p, minHeight: 8, color: c.indigo, backgroundColor: c.verre3),
              ),
              const SizedBox(height: 8),
              Text(p >= 1 ? 'Ouverture de l’installateur…' : 'Téléchargement… ${(p * 100).round()} %',
                  textAlign: TextAlign.center, style: mono(context, taille: 12, couleur: c.t2)),
            ] else if (v != null)
              BoutonGrad(obligatoire ? 'Installer maintenant' : 'Mettre à jour',
                  icone: Icons.download_rounded, onTap: maj.installer)
            else
              BoutonGrad('Rechercher une mise à jour',
                  icone: Icons.refresh_rounded, charge: maj.verification, onTap: () => maj.verifier(force: true)),
            if (p == null && v != null && !obligatoire)
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Plus tard', style: TextStyle(color: c.t2))),
            // Échappatoire seulement si l'installation échoue (réseau, signature…) : on ne bloque pas l'app pour toujours
            if (p == null && v != null && obligatoire && maj.erreur != null)
              TextButton(
                  onPressed: () => Navigator.of(context).pop('ignorer'),
                  child: Text('Continuer sans mettre à jour', style: TextStyle(color: c.t2))),
          ]),
        );
      },
    );
  }
}
