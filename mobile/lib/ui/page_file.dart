/// Onglet En cours : file de téléchargements en direct.
library;

import 'package:flutter/material.dart';

import '../moteur/natif.dart';
import '../moteur/taches.dart';
import 'etat.dart';
import 'theme.dart';

const _filtres = {
  'tout': 'Tout',
  'actifs': 'Actifs',
  'termines': 'Terminés',
  'echecs': 'Échecs',
};

bool _correspond(String f, Tache t) => switch (f) {
      'actifs' => actifs.contains(t.statut) || t.statut == 'pause',
      'termines' => t.statut == 'termine',
      'echecs' => t.statut == 'erreur' || t.statut == 'annule',
      _ => true,
    };

Future<bool> _confirmerRetrait(BuildContext context, String titre, String message, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: context.c.rouge),
        title: Text(titre),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Garder')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.rouge),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ?? false;

class PageFile extends StatefulWidget {
  const PageFile({super.key});
  @override
  State<PageFile> createState() => _PageFileState();
}

class _PageFileState extends State<PageFile> {
  String _filtre = 'tout';
  Widget? _vue;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vue = null; // thème changé : on reconstruit
  }

  @override
  Widget build(BuildContext context) {
    _vue = null;
    return ListenableBuilder(
      listenable: Listenable.merge([gestionnaire, onglet]),
      // Onglet caché : on garde la dernière vue au lieu de tout reconstruire 4 fois par seconde.
      builder: (context, _) => onglet.value != 2 && _vue != null ? _vue! : _vue = _construire(context),
    );
  }

  Widget _construire(BuildContext context) {
    final c = context.c;
    return Builder(
      builder: (context) {
        final toutes = gestionnaire.taches;
        final liste = toutes.where((t) => _correspond(_filtre, t)).toList();
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Row(children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final e in _filtres.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Puce('${e.value}  ${toutes.where((t) => _correspond(e.key, t)).length}',
                              choisie: _filtre == e.key, onTap: () => setState(() => _filtre = e.key)),
                        ),
                    ]),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, color: c.t2),
                  color: c.sombre ? const Color(0xFF14162A) : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  onSelected: (action) async {
                    if (action.startsWith('vider_')) {
                      final confirme = await _confirmerRetrait(context, 'Nettoyer la liste ?',
                        'Retirer les téléchargements ${action == 'vider_termines' ? 'terminés' : 'en échec ou annulés'} de la liste ? Les fichiers téléchargés seront conservés.', 'Retirer');
                      if (!confirme || !context.mounted) return;
                    }
                    gestionnaire.actionGlobale(action);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'pause_tout', child: Text('Tout mettre en pause')),
                    PopupMenuItem(value: 'reprendre_tout', child: Text('Tout reprendre')),
                    PopupMenuItem(value: 'relancer_erreurs', child: Text('Relancer les échecs')),
                    PopupMenuItem(value: 'vider_termines', child: Text('Retirer les terminés')),
                    PopupMenuItem(value: 'vider_echecs', child: Text('Retirer les échecs')),
                  ],
                ),
              ]),
            ),
          ),
          if (liste.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.inbox_rounded, size: 52, color: c.t3),
                  const SizedBox(height: 10),
                  Text('Rien ici pour l’instant', style: TextStyle(color: c.t3)),
                  const SizedBox(height: 80),
                ]),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 120 + MediaQuery.paddingOf(context).bottom),
              sliver: SliverList.separated(
                itemCount: liste.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => CarteTache(liste[i], key: ValueKey(liste[i].id)),
              ),
            ),
        ]);
      },
    );
  }
}

(String, Color, IconData) etatTache(BuildContext context, Tache t) {
  final c = context.c;
  return switch (t.statut) {
    'en_attente' => ('En attente', c.t2, Icons.schedule_rounded),
    'programme' => ('Programmé', c.cyan, Icons.alarm_rounded),
    'analyse' => ('Analyse', c.violet, Icons.manage_search_rounded),
    'telechargement' => ('Téléchargement', c.bleu, Icons.south_rounded),
    'traitement' => ('Traitement', c.violet, Icons.auto_fix_high_rounded),
    'attente_relance' => ('Nouvelle tentative', c.ambre, Icons.replay_rounded),
    'pause' => ('En pause', c.ambre, Icons.pause_rounded),
    'termine' => ('Terminé', c.vert, Icons.check_circle_rounded),
    'erreur' => ('Erreur', c.rouge, Icons.error_rounded),
    'annule' => ('Annulé', c.t3, Icons.block_rounded),
    _ => (t.statut, c.t2, Icons.circle_outlined),
  };
}

class CarteTache extends StatelessWidget {
  final Tache t;
  const CarteTache(this.t, {super.key});

  Future<void> _retirer(BuildContext context, {bool annuler = false}) async {
    final confirme = await _confirmerRetrait(context,
      annuler ? 'Annuler ce téléchargement ?' : 'Retirer de la liste ?',
      annuler
        ? '« ${t.titre} » sera arrêté et ses fichiers temporaires seront supprimés. Pour continuer plus tard, utilise Pause.'
        : '« ${t.titre} » sera retiré de la liste. Les fichiers téléchargés seront conservés.',
      annuler ? 'Annuler le téléchargement' : 'Retirer');
    if (!confirme || !context.mounted) return;
    if (annuler) {
      // Le téléchargement peut s’être terminé pendant la confirmation.
      if (actifs.contains(t.statut) || t.statut == 'pause') gestionnaire.annuler(t.id);
    } else {
      await gestionnaire.supprimer(t.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (libelle, couleur, icone) = etatTache(context, t);
    final g = gestionnaire;
    final actif = enCours.contains(t.statut);
    final indetermine = t.statut == 'analyse' || t.statut == 'traitement' || t.statut == 'attente_relance';
    final principal = t.fichierPrincipal;
    return Verre(
      padding: const EdgeInsets.all(12),
      rayon: 20,
      onTap: principal != null ? () => Natif.ouvrir(principal.uri, principal.mime) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Miniature(t.miniature, largeur: 112, rayon: 10, texteDuree: formaterDuree(t.duree)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.titre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5, height: 1.3)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(icone, size: 14, color: couleur),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    t.phase.isNotEmpty && actif ? t.phase : libelle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: couleur, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
              if (t.pistes.isNotEmpty || t.options['type'] == 'audio')
                Text(
                  [
                    if (t.pistes.isNotEmpty) t.pistes,
                    t.options['type'] == 'audio'
                        ? '${t.options['format_audio']}'.toUpperCase()
                        : '${t.options['qualite'] == 'best' ? 'Max' : '${t.options['qualite']}p'} ${'${t.options['conteneur']}'.toUpperCase()}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.t3, fontSize: 11.5),
                ),
            ]),
          ),
        ]),
        if (actif || t.statut == 'pause' || t.statut == 'en_attente') ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(children: [
              Container(height: 6, color: c.verre3),
              if (indetermine && t.progression <= 0)
                LinearProgressIndicator(minHeight: 6, backgroundColor: Colors.transparent, color: couleur)
              else
                FractionallySizedBox(
                  widthFactor: (t.progression / 100).clamp(0, 1),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(gradient: t.statut == 'pause' ? null : gradBouton, color: c.ambre),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Text('${t.progression.toStringAsFixed(1).replaceAll('.', ',')} %', style: mono(context, taille: 11, couleur: c.t1)),
            const SizedBox(width: 10),
            if (t.total > 0)
              Text('${formaterTaille(t.telecharge)} / ${formaterTaille(t.total)}', style: mono(context, taille: 11)),
            const Spacer(),
            if (t.vitesse > 0) Text('${formaterTaille(t.vitesse)}/s', style: mono(context, taille: 11, couleur: c.vert)),
            if (t.eta != null && t.vitesse > 0) ...[
              const SizedBox(width: 8),
              Text(formaterDuree(t.eta), style: mono(context, taille: 11)),
            ],
          ]),
        ],
        if (t.erreur.isNotEmpty || t.message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(t.erreur.isNotEmpty ? t.erreur : t.message,
              style: TextStyle(color: t.erreur.isNotEmpty ? c.rouge : c.ambre, fontSize: 12)),
        ],
        if (t.statut == 'termine' && principal != null) ...[
          const SizedBox(height: 6),
          Text('${principal.chemin} · ${formaterTaille(t.tailleFichier)}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, taille: 10.5, couleur: c.t3)),
        ],
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (actifs.contains(t.statut))
            _Action(Icons.pause_rounded, 'Pause', () => g.pause(t.id)),
          if (t.statut == 'pause') _Action(Icons.play_arrow_rounded, 'Reprendre', () => g.reprendre(t.id)),
          if (t.statut == 'erreur' || t.statut == 'annule')
            _Action(Icons.refresh_rounded, 'Relancer', () => g.relancer(t.id)),
          if (t.statut == 'termine' && principal != null) ...[
            _Action(Icons.play_circle_outline_rounded, 'Ouvrir', () => Natif.ouvrir(principal.uri, principal.mime)),
            _Action(Icons.share_rounded, 'Partager', () => Natif.partager(principal.uri, principal.mime)),
          ],
          if (actifs.contains(t.statut) || t.statut == 'pause')
            _Action(Icons.close_rounded, 'Annuler', () => _retirer(context, annuler: true))
          else
            _Action(Icons.delete_outline_rounded, 'Retirer de la liste', () => _retirer(context)),
        ]),
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icone;
  final String aide;
  final VoidCallback onTap;
  const _Action(this.icone, this.aide, this.onTap);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: BoutonVerre(icone: icone, aide: aide, onTap: onTap),
      );
}
