/// Onglet Fichiers : bibliothèque des téléchargements terminés.
library;

import 'package:flutter/material.dart';

import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'lecteur.dart';
import 'theme.dart';

class PageFichiers extends StatefulWidget {
  const PageFichiers({super.key});
  @override
  State<PageFichiers> createState() => _PageFichiersState();
}

class _PageFichiersState extends State<PageFichiers> {
  String _requete = '';
  String _type = 'tout'; // tout | video | audio
  String _groupe = ''; // playlist / dossier ('' = toutes)
  bool _favorisSeuls = false;
  final _selection = <String>{};

  static const _tris = {
    'recent': 'Plus récents',
    'ancien': 'Plus anciens',
    'titre': 'Titre (A→Z)',
    'chaine': 'Chaîne',
    'taille': 'Plus gros',
    'duree': 'Plus longs',
  };

  Set<String> get _favoris => {for (final e in (reglages['favoris'] as List? ?? const [])) '$e'};

  void _basculerFavoris(Iterable<String> ids) {
    final f = _favoris;
    final tous = ids.every(f.contains);
    tous ? f.removeAll(ids) : f.addAll(ids);
    reglages['favoris'] = f.toList();
  }

  void _basculerSelection(Tache t) => setState(() {
        if (!_selection.remove(t.id)) _selection.add(t.id);
      });

  /// Avancement de lecture (0‥1) pour la barre « reprendre », sinon null.
  double? _avancement(Tache t) {
    final pos = ((reglages['positions'] as Map?) ?? const {})[t.id];
    final d = t.duree;
    if (pos is! int || d == null || d <= 0 || pos < 10000) return null;
    return (pos / (d * 1000)).clamp(0.0, 1.0);
  }

  int _comparer(Tache a, Tache b) => switch (reglages['tri_fichiers']) {
        'ancien' => (a.fin ?? 0).compareTo(b.fin ?? 0),
        'titre' => a.titre.toLowerCase().compareTo(b.titre.toLowerCase()),
        'chaine' => (a.chaine ?? '').toLowerCase().compareTo((b.chaine ?? '').toLowerCase()),
        'taille' => b.tailleFichier.compareTo(a.tailleFichier),
        'duree' => (b.duree ?? 0).compareTo(a.duree ?? 0),
        _ => (b.fin ?? 0).compareTo(a.fin ?? 0),
      };

  Future<void> _supprimerSelection(List<Tache> toutes) async {
    final c = context.c;
    final cibles = toutes.where((t) => _selection.contains(t.id)).toList();
    if (cibles.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Supprimer ${cibles.length} fichier${cibles.length > 1 ? 's' : ''} ?'),
        content: const Text('Les fichiers seront effacés du téléphone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Supprimer', style: TextStyle(color: c.rouge)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final t in cibles) {
      await gestionnaire.supprimer(t.id, fichier: true);
    }
    if (mounted) {
      setState(_selection.clear);
      toast(context, '${cibles.length} fichier${cibles.length > 1 ? 's' : ''} supprimé${cibles.length > 1 ? 's' : ''}');
    }
  }

  bool _estAudio(Tache t) => t.fichierPrincipal?.mime.startsWith('audio') ?? t.options['type'] == 'audio';

  bool _lisible(Tache t) {
    final m = t.fichierPrincipal?.mime ?? '';
    return m.startsWith('video') || m.startsWith('audio');
  }

  /// Lecteur intégré, avec les autres fichiers de la liste affichée pour enchaîner.
  void _lire(List<Tache> liste, Tache t) {
    if (_selection.isNotEmpty) return _basculerSelection(t);
    final f = t.fichierPrincipal!;
    if (!_lisible(t)) {
      Natif.ouvrir(f.uri, f.mime);
      return;
    }
    final lisibles = liste.where(_lisible).toList();
    ouvrirLecteur(context, lisibles, lisibles.indexOf(t));
  }

  Future<void> _supprimer(Tache t) async {
    final c = context.c;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Supprimer le fichier ?'),
        content: Text(t.titre),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Supprimer', style: TextStyle(color: c.rouge)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await gestionnaire.supprimer(t.id, fichier: true);
      if (mounted) toast(context, 'Fichier supprimé');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([gestionnaire, reglages]),
      builder: (context, _) {
        final termines = gestionnaire.taches.where((t) => t.statut == 'termine' && t.fichiers.isNotEmpty).toList();
        final q = _requete.toLowerCase();
        final favs = _favoris;
        final groupes = <String, int>{};
        for (final t in termines) {
          if (t.groupe != null && t.groupe!.isNotEmpty) groupes[t.groupe!] = (groupes[t.groupe!] ?? 0) + 1;
        }
        if (_groupe.isNotEmpty && !groupes.containsKey(_groupe)) _groupe = '';
        final liste = termines
            .where((t) => q.isEmpty || t.titre.toLowerCase().contains(q) || (t.chaine ?? '').toLowerCase().contains(q))
            .where((t) => _type == 'tout' || (_type == 'audio') == _estAudio(t))
            .where((t) => _groupe.isEmpty || t.groupe == _groupe)
            .where((t) => !_favorisSeuls || favs.contains(t.id))
            .toList()
          ..sort(_comparer);
        final total = termines.fold(0, (a, t) => a + t.tailleFichier);
        final selectionnes = liste.where((t) => _selection.contains(t.id)).toList();
        return CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_selection.isNotEmpty)
                  Verre(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                    child: Row(children: [
                      IconButton(
                        tooltip: 'Annuler la sélection',
                        icon: Icon(Icons.close_rounded, color: c.t1),
                        onPressed: () => setState(_selection.clear),
                      ),
                      Expanded(
                        child: Text('${selectionnes.length} sélectionné${selectionnes.length > 1 ? 's' : ''}',
                            style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 15)),
                      ),
                      IconButton(
                        tooltip: 'Tout sélectionner',
                        icon: Icon(Icons.select_all_rounded, color: c.t1),
                        onPressed: () => setState(() => _selection.addAll(liste.map((t) => t.id))),
                      ),
                      IconButton(
                        tooltip: 'Favoris',
                        icon: Icon(Icons.star_rounded, color: c.ambre),
                        onPressed: () => _basculerFavoris(selectionnes.map((t) => t.id)),
                      ),
                      IconButton(
                        tooltip: 'Supprimer',
                        icon: Icon(Icons.delete_outline_rounded, color: c.rouge),
                        onPressed: () => _supprimerSelection(liste),
                      ),
                    ]),
                  )
                else
                Verre(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(gradient: gradVert, borderRadius: BorderRadius.circular(14)),
                      child: const Icon(Icons.folder_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${termines.length} fichier${termines.length > 1 ? 's' : ''}',
                            style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 16)),
                        Text('Téléchargements/YT-NEXUS · ${formaterTaille(total)}',
                            style: TextStyle(color: c.t2, fontSize: 12)),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (v) => setState(() => _requete = v),
                  style: TextStyle(color: c.t1),
                  decoration: InputDecoration(
                    hintText: 'Filtrer',
                    hintStyle: TextStyle(color: c.t3),
                    prefixIcon: Icon(Icons.filter_list_rounded, color: c.t3),
                    filled: true,
                    fillColor: c.verre2,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.trait)),
                    enabledBorder:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.trait)),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (k, l) in const [('tout', 'Tout'), ('video', '🎬 Vidéos'), ('audio', '🎧 Audio')])
                    Puce(l, choisie: _type == k, onTap: () => setState(() => _type = k)),
                  Puce('⭐ Favoris', choisie: _favorisSeuls, onTap: () => setState(() => _favorisSeuls = !_favorisSeuls)),
                  PopupMenuButton<String>(
                    tooltip: 'Trier',
                    color: c.sombre ? const Color(0xFF14162A) : Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (k) => reglages['tri_fichiers'] = k,
                    itemBuilder: (_) => [
                      for (final e in _tris.entries)
                        CheckedPopupMenuItem(value: e.key, checked: reglages['tri_fichiers'] == e.key, child: Text(e.value)),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                          color: c.verre2, borderRadius: BorderRadius.circular(20), border: Border.all(color: c.trait)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.sort_rounded, size: 16, color: c.t2),
                        const SizedBox(width: 6),
                        Text(_tris[reglages['tri_fichiers']] ?? _tris['recent']!,
                            style: TextStyle(color: c.t2, fontSize: 13, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ]),
                if (groupes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 38,
                    child: ListView(scrollDirection: Axis.horizontal, children: [
                      for (final e in groupes.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Puce('📁 ${e.key} (${e.value})',
                              choisie: _groupe == e.key, onTap: () => setState(() => _groupe = _groupe == e.key ? '' : e.key)),
                        ),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
          if (liste.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.video_library_outlined, size: 52, color: c.t3),
                  const SizedBox(height: 10),
                  Text('Aucun fichier', style: TextStyle(color: c.t3)),
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
                itemBuilder: (context, i) {
                  final t = liste[i];
                  final f = t.fichierPrincipal!;
                  final choisi = _selection.contains(t.id);
                  final avancement = _avancement(t);
                  return GestureDetector(
                    onLongPress: () => _basculerSelection(t),
                    child: Verre(
                    padding: const EdgeInsets.all(10),
                    rayon: 20,
                    onTap: () => _lire(liste, t),
                    child: Row(children: [
                      if (_selection.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Icon(choisi ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                              color: choisi ? c.indigo : c.t3),
                        ),
                      Stack(children: [
                        Miniature(t.miniature, largeur: 112, rayon: 10, texteDuree: formaterDuree(t.duree)),
                        Positioned(
                          left: 5,
                          top: 5,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(color: Colors.black.withAlpha(160), borderRadius: BorderRadius.circular(6)),
                            child: Icon(_estAudio(t) ? Icons.headphones_rounded : Icons.movie_rounded,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.titre,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5)),
                          const SizedBox(height: 3),
                          Text(
                            [if (t.pistes.isNotEmpty) t.pistes, formaterTaille(t.tailleFichier)].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: c.t2, fontSize: 11.5),
                          ),
                          if (avancement != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 5, right: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                    value: avancement, minHeight: 3, color: c.indigo, backgroundColor: c.trait2),
                              ),
                            ),
                          if (t.message == 'Fichier déplacé ou supprimé')
                            Text(t.message, style: TextStyle(color: c.ambre, fontSize: 11.5)),
                          if (t.fichiers.length > 1)
                            Text('${t.fichiers.length} fichiers', style: TextStyle(color: c.t3, fontSize: 11.5)),
                        ]),
                      ),
                      if (favs.contains(t.id)) Icon(Icons.star_rounded, size: 18, color: c.ambre),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert_rounded, color: c.t2),
                        color: c.sombre ? const Color(0xFF14162A) : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        onSelected: (a) {
                          switch (a) {
                            case 'lire':
                              _lire(liste, t);
                            case 'favori':
                              _basculerFavoris([t.id]);
                            case 'selection':
                              _basculerSelection(t);
                            case 'ouvrir':
                              Natif.ouvrir(f.uri, f.mime);
                            case 'partager':
                              Natif.partager(f.uri, f.mime);
                            case 'youtube':
                              Natif.ouvrirLien(t.url);
                            case 'retirer':
                              gestionnaire.supprimer(t.id);
                            case 'supprimer':
                              _supprimer(t);
                          }
                        },
                        itemBuilder: (_) => [
                          if (_lisible(t)) const PopupMenuItem(value: 'lire', child: Text('Lire')),
                          PopupMenuItem(
                              value: 'favori', child: Text(favs.contains(t.id) ? 'Retirer des favoris' : 'Ajouter aux favoris')),
                          const PopupMenuItem(value: 'selection', child: Text('Sélectionner')),
                          const PopupMenuItem(value: 'ouvrir', child: Text('Ouvrir avec…')),
                          const PopupMenuItem(value: 'partager', child: Text('Partager')),
                          const PopupMenuItem(value: 'youtube', child: Text('Voir sur YouTube')),
                          const PopupMenuItem(value: 'retirer', child: Text('Retirer de la liste')),
                          PopupMenuItem(value: 'supprimer', child: Text('Supprimer le fichier', style: TextStyle(color: c.rouge))),
                        ],
                      ),
                    ]),
                  ),
                  );
                },
              ),
            ),
        ]);
      },
    );
  }
}
