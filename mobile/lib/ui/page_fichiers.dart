/// Onglet Fichiers : bibliothèque des téléchargements terminés.
library;

import 'package:flutter/material.dart';

import '../moteur/natif.dart';
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

  bool _estAudio(Tache t) => t.fichierPrincipal?.mime.startsWith('audio') ?? t.options['type'] == 'audio';

  bool _lisible(Tache t) {
    final m = t.fichierPrincipal?.mime ?? '';
    return m.startsWith('video') || m.startsWith('audio');
  }

  /// Lecteur intégré, avec les autres fichiers de la liste affichée pour enchaîner.
  void _lire(List<Tache> liste, Tache t) {
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
      listenable: gestionnaire,
      builder: (context, _) {
        final termines = gestionnaire.taches.where((t) => t.statut == 'termine' && t.fichiers.isNotEmpty).toList()
          ..sort((a, b) => (b.fin ?? 0).compareTo(a.fin ?? 0));
        final q = _requete.toLowerCase();
        final liste = termines
            .where((t) => q.isEmpty || t.titre.toLowerCase().contains(q) || (t.chaine ?? '').toLowerCase().contains(q))
            .where((t) => _type == 'tout' || (_type == 'audio') == _estAudio(t))
            .toList();
        final total = termines.fold(0, (a, t) => a + t.tailleFichier);
        return CustomScrollView(slivers: [
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
                Wrap(spacing: 8, children: [
                  for (final (k, l) in const [('tout', 'Tout'), ('video', '🎬 Vidéos'), ('audio', '🎧 Audio')])
                    Puce(l, choisie: _type == k, onTap: () => setState(() => _type = k)),
                ]),
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
                  return Verre(
                    padding: const EdgeInsets.all(10),
                    rayon: 20,
                    onTap: () => _lire(liste, t),
                    child: Row(children: [
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
                          if (t.message == 'Fichier déplacé ou supprimé')
                            Text(t.message, style: TextStyle(color: c.ambre, fontSize: 11.5)),
                          if (t.fichiers.length > 1)
                            Text('${t.fichiers.length} fichiers', style: TextStyle(color: c.t3, fontSize: 11.5)),
                        ]),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert_rounded, color: c.t2),
                        color: c.sombre ? const Color(0xFF14162A) : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        onSelected: (a) {
                          switch (a) {
                            case 'lire':
                              _lire(liste, t);
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
                          const PopupMenuItem(value: 'ouvrir', child: Text('Ouvrir avec…')),
                          const PopupMenuItem(value: 'partager', child: Text('Partager')),
                          const PopupMenuItem(value: 'youtube', child: Text('Voir sur YouTube')),
                          const PopupMenuItem(value: 'retirer', child: Text('Retirer de la liste')),
                          PopupMenuItem(value: 'supprimer', child: Text('Supprimer le fichier', style: TextStyle(color: c.rouge))),
                        ],
                      ),
                    ]),
                  );
                },
              ),
            ),
        ]);
      },
    );
  }
}
