/// Annonce et installation d'une nouvelle version de l'app.
library;

import 'package:flutter/material.dart';

import '../moteur/maj.dart';
import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart' show formaterTaille;
import 'theme.dart';

/// Pastille « Mise à jour » de l'en-tête : vérifie au lancement et propose la nouvelle version une fois.
class BoutonMaj extends StatefulWidget {
  const BoutonMaj({super.key});
  @override
  State<BoutonMaj> createState() => _BoutonMajState();
}

class _BoutonMajState extends State<BoutonMaj> {
  @override
  void initState() {
    super.initState();
    _verifier();
  }

  Future<void> _verifier() async {
    final v = await maj.verifier();
    if (v == null || !mounted || reglages['maj_proposee'] == v.version) return;
    reglages['maj_proposee'] = v.version;
    ouvrirFenetreMaj(context);
  }

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
  const _FenetreMaj();

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
              'Tes vidéos et réglages sont conservés. Android te demandera de confirmer l’installation'
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
              BoutonGrad('Mettre à jour', icone: Icons.download_rounded, onTap: maj.installer)
            else
              BoutonGrad('Rechercher une mise à jour',
                  icone: Icons.refresh_rounded, charge: maj.verification, onTap: () => maj.verifier(force: true)),
            if (p == null && v != null)
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Plus tard', style: TextStyle(color: c.t2))),
          ]),
        );
      },
    );
  }
}
