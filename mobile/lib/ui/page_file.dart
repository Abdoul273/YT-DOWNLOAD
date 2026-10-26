/// Onglet En cours : file de téléchargements en direct.
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/natif.dart';
import '../moteur/erreurs.dart';
import '../moteur/taches.dart';
import 'etat.dart';
import 'page_reglages.dart' show modifierCookies;
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
        backgroundColor: ctx.c.sombre ? const Color(0xFF14162A) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: ctx.c.sombre ? ctx.c.indigo.withAlpha(50) : ctx.c.trait2),
        ),
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

  void _ouvrirMenuFile(BuildContext context) {
    HapticFeedback.lightImpact();
    final c = context.c;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(c.sombre ? 140 : 80),
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: c.sombre ? const Color(0xE8101224) : const Color(0xF4FFFFFF),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(
                  color: c.sombre ? c.indigo.withAlpha(85) : c.indigo.withAlpha(50),
                  width: 1.2,
                ),
                left: BorderSide(color: c.trait),
                right: BorderSide(color: c.trait),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(c.sombre ? 110 : 30),
                  blurRadius: 32,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: c.t3.withAlpha(90),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      'Gestion de la file',
                      style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: c.t1),
                    ),
                    const SizedBox(height: 12),
                    _ItemActionFile(
                      icone: Icons.pause_circle_outline_rounded,
                      couleur: c.ambre,
                      titre: 'Tout mettre en pause',
                      sousTitre: 'Suspendre les téléchargements actifs',
                      onTap: () {
                        Navigator.pop(ctx);
                        gestionnaire.actionGlobale('pause_tout');
                      },
                    ),
                    _ItemActionFile(
                      icone: Icons.play_circle_outline_rounded,
                      couleur: c.indigo,
                      titre: 'Tout reprendre',
                      sousTitre: 'Relancer les téléchargements en attente',
                      onTap: () {
                        Navigator.pop(ctx);
                        gestionnaire.actionGlobale('reprendre_tout');
                      },
                    ),
                    _ItemActionFile(
                      icone: Icons.replay_rounded,
                      couleur: c.cyan,
                      titre: 'Relancer les échecs',
                      sousTitre: 'Réessayer les téléchargements en erreur',
                      onTap: () {
                        Navigator.pop(ctx);
                        gestionnaire.actionGlobale('relancer_erreurs');
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Divider(color: c.trait, height: 10),
                    ),
                    _ItemActionFile(
                      icone: Icons.cleaning_services_rounded,
                      couleur: c.vert,
                      titre: 'Retirer les terminés',
                      sousTitre: 'Conserver les fichiers mais vider la file',
                      onTap: () async {
                        Navigator.pop(ctx);
                        final confirme = await _confirmerRetrait(
                          context,
                          'Nettoyer la liste ?',
                          'Retirer les téléchargements terminés de la liste ? Les fichiers téléchargés seront conservés.',
                          'Retirer',
                        );
                        if (confirme) gestionnaire.actionGlobale('vider_termines');
                      },
                    ),
                    _ItemActionFile(
                      icone: Icons.delete_sweep_rounded,
                      couleur: c.rouge,
                      titre: 'Retirer les échecs',
                      sousTitre: 'Supprimer les téléchargements annulés ou en échec',
                      destructif: true,
                      onTap: () async {
                        Navigator.pop(ctx);
                        final confirme = await _confirmerRetrait(
                          context,
                          'Nettoyer les échecs ?',
                          'Retirer les téléchargements en échec ou annulés de la liste ?',
                          'Retirer',
                        );
                        if (confirme) gestionnaire.actionGlobale('vider_echecs');
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
        final attente = gestionnaire.fileAttente;
        final idsAttente = attente.map((t) => t.id).toSet();
        final positions = {for (var i = 0; i < attente.length; i++) attente[i].id: i};
        final liste = [
          ...toutes.where((t) => enCours.contains(t.statut)),
          ...attente,
          ...toutes.where((t) => !enCours.contains(t.statut) && !idsAttente.contains(t.id)),
        ].where((t) => _correspond(_filtre, t)).toList();
        return CustomScrollView(slivers: [
          if (gestionnaire.avertissement != null)
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(gestionnaire.avertissement!, style: TextStyle(color: c.ambre)),
            )),
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
                IconButton(
                  tooltip: 'Options de la file',
                  icon: Icon(Icons.more_vert_rounded, color: c.t2),
                  onPressed: () => _ouvrirMenuFile(context),
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
                itemBuilder: (context, i) => CarteTache(liste[i], key: ValueKey(liste[i].id),
                    positionFile: positions[liste[i].id] ?? -1, nombreFile: attente.length),
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
  final int? positionFile, nombreFile;
  const CarteTache(this.t, {super.key, this.positionFile, this.nombreFile});

  Future<void> _corriger(BuildContext context, Remede action) async {
    if (action == Remede.cookies) {
      final ok = await modifierCookies(context);
      if (ok && t.statut == 'erreur') gestionnaire.relancer(t.id);
    } else if (action == Remede.stockage) {
      try {
        await Natif.ouvrirStockage();
      } catch (_) {
        if (context.mounted) toast(context, 'Ouvre les réglages de stockage du téléphone pour libérer de la place.', erreur: true);
      }
    } else {
      final audio = t.options['type'] == 'audio';
      final qualite = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withAlpha(context.c.sombre ? 140 : 80),
        builder: (ctx) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: BoxDecoration(
                color: ctx.c.sombre ? const Color(0xE8101224) : const Color(0xF4FFFFFF),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: ctx.c.sombre ? ctx.c.indigo.withAlpha(85) : ctx.c.indigo.withAlpha(50),
                    width: 1.2,
                  ),
                  left: BorderSide(color: ctx.c.trait),
                  right: BorderSide(color: ctx.c.trait),
                ),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: ctx.c.t3.withAlpha(90),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        audio ? 'Changer le format audio et réessayer' : 'Changer la qualité et réessayer',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: ctx.c.t1),
                      ),
                      const SizedBox(height: 12),
                      for (final q in audio ? const ['original', 'mp3', 'm4a', 'opus', 'flac', 'wav'] : const ['best', '1080', '720', '480', '360', '240', '144'])
                        ListTile(
                          title: Text(audio ? (q == 'original' ? 'Format original' : q.toUpperCase()) : q == 'best' ? 'Meilleure disponible' : '${q}p'),
                          trailing: t.options[audio ? 'format_audio' : 'qualite'] == q ? Icon(Icons.check_rounded, color: ctx.c.indigo) : null,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          onTap: () => Navigator.pop(ctx, q),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (qualite != null) gestionnaire.changerQualite(t.id, qualite);
    }
  }

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
    final action = t.statut == 'erreur' ? remede(t.erreur) : null;
    // La page calcule l'ordre une seule fois pour toutes les cartes.
    final attente = positionFile == null || nombreFile == null ? g.fileAttente : null;
    final position = positionFile ?? attente!.indexWhere((e) => e.id == t.id);
    final nombre = nombreFile ?? attente!.length;
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
        if (position >= 0)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(
            'Position ${position + 1} dans la file${t.statut == 'programme' ? ' · horaire conservé' : t.statut == 'pause' ? ' · en pause' : ''}',
            style: TextStyle(color: c.t3, fontSize: 12))),
        if (action != null)
          TextButton.icon(
            onPressed: () => _corriger(context, action),
            icon: Icon(switch (action) { Remede.cookies => Icons.cookie_outlined, Remede.qualite => Icons.tune_rounded, Remede.stockage => Icons.storage_rounded }),
            label: Text(switch (action) { Remede.cookies => 'Ajouter les cookies', Remede.qualite => t.options['type'] == 'audio' ? 'Changer le format audio' : 'Changer la qualité', Remede.stockage => 'Libérer de l’espace' }),
          ),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.end, children: [
          if (position >= 0 && nombre > 1)
            PopupMenuButton<int>(
              tooltip: 'Réorganiser la file',
              icon: const Icon(Icons.low_priority_rounded),
              onSelected: (cible) => g.deplacer(t.id, cible),
              itemBuilder: (_) => [
                if (position > 0) const PopupMenuItem(value: 0, child: Text('Passer en premier')),
                if (position > 1) PopupMenuItem(value: position - 1, child: const Text('Monter')),
                if (position < nombre - 1) PopupMenuItem(value: position + 1, child: const Text('Descendre')),
              ],
            ),
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

class _ItemActionFile extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String? sousTitre;
  final VoidCallback onTap;
  final bool destructif;

  const _ItemActionFile({
    required this.icone,
    required this.couleur,
    required this.titre,
    this.sousTitre,
    required this.onTap,
    this.destructif = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: couleur.withAlpha(c.sombre ? 32 : 24),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: couleur.withAlpha(c.sombre ? 60 : 40),
                    width: 1,
                  ),
                ),
                child: Icon(icone, color: couleur, size: 20),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titre,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: destructif ? c.rouge : c.t1,
                      ),
                    ),
                    if (sousTitre != null) ...[
                      const SizedBox(height: 1.5),
                      Text(
                        sousTitre!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: destructif ? c.rouge.withAlpha(190) : c.t3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: c.t3.withAlpha(80), size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
