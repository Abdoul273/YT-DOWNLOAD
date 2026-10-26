/// Onglet Fichiers : bibliothèque des téléchargements terminés.
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'etat.dart';
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

  @override
  void initState() {
    super.initState();
    intercepteursRetour.add(_gererRetour);
  }

  @override
  void dispose() {
    intercepteursRetour.remove(_gererRetour);
    super.dispose();
  }

  bool _gererRetour() {
    if (onglet.value == 3 && _selection.isNotEmpty) {
      _annulerSelection();
      return true;
    }
    return false;
  }

  void _annulerSelection() {
    HapticFeedback.lightImpact();
    setState(_selection.clear);
  }

  void _basculerToutSelectionner(List<Tache> liste) {
    if (liste.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      final tous = liste.every((t) => _selection.contains(t.id));
      if (tous) {
        _selection.clear();
      } else {
        _selection.addAll(liste.map((t) => t.id));
      }
    });
  }

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

  void _basculerSelection(Tache t) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selection.remove(t.id)) _selection.add(t.id);
    });
  }

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

  void _ouvrirMenuFichier(Tache t, List<Tache> liste) {
    HapticFeedback.lightImpact();
    final c = context.c;
    final f = t.fichierPrincipal;
    final favs = _favoris;
    final estFav = favs.contains(t.id);
    final lisible = _lisible(t);
    final audio = _estAudio(t);

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
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
            ),
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
                          color: c.t3.withAlpha(90),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Verre(
                      padding: const EdgeInsets.all(10),
                      rayon: 18,
                      child: Row(
                        children: [
                          Stack(
                            children: [
                              Miniature(t.miniature, largeur: 76, rayon: 10, texteDuree: formaterDuree(t.duree)),
                              Positioned(
                                left: 4,
                                top: 4,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withAlpha(160),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Icon(
                                    audio ? Icons.headphones_rounded : Icons.movie_rounded,
                                    size: 11,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.titre,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: c.t1,
                                    fontSize: 13.5,
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    if (t.chaine != null && t.chaine!.isNotEmpty) t.chaine,
                                    if (t.pistes.isNotEmpty) t.pistes,
                                    formaterTaille(t.tailleFichier),
                                  ].whereType<String>().join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono(context, taille: 11, couleur: c.t2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (lisible)
                      _ItemMenuFichier(
                        icone: Icons.play_circle_fill_rounded,
                        couleur: c.indigo,
                        titre: 'Lire',
                        sousTitre: audio ? 'Écouter dans le lecteur' : 'Regarder dans le lecteur',
                        onTap: () {
                          Navigator.pop(ctx);
                          _lire(liste, t);
                        },
                      ),
                    _ItemMenuFichier(
                      icone: estFav ? Icons.star_rounded : Icons.star_outline_rounded,
                      couleur: c.ambre,
                      titre: estFav ? 'Retirer des favoris' : 'Ajouter aux favoris',
                      sousTitre: estFav ? 'Enlever de la sélection des favoris' : 'Garder en accès rapide',
                      onTap: () {
                        Navigator.pop(ctx);
                        _basculerFavoris([t.id]);
                      },
                    ),
                    _ItemMenuFichier(
                      icone: Icons.checklist_rounded,
                      couleur: c.bleu,
                      titre: 'Sélectionner',
                      sousTitre: 'Activer la sélection multiple',
                      onTap: () {
                        Navigator.pop(ctx);
                        _basculerSelection(t);
                      },
                    ),
                    if (f != null) ...[
                      _ItemMenuFichier(
                        icone: Icons.open_in_new_rounded,
                        couleur: c.cyan,
                        titre: 'Ouvrir avec…',
                        sousTitre: 'Choisir une autre application',
                        onTap: () {
                          Navigator.pop(ctx);
                          Natif.ouvrir(f.uri, f.mime);
                        },
                      ),
                      _ItemMenuFichier(
                        icone: Icons.share_rounded,
                        couleur: c.vert,
                        titre: 'Partager',
                        sousTitre: 'Envoyer le fichier',
                        onTap: () {
                          Navigator.pop(ctx);
                          Natif.partager(f.uri, f.mime);
                        },
                      ),
                    ],
                    if (t.url.isNotEmpty)
                      _ItemMenuFichier(
                        icone: Icons.smart_display_rounded,
                        couleur: const Color(0xFFFF0000),
                        titre: 'Voir sur YouTube',
                        sousTitre: 'Ouvrir la page originale',
                        onTap: () {
                          Navigator.pop(ctx);
                          Natif.ouvrirLien(t.url);
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Divider(color: c.trait, height: 10),
                    ),
                    _ItemMenuFichier(
                      icone: Icons.playlist_remove_rounded,
                      couleur: c.t2,
                      titre: 'Retirer de la liste',
                      sousTitre: 'Conserver le fichier sur le téléphone',
                      onTap: () {
                        Navigator.pop(ctx);
                        gestionnaire.supprimer(t.id);
                      },
                    ),
                    _ItemMenuFichier(
                      icone: Icons.delete_outline_rounded,
                      couleur: c.rouge,
                      titre: 'Supprimer le fichier',
                      sousTitre: 'Effacer définitivement du téléphone',
                      destructif: true,
                      onTap: () {
                        Navigator.pop(ctx);
                        _supprimer(t);
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
    final c = context.c;
    return ListenableBuilder(
      // Pas l'avancement des téléchargements en cours : seulement les changements de statut.
      listenable: Listenable.merge([gestionnaire.statuts, reglages]),
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
        final tousSelectionnes = liste.isNotEmpty && liste.every((t) => _selection.contains(t.id));
        return Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: _selection.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                      child: Verre(
                        flou: 16,
                        teinte: c.sombre ? const Color(0x286366F1) : const Color(0x186366F1),
                        bordure: Border.all(color: c.indigo.withAlpha(120), width: 1.2),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(children: [
                          IconButton(
                            tooltip: 'Annuler la sélection',
                            icon: Icon(Icons.close_rounded, color: c.t1),
                            onPressed: _annulerSelection,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text('${selectionnes.length} sélectionné${selectionnes.length > 1 ? 's' : ''}',
                                style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 15)),
                          ),
                          IconButton(
                            tooltip: tousSelectionnes ? 'Tout désélectionner' : 'Tout sélectionner',
                            icon: Icon(
                              tousSelectionnes ? Icons.deselect_rounded : Icons.select_all_rounded,
                              color: tousSelectionnes ? c.indigo : c.t1,
                            ),
                            onPressed: () => _basculerToutSelectionner(liste),
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
                      ),
                    ),
            ),
            Expanded(
              child: CustomScrollView(slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                      IconButton(
                        tooltip: 'Options',
                        icon: Icon(Icons.more_vert_rounded, color: c.t2),
                        onPressed: () => _ouvrirMenuFichier(t, liste),
                      ),
                    ]),
                  ),
                  );
                },
              ),
            ),
          ]),
        ),
      ],
    );
      },
    );
  }
}

class _ItemMenuFichier extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String? sousTitre;
  final VoidCallback onTap;
  final bool destructif;

  const _ItemMenuFichier({
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
