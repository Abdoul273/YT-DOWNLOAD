/// Onglet Fichiers : médiathèque visuelle avec vue grille/liste, playlists locales,
/// renommage, extraction audio et jauge de stockage avec nettoyage des orphelins.
library;

import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'etat.dart';
import 'lecteur.dart';
import 'lecteur_audio.dart';
import 'theme.dart';

class PageFichiers extends StatefulWidget {
  const PageFichiers({super.key});
  @override
  State<PageFichiers> createState() => _PageFichiersState();
}

class _PageFichiersState extends State<PageFichiers> {
  final _champFiltre = TextEditingController();
  String _requete = '';
  String _type = 'tout'; // tout | video | audio
  String _groupe = ''; // playlist / dossier yt-dlp ('' = toutes)
  String _playlistId = ''; // playlist locale ('' = toutes)
  bool _favorisSeuls = false;
  final _selection = <String>{};

  ({int libre, int total, List<FichierPublie> fichiers})? _stockage;
  int _tailleTemp = 0;
  bool _chargeStockage = false;
  String _signatureStockage = '';

  static const _tris = {
    'recent': 'Plus récents',
    'ancien': 'Plus anciens',
    'titre': 'Titre (A→Z)',
    'chaine': 'Chaîne',
    'taille': 'Plus gros',
    'duree': 'Plus longs',
  };

  @override
  void initState() {
    super.initState();
    intercepteursRetour.add(_gererRetour);
    unawaited(_rafraichirStockage());
  }

  @override
  void dispose() {
    intercepteursRetour.remove(_gererRetour);
    _champFiltre.dispose();
    super.dispose();
  }

  bool _gererRetour() {
    if (onglet.value == 3 && _selection.isNotEmpty) {
      _annulerSelection();
      return true;
    }
    return false;
  }

  Future<void> _rafraichirStockage() async {
    if (_chargeStockage) return;
    _chargeStockage = true;
    try {
      final res = await Future.wait<Object?>([
        Natif.etatStockage().catchError((_) => (libre: 0, total: 0, fichiers: <FichierPublie>[])),
        gestionnaire.tailleTemporairesAsync().catchError((_) => 0),
      ]);
      if (!mounted) return;
      setState(() {
        _stockage = res[0] as ({int libre, int total, List<FichierPublie> fichiers});
        _tailleTemp = res[1] as int;
      });
    } catch (_) {
      // Sur test widget sans canal natif / dossiers initialisés, on reste silencieux.
    } finally {
      _chargeStockage = false;
    }
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

  /// Dernière vidéo lisible non terminée à reprendre rapidement.
  ({Tache tache, int posMs, double pct})? _videoAReprendre(List<Tache> videos) {
    final posMap = (reglages['positions'] as Map?) ?? const {};
    if (posMap.isEmpty || videos.isEmpty) return null;
    final parId = {for (final v in videos) v.id: v};
    for (final k in posMap.keys.toList().reversed) {
      final v = parId[k];
      if (v == null) continue;
      final pos = posMap[k];
      final pct = _avancement(v);
      if (pos is int && pct != null && pct < 0.95) {
        return (tache: v, posMs: pos, pct: pct);
      }
    }
    return null;
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
    ouvrirLecteur(context, lisibles, lisibles.indexOf(t)).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _lireListe(List<Tache> liste, {bool melanger = false}) {
    final lisibles = liste.where(_lisible).toList();
    if (lisibles.isEmpty) return;
    final tousAudio = lisibles.every(_estAudio);
    if (tousAudio) {
      ouvrirLecteurAudio(context, liste: lisibles, index: 0, melanger: melanger);
      return;
    }
    final ordre = List.of(lisibles);
    if (melanger) ordre.shuffle();
    ouvrirLecteur(context, ordre, 0).then((_) {
      if (mounted) setState(() {});
    });
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
      if (mounted) {
        setState(() => _selection.remove(t.id));
        toast(context, 'Fichier supprimé');
      }
    }
  }

  Future<String?> _demanderTexte({
    required String titre,
    required String etiquette,
    String initial = '',
    String confirmer = 'Valider',
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => _DialogueTexte(
          titre: titre,
          etiquette: etiquette,
          initial: initial,
          confirmer: confirmer,
        ),
      );

  Future<void> _renommerDialog(Tache t) async {
    final nouveau = await _demanderTexte(
      titre: 'Renommer le titre',
      etiquette: 'Nouveau nom du média',
      initial: t.titre,
      confirmer: 'Renommer',
    );
    if (nouveau == null || nouveau.isEmpty || nouveau == t.titre) return;
    try {
      final ok = await gestionnaire.renommer(t.id, nouveau);
      if (mounted) {
        toast(context, ok ? 'Titre renommé' : 'Impossible de renommer', erreur: !ok);
      }
    } catch (e) {
      if (mounted) toast(context, 'Renommage impossible : $e', erreur: true);
    }
  }

  Future<void> _extraireAudioDialog(Tache source) async {
    final c = context.c;
    var format = 'mp3';
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, maj) => AlertDialog(
          backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Extraire l’audio'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(source.titre, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.t2, fontSize: 13)),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                Puce(
                  'MP3',
                  sous: 'Universel · VBR',
                  choisie: format == 'mp3',
                  onTap: () => maj(() => format = 'mp3'),
                ),
                Puce(
                  'M4A',
                  sous: 'AAC · 192 kbps',
                  choisie: format == 'm4a',
                  onTap: () => maj(() => format = 'm4a'),
                ),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.indigo, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Extraire en ${format.toUpperCase()}'),
            ),
          ],
        ),
      ),
    );
    if (confirme != true || !mounted) return;

    var dialogueOuvert = true;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          content: Row(children: [
            CircularProgressIndicator(color: c.indigo, strokeWidth: 3),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Extraction ${format.toUpperCase()}…', style: TextStyle(fontWeight: FontWeight.w800, color: c.t1)),
                  const SizedBox(height: 4),
                  Text('Conversion FFmpeg locale en cours', style: TextStyle(color: c.t3, fontSize: 12)),
                ],
              ),
            ),
          ]),
        ),
      ),
    ).whenComplete(() => dialogueOuvert = false));

    try {
      final audio = await gestionnaire.extraireAudio(source, format: format);
      if (dialogueOuvert && mounted) Navigator.of(context, rootNavigator: true).pop();
      unawaited(_rafraichirStockage());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Row(children: [
            Icon(Icons.music_note_rounded, color: c.vert, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('Audio ${format.toUpperCase()} extrait')),
          ]),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          action: SnackBarAction(
            label: 'Écouter',
            textColor: c.cyan,
            onPressed: () => ouvrirLecteurAudio(context, liste: [audio], index: 0),
          ),
        ));
    } catch (e) {
      if (dialogueOuvert && mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) toast(context, 'Extraction échouée : $e', erreur: true);
    }
  }

  Future<PlaylistLocale?> _creerPlaylistDialog({List<String> tacheIds = const [], bool activerApres = true}) async {
    final nom = await _demanderTexte(
      titre: 'Nouvelle playlist locale',
      etiquette: 'Ex. Favoris hors-ligne, Sport, Nuit…',
      confirmer: 'Créer',
    );
    if (nom == null || nom.isEmpty) return null;
    final cree = PlaylistsLocales.creer(nom, tacheIds: tacheIds);
    if (mounted) {
      if (activerApres) setState(() => _playlistId = cree.id);
      toast(
        context,
        tacheIds.isEmpty
            ? 'Playlist « ${cree.nom} » créée'
            : '${tacheIds.length} titre${tacheIds.length > 1 ? 's' : ''} ajouté${tacheIds.length > 1 ? 's' : ''} à « ${cree.nom} »',
      );
    }
    return cree;
  }

  void _choisirPlaylistPour(List<String> tacheIds) {
    if (tacheIds.isEmpty) return;
    _ouvrirFeuilleVerre(
      context,
      child: StatefulBuilder(
        builder: (ctx, maj) {
          final c = ctx.c;
          final playlists = PlaylistsLocales.tout();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.playlist_add_rounded, color: c.cyan),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ajouter à une playlist (${tacheIds.length})',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.t1),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              _ItemMenuFichier(
                icone: Icons.add_circle_outline_rounded,
                couleur: c.indigo,
                titre: 'Créer une nouvelle playlist',
                sousTitre: 'Inclure immédiatement la sélection',
                onTap: () async {
                  Navigator.pop(ctx);
                  await _creerPlaylistDialog(tacheIds: tacheIds, activerApres: false);
                },
              ),
              if (playlists.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Divider(color: c.trait, height: 10),
                ),
                for (final p in playlists)
                  Builder(builder: (_) {
                    final contientTous = tacheIds.every(p.tacheIds.contains);
                    return _ItemMenuFichier(
                      icone: contientTous ? Icons.playlist_add_check_rounded : Icons.queue_music_rounded,
                      couleur: contientTous ? c.vert : c.cyan,
                      titre: p.nom,
                      sousTitre: '${p.tacheIds.length} titre${p.tacheIds.length > 1 ? 's' : ''}'
                          '${contientTous ? ' · déjà inclus' : ''}',
                      onTap: () {
                        if (contientTous) {
                          PlaylistsLocales.retirer(p.id, tacheIds);
                          toast(context, 'Retiré de « ${p.nom} »');
                        } else {
                          PlaylistsLocales.ajouter(p.id, tacheIds);
                          toast(context, 'Ajouté à « ${p.nom} »');
                        }
                        maj(() {});
                      },
                    );
                  }),
              ],
            ],
          );
        },
      ),
    );
  }

  void _ouvrirAtelierPlaylist(PlaylistLocale p, List<Tache> termines) {
    _ouvrirFeuilleVerre(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.nom, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: context.c.t1)),
                Text('${PlaylistsLocales.tachesDe(p, termines).length} média${p.tacheIds.length > 1 ? 's' : ''}',
                    style: TextStyle(color: context.c.t3, fontSize: 12)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          _ItemMenuFichier(
            icone: Icons.checklist_rtl_rounded,
            couleur: context.c.indigo,
            titre: 'Gérer les titres',
            sousTitre: 'Cocher ou décocher les fichiers de cette playlist',
            onTap: () {
              Navigator.pop(context);
              _ouvrirSelectionPistes(p, termines);
            },
          ),
          _ItemMenuFichier(
            icone: Icons.drive_file_rename_outline_rounded,
            couleur: context.c.cyan,
            titre: 'Renommer la playlist',
            sousTitre: 'Changer le nom affiché',
            onTap: () async {
              Navigator.pop(context);
              final nom = await _demanderTexte(
                titre: 'Renommer la playlist',
                etiquette: 'Nom de la playlist',
                initial: p.nom,
                confirmer: 'Enregistrer',
              );
              if (nom != null && PlaylistsLocales.renommer(p.id, nom) && mounted) {
                toast(context, 'Playlist renommée');
              }
            },
          ),
          _ItemMenuFichier(
            icone: Icons.delete_outline_rounded,
            couleur: context.c.rouge,
            titre: 'Supprimer la playlist',
            sousTitre: 'Conserve tous les fichiers téléchargés',
            destructif: true,
            onTap: () async {
              Navigator.pop(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: context.c.sombre ? const Color(0xFF14162A) : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  title: Text('Supprimer « ${p.nom} » ?'),
                  content: const Text('Seule la playlist locale sera supprimée ; vos vidéos et musiques restent sur l’appareil.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('Supprimer', style: TextStyle(color: context.c.rouge)),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                PlaylistsLocales.supprimer(p.id);
                if (mounted) {
                  if (_playlistId == p.id) setState(() => _playlistId = '');
                  toast(context, 'Playlist supprimée');
                }
              }
            },
          ),
        ],
      ),
    );
  }

  void _ouvrirSelectionPistes(PlaylistLocale p, List<Tache> termines) {
    final choisis = List<String>.from(p.tacheIds);
    _ouvrirFeuilleVerre(
      context,
      child: StatefulBuilder(
        builder: (ctx, maj) {
          final c = ctx.c;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Titres · ${p.nom}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.t1)),
                    Text('${choisis.length} sélectionné${choisis.length > 1 ? 's' : ''}',
                        style: TextStyle(color: c.t3, fontSize: 12)),
                  ]),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: c.indigo, foregroundColor: Colors.white),
                  onPressed: () {
                    PlaylistsLocales.definirElements(p.id, choisis);
                    Navigator.pop(ctx);
                    toast(context, 'Playlist mise à jour');
                  },
                  child: const Text('Enregistrer'),
                ),
              ]),
              const SizedBox(height: 10),
              if (termines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('Aucun fichier téléchargé', textAlign: TextAlign.center, style: TextStyle(color: c.t3)),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.52),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: termines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final t = termines[i];
                      final coche = choisis.contains(t.id);
                      final audio = _estAudio(t);
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          maj(() => coche ? choisis.remove(t.id) : choisis.add(t.id));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: coche ? c.indigo.withAlpha(c.sombre ? 36 : 20) : c.verre2,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: coche ? c.indigo.withAlpha(150) : c.trait),
                          ),
                          child: Row(children: [
                            Icon(
                              coche ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                              color: coche ? c.indigo : c.t3,
                              size: 21,
                            ),
                            const SizedBox(width: 10),
                            Miniature(t.miniature, largeur: 56, rayon: 8),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(t.titre,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13)),
                                Text(
                                  '${audio ? 'Audio' : 'Vidéo'} · ${formaterDuree(t.duree)} · ${formaterTaille(t.tailleFichier)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.t3, fontSize: 11),
                                ),
                              ]),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _ouvrirAtelierStockage(List<FichierPublie> orphelinsInit) {
    _ouvrirFeuilleVerre(
      context,
      child: _FeuilleStockage(
        tempInitial: _tailleTemp,
        stockageInitial: _stockage,
        orphelinsInit: orphelinsInit,
        onActualise: _rafraichirStockage,
      ),
    );
  }

  void _ouvrirMenuFichier(Tache t, List<Tache> liste, PlaylistLocale? playlistActive) {
    HapticFeedback.lightImpact();
    final c = context.c;
    final f = t.fichierPrincipal;
    final favs = _favoris;
    final estFav = favs.contains(t.id);
    final lisible = _lisible(t);
    final audio = _estAudio(t);

    _ouvrirFeuilleVerre(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              sousTitre: audio ? 'Écouter dans Onde Studio' : 'Regarder dans le lecteur vidéo',
              onTap: () {
                Navigator.pop(context);
                _lire(liste, t);
              },
            ),
          if (!audio && lisible)
            _ItemMenuFichier(
              icone: Icons.headphones_rounded,
              couleur: c.cyan,
              titre: 'Écouter en mode audio',
              sousTitre: 'Fond sonore ou verrouillé dans Onde Studio',
              onTap: () {
                Navigator.pop(context);
                final pos = ((reglages['positions'] as Map?) ?? const {})[t.id];
                ouvrirLecteurAudio(
                  context,
                  liste: [t],
                  index: 0,
                  departPosition: pos is int ? Duration(milliseconds: pos) : null,
                );
              },
            ),
          if (!audio && lisible && f != null)
            _ItemMenuFichier(
              icone: Icons.music_note_rounded,
              couleur: c.violet,
              titre: 'Extraire l’audio',
              sousTitre: 'Créer un fichier MP3 ou M4A hors-ligne',
              onTap: () {
                Navigator.pop(context);
                _extraireAudioDialog(t);
              },
            ),
          if (audio && lisible) ...[
            _ItemMenuFichier(
              icone: Icons.playlist_play_rounded,
              couleur: c.violet,
              titre: 'Lire ensuite',
              sousTitre: 'Insérer juste après le morceau en cours',
              onTap: () {
                Navigator.pop(context);
                moteurAudio.lireEnsuite(t);
                toast(context, 'Ajouté après le titre en cours');
              },
            ),
            _ItemMenuFichier(
              icone: Icons.queue_music_rounded,
              couleur: c.cyan,
              titre: 'Ajouter à la file musicale',
              sousTitre: 'Placer à la fin de la file d’attente',
              onTap: () {
                Navigator.pop(context);
                moteurAudio.ajouterAFile(t);
                toast(context, 'Ajouté à la file musicale');
              },
            ),
          ],
          _ItemMenuFichier(
            icone: Icons.playlist_add_rounded,
            couleur: c.cyan,
            titre: 'Ajouter à une playlist',
            sousTitre: 'Classer dans une playlist locale',
            onTap: () {
              Navigator.pop(context);
              _choisirPlaylistPour([t.id]);
            },
          ),
          if (playlistActive != null)
            _ItemMenuFichier(
              icone: Icons.playlist_remove_rounded,
              couleur: c.ambre,
              titre: 'Retirer de la playlist',
              sousTitre: 'Enlever de « ${playlistActive.nom} »',
              onTap: () {
                Navigator.pop(context);
                PlaylistsLocales.retirer(playlistActive.id, [t.id]);
                toast(context, 'Retiré de « ${playlistActive.nom} »');
              },
            ),
          _ItemMenuFichier(
            icone: Icons.drive_file_rename_outline_rounded,
            couleur: c.bleu,
            titre: 'Renommer le titre',
            sousTitre: 'Modifier le titre et le fichier enregistré',
            onTap: () {
              Navigator.pop(context);
              _renommerDialog(t);
            },
          ),
          _ItemMenuFichier(
            icone: estFav ? Icons.star_rounded : Icons.star_outline_rounded,
            couleur: c.ambre,
            titre: estFav ? 'Retirer des favoris' : 'Ajouter aux favoris',
            sousTitre: estFav ? 'Enlever de la sélection des favoris' : 'Garder en accès rapide',
            onTap: () {
              Navigator.pop(context);
              _basculerFavoris([t.id]);
            },
          ),
          _ItemMenuFichier(
            icone: Icons.checklist_rounded,
            couleur: c.bleu,
            titre: 'Sélectionner',
            sousTitre: 'Activer la sélection multiple',
            onTap: () {
              Navigator.pop(context);
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
                Navigator.pop(context);
                Natif.ouvrir(f.uri, f.mime);
              },
            ),
            _ItemMenuFichier(
              icone: Icons.share_rounded,
              couleur: c.vert,
              titre: 'Partager',
              sousTitre: 'Envoyer le fichier',
              onTap: () {
                Navigator.pop(context);
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
                Navigator.pop(context);
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
              Navigator.pop(context);
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
              Navigator.pop(context);
              _supprimer(t);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      // Pas l'avancement des téléchargements en cours : seulement les changements de statut.
      listenable: Listenable.merge([gestionnaire.statuts, reglages, moteurAudio.morceauActif]),
      builder: (context, _) {
        final termines = gestionnaire.taches.where((t) => t.statut == 'termine' && t.fichiers.isNotEmpty).toList();
        final q = _requete.toLowerCase();
        final favs = _favoris;
        final vueGrille = reglages['fichiers_vue_grille'] == true;
        final playlists = PlaylistsLocales.tout();
        PlaylistLocale? playlistActive;
        if (_playlistId.isNotEmpty) {
          for (final p in playlists) {
            if (p.id == _playlistId) {
              playlistActive = p;
              break;
            }
          }
          if (playlistActive == null) _playlistId = '';
        }

        final groupes = <String, int>{};
        for (final t in termines) {
          if (t.groupe != null && t.groupe!.isNotEmpty) groupes[t.groupe!] = (groupes[t.groupe!] ?? 0) + 1;
        }
        if (_groupe.isNotEmpty && !groupes.containsKey(_groupe)) _groupe = '';

        final idsPlaylist = playlistActive?.tacheIds.toSet();
        final liste = termines
            .where((t) => idsPlaylist == null || idsPlaylist.contains(t.id))
            .where((t) => q.isEmpty || t.titre.toLowerCase().contains(q) || (t.chaine ?? '').toLowerCase().contains(q))
            .where((t) => _type == 'tout' || (_type == 'audio') == _estAudio(t))
            .where((t) => _groupe.isEmpty || t.groupe == _groupe)
            .where((t) => !_favorisSeuls || favs.contains(t.id))
            .toList()
          ..sort(_comparer);

        final audios = liste.where((t) => _estAudio(t) && _lisible(t)).toList();
        final videosLisibles = liste.where((t) => !_estAudio(t) && _lisible(t)).toList();
        final repriseVideo = (_type == 'audio' || playlistActive != null) ? null : _videoAReprendre(videosLisibles);
        final total = termines.fold(0, (a, t) => a + t.tailleFichier);
        final tailleVideos = termines.where((t) => !_estAudio(t)).fold(0, (a, t) => a + t.tailleFichier);
        final tailleAudios = termines.where(_estAudio).fold(0, (a, t) => a + t.tailleFichier);
        final urisConnus = {
          for (final t in termines)
            for (final f in t.fichiers)
              if (f.uri.isNotEmpty) f.uri,
        };
        final cheminsConnus = {
          for (final t in termines)
            for (final f in t.fichiers)
              if (f.chemin.isNotEmpty) f.chemin,
        };
        final orphelinsDisque = [
          for (final f in _stockage?.fichiers ?? const <FichierPublie>[])
            if (!urisConnus.contains(f.uri) && (f.chemin.isEmpty || !cheminsConnus.contains(f.chemin))) f,
        ];
        final tailleOrphelins = orphelinsDisque.fold(0, (a, f) => a + f.taille);
        final manquants = termines.where((t) => t.message == 'Fichier déplacé ou supprimé').length;

        final signature = '${termines.length}:$total';
        if (signature != _signatureStockage && !_chargeStockage) {
          _signatureStockage = signature;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _rafraichirStockage();
          });
        }

        final selectionnes = liste.where((t) => _selection.contains(t.id)).toList();
        final tousSelectionnes = liste.isNotEmpty && liste.every((t) => _selection.contains(t.id));
        final idsTermines = {for (final t in termines) t.id};

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
                            child: Text(
                              '${selectionnes.length} sélectionné${selectionnes.length > 1 ? 's' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 15),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Ajouter à une playlist',
                            icon: Icon(Icons.playlist_add_rounded, color: c.cyan),
                            onPressed: () => _choisirPlaylistPour(selectionnes.map((t) => t.id).toList()),
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
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CarteMediatheque(
                            nbFichiers: termines.length,
                            nbVideos: termines.where((t) => !_estAudio(t)).length,
                            nbAudios: termines.where(_estAudio).length,
                            tailleVideos: tailleVideos,
                            tailleAudios: tailleAudios,
                            tailleTempEtOrphelins: _tailleTemp + tailleOrphelins,
                            nbOrphelins: orphelinsDisque.length + manquants,
                            libreDisque: _stockage?.libre ?? 0,
                            totalDisque: _stockage?.total ?? 0,
                            vueGrille: vueGrille,
                            onBasculerVue: (grille) => reglages['fichiers_vue_grille'] = grille,
                            onOuvrirStockage: () => _ouvrirAtelierStockage(orphelinsDisque),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _champFiltre,
                            onChanged: (v) => setState(() => _requete = v),
                            style: TextStyle(color: c.t1),
                            decoration: InputDecoration(
                              hintText: 'Filtrer titres, chaînes…',
                              hintStyle: TextStyle(color: c.t3),
                              prefixIcon: Icon(Icons.filter_list_rounded, color: c.t3),
                              suffixIcon: _requete.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Effacer le filtre',
                                      icon: Icon(Icons.close_rounded, color: c.t3, size: 19),
                                      onPressed: () {
                                        _champFiltre.clear();
                                        setState(() => _requete = '');
                                      },
                                    ),
                              filled: true,
                              fillColor: c.verre2,
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: c.trait),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: c.trait),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
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
                                    CheckedPopupMenuItem(
                                      value: e.key,
                                      checked: reglages['tri_fichiers'] == e.key,
                                      child: Text(e.value),
                                    ),
                                ],
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: c.verre2,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: c.trait),
                                  ),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Icon(Icons.sort_rounded, size: 16, color: c.t2),
                                    const SizedBox(width: 6),
                                    Text(
                                      _tris[reglages['tri_fichiers']] ?? _tris['recent']!,
                                      style: TextStyle(color: c.t2, fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ]),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 42,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                Puce(
                                  '+ Playlist',
                                  choisie: false,
                                  onTap: () => _creerPlaylistDialog(),
                                ),
                                for (final p in playlists) ...[
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onLongPress: () => _ouvrirAtelierPlaylist(p, termines),
                                    child: Puce(
                                      '🎵 ${p.nom} (${p.tacheIds.where(idsTermines.contains).length})',
                                      choisie: _playlistId == p.id,
                                      onTap: () => setState(() => _playlistId = _playlistId == p.id ? '' : p.id),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (groupes.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 40,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  for (final e in groupes.entries)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Puce(
                                        '📁 ${e.key} (${e.value})',
                                        choisie: _groupe == e.key,
                                        onTap: () => setState(() => _groupe = _groupe == e.key ? '' : e.key),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          if (playlistActive != null) ...[
                            const SizedBox(height: 12),
                            _CartePlaylistActive(
                              playlist: playlistActive,
                              elements: liste,
                              onLire: () => _lireListe(liste),
                              onMelanger: () => _lireListe(liste, melanger: true),
                              onGerer: () => _ouvrirAtelierPlaylist(playlistActive!, termines),
                            ),
                          ] else if (audios.isNotEmpty && _type != 'video') ...[
                            const SizedBox(height: 12),
                            Verre(
                              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                              rayon: 20,
                              teinte: c.sombre ? const Color(0x226366F1) : const Color(0x146366F1),
                              bordure: Border.all(color: c.indigo.withAlpha(90)),
                              child: Row(
                                children: [
                                  Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(12)),
                                    child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 20),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Onde Studio · ${audios.length} titre${audios.length > 1 ? 's' : ''}',
                                          style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 13.5),
                                        ),
                                        Text(
                                          'Platine vinyle, égaliseur 5 bandes & paroles',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: c.t2, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  BoutonVerre(
                                    icone: Icons.shuffle_rounded,
                                    aide: 'Lecture aléatoire',
                                    couleur: c.indigo,
                                    onTap: () => ouvrirLecteurAudio(context, liste: audios, index: 0, melanger: true),
                                  ),
                                  const SizedBox(width: 6),
                                  BoutonVerre(
                                    icone: Icons.play_arrow_rounded,
                                    texte: 'Écouter',
                                    couleur: c.indigo,
                                    onTap: () => ouvrirLecteurAudio(context, liste: audios, index: 0),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (repriseVideo != null && _selection.isEmpty) ...[
                            const SizedBox(height: 10),
                            Verre(
                              padding: const EdgeInsets.all(10),
                              rayon: 20,
                              teinte: c.sombre ? const Color(0x2006B6D4) : const Color(0x1406B6D4),
                              bordure: Border.all(color: c.cyan.withAlpha(85)),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => _lire(videosLisibles, repriseVideo.tache),
                                child: Row(children: [
                                  Stack(children: [
                                    Miniature(repriseVideo.tache.miniature, largeur: 72, rayon: 10),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: ClipRRect(
                                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                                        child: LinearProgressIndicator(
                                          value: repriseVideo.pct,
                                          minHeight: 3,
                                          backgroundColor: Colors.black54,
                                          valueColor: AlwaysStoppedAnimation(c.cyan),
                                        ),
                                      ),
                                    ),
                                  ]),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(
                                        'Reprendre à ${formaterDuree(repriseVideo.posMs ~/ 1000)}',
                                        style: TextStyle(color: c.cyan, fontSize: 11.5, fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        repriseVideo.tache.titre,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5),
                                      ),
                                    ]),
                                  ),
                                  const SizedBox(width: 8),
                                  BoutonVerre(
                                    icone: Icons.play_arrow_rounded,
                                    texte: 'Reprendre',
                                    couleur: c.cyan,
                                    onTap: () => _lire(videosLisibles, repriseVideo.tache),
                                  ),
                                ]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (liste.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            playlistActive != null ? Icons.queue_music_rounded : Icons.video_library_outlined,
                            size: 52,
                            color: c.t3,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            playlistActive != null ? 'Playlist vide' : 'Aucun fichier',
                            style: TextStyle(color: c.t3, fontWeight: FontWeight.w600),
                          ),
                          if (playlistActive != null && termines.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            BoutonVerre(
                              icone: Icons.playlist_add_rounded,
                              texte: 'Ajouter des titres',
                              couleur: c.indigo,
                              onTap: () => _ouvrirSelectionPistes(playlistActive!, termines),
                            ),
                          ],
                          const SizedBox(height: 80),
                        ]),
                      ),
                    )
                  else if (vueGrille)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 120 + MediaQuery.paddingOf(context).bottom),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          final dispo = (constraints.crossAxisExtent - 32).clamp(220.0, 2200.0);
                          final colonnes = dispo >= 820 ? 4 : (dispo >= 560 ? 3 : 2);
                          const espacement = 10.0;
                          final largeurCarte = (dispo - espacement * (colonnes - 1)) / colonnes;
                          final hauteurImage = (largeurCarte - 16) * 9 / 16;
                          final echelle = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.35);
                          final hauteurCarte = (hauteurImage + 16 + 98 * echelle).ceilToDouble();

                          return SliverGrid.builder(
                            itemCount: liste.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: colonnes,
                              mainAxisExtent: hauteurCarte,
                              crossAxisSpacing: espacement,
                              mainAxisSpacing: espacement,
                            ),
                            itemBuilder: (context, i) {
                              final t = liste[i];
                              return _CarteFichierGrille(
                                tache: t,
                                estAudio: _estAudio(t),
                                estFavori: favs.contains(t.id),
                                selectionMode: _selection.isNotEmpty,
                                choisi: _selection.contains(t.id),
                                enCoursAudio: moteurAudio.tache?.id == t.id,
                                avancement: _avancement(t),
                                onTap: () => _lire(liste, t),
                                onLongPress: () => _basculerSelection(t),
                                onMenu: () => _ouvrirMenuFichier(t, liste, playlistActive),
                              );
                            },
                          );
                        },
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
                          return _TuileFichierListe(
                            tache: t,
                            estAudio: _estAudio(t),
                            estFavori: favs.contains(t.id),
                            selectionMode: _selection.isNotEmpty,
                            choisi: _selection.contains(t.id),
                            enCoursAudio: moteurAudio.tache?.id == t.id,
                            avancement: _avancement(t),
                            onTap: () => _lire(liste, t),
                            onLongPress: () => _basculerSelection(t),
                            onMenu: () => _ouvrirMenuFichier(t, liste, playlistActive),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// En-tête de la médiathèque avec bascule Liste/Grille et jauge segmentée de stockage.
class _CarteMediatheque extends StatelessWidget {
  final int nbFichiers, nbVideos, nbAudios;
  final int tailleVideos, tailleAudios, tailleTempEtOrphelins;
  final int nbOrphelins;
  final int libreDisque, totalDisque;
  final bool vueGrille;
  final ValueChanged<bool> onBasculerVue;
  final VoidCallback onOuvrirStockage;

  const _CarteMediatheque({
    required this.nbFichiers,
    required this.nbVideos,
    required this.nbAudios,
    required this.tailleVideos,
    required this.tailleAudios,
    required this.tailleTempEtOrphelins,
    required this.nbOrphelins,
    required this.libreDisque,
    required this.totalDisque,
    required this.vueGrille,
    required this.onBasculerVue,
    required this.onOuvrirStockage,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final totalApp = tailleVideos + tailleAudios + tailleTempEtOrphelins;
    final alerteOrphelins = nbOrphelins > 0 || tailleTempEtOrphelins > 15 * 1024 * 1024;
    final denom = max(totalApp, 1);
    final flexV = tailleVideos <= 0 ? 0 : max(1, (tailleVideos * 1000 / denom).round());
    final flexA = tailleAudios <= 0 ? 0 : max(1, (tailleAudios * 1000 / denom).round());
    final flexO = tailleTempEtOrphelins <= 0 ? 0 : max(1, (tailleTempEtOrphelins * 1000 / denom).round());

    return Verre(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(gradient: gradVert, borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.video_library_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '$nbFichiers média${nbFichiers > 1 ? 's' : ''}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 16),
                ),
                Text(
                  '$nbVideos vidéo${nbVideos > 1 ? 's' : ''} · $nbAudios audio · ${formaterTaille(totalApp)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.t2, fontSize: 12),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: c.verre2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.trait),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _BoutonSegmentVue(
                  icone: Icons.view_agenda_rounded,
                  aide: 'Vue liste',
                  actif: !vueGrille,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onBasculerVue(false);
                  },
                ),
                const SizedBox(width: 2),
                _BoutonSegmentVue(
                  icone: Icons.grid_view_rounded,
                  aide: 'Vue grille',
                  actif: vueGrille,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onBasculerVue(true);
                  },
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onOuvrirStockage,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.verre2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: alerteOrphelins ? c.ambre.withAlpha(110) : c.trait),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      alerteOrphelins ? Icons.cleaning_services_rounded : Icons.sd_storage_rounded,
                      size: 15,
                      color: alerteOrphelins ? c.ambre : c.cyan,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        totalDisque > 0
                            ? 'Stockage · Libre : ${formaterTaille(libreDisque)} / ${formaterTaille(totalDisque)}'
                            : 'Stockage YT-NEXUS · ${formaterTaille(totalApp)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.t1, fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: (alerteOrphelins ? c.ambre : c.indigo).withAlpha(c.sombre ? 38 : 24),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        nbOrphelins > 0 ? '$nbOrphelins à nettoyer' : 'Gérer',
                        style: TextStyle(
                          color: alerteOrphelins ? c.ambre : c.indigo,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: SizedBox(
                      height: 6,
                      child: totalApp <= 0
                          ? Container(color: c.verre3)
                          : Row(children: [
                              if (flexV > 0) Expanded(flex: flexV, child: Container(color: c.indigo)),
                              if (flexA > 0) Expanded(flex: flexA, child: Container(color: c.cyan)),
                              if (flexO > 0) Expanded(flex: flexO, child: Container(color: c.ambre)),
                            ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 10, runSpacing: 4, children: [
                    _PointLegende(couleur: c.indigo, texte: 'Vidéos ${formaterTaille(tailleVideos)}'),
                    _PointLegende(couleur: c.cyan, texte: 'Audio ${formaterTaille(tailleAudios)}'),
                    if (tailleTempEtOrphelins > 0)
                      _PointLegende(couleur: c.ambre, texte: 'Temp & orphelins ${formaterTaille(tailleTempEtOrphelins)}'),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BoutonSegmentVue extends StatelessWidget {
  final IconData icone;
  final String aide;
  final bool actif;
  final VoidCallback onTap;
  const _BoutonSegmentVue({required this.icone, required this.aide, required this.actif, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tooltip(
      message: aide,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 32,
          height: 30,
          decoration: BoxDecoration(
            gradient: actif ? gradBouton : null,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icone, size: 17, color: actif ? Colors.white : c.t3),
        ),
      ),
    );
  }
}

class _PointLegende extends StatelessWidget {
  final Color couleur;
  final String texte;
  const _PointLegende({required this.couleur, required this.texte});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: couleur, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(texte, style: TextStyle(color: context.c.t3, fontSize: 10.5, fontWeight: FontWeight.w600)),
      ]);
}

/// Bannière affichée quand une playlist locale est sélectionnée.
class _CartePlaylistActive extends StatelessWidget {
  final PlaylistLocale playlist;
  final List<Tache> elements;
  final VoidCallback onLire;
  final VoidCallback onMelanger;
  final VoidCallback onGerer;

  const _CartePlaylistActive({
    required this.playlist,
    required this.elements,
    required this.onLire,
    required this.onMelanger,
    required this.onGerer,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final taille = elements.fold(0, (a, t) => a + t.tailleFichier);
    return Verre(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      rayon: 20,
      teinte: c.sombre ? const Color(0x246366F1) : const Color(0x146366F1),
      bordure: Border.all(color: c.indigo.withAlpha(110)),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              playlist.nom,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 14),
            ),
            Text(
              '${elements.length} titre${elements.length > 1 ? 's' : ''} · ${formaterTaille(taille)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.t2, fontSize: 11.5),
            ),
          ]),
        ),
        BoutonVerre(icone: Icons.tune_rounded, aide: 'Gérer la playlist', couleur: c.t2, onTap: onGerer),
        if (elements.isNotEmpty) ...[
          const SizedBox(width: 6),
          BoutonVerre(icone: Icons.shuffle_rounded, aide: 'Mélanger', couleur: c.cyan, onTap: onMelanger),
          const SizedBox(width: 6),
          BoutonVerre(icone: Icons.play_arrow_rounded, texte: 'Lire', couleur: c.indigo, onTap: onLire),
        ],
      ]),
    );
  }
}

class _BadgeTypeMedia extends StatelessWidget {
  final bool estAudio;
  final bool enCoursAudio;
  final bool selectionMode;
  final bool choisi;
  const _BadgeTypeMedia({
    required this.estAudio,
    required this.enCoursAudio,
    required this.selectionMode,
    required this.choisi,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (selectionMode) {
      return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: choisi ? c.indigo : Colors.black.withAlpha(170),
          shape: BoxShape.circle,
        ),
        child: Icon(
          choisi ? Icons.check_rounded : Icons.circle_outlined,
          size: 13,
          color: Colors.white,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: enCoursAudio ? c.indigo : Colors.black.withAlpha(165),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(
        enCoursAudio ? Icons.graphic_eq_rounded : (estAudio ? Icons.headphones_rounded : Icons.movie_rounded),
        size: 12,
        color: Colors.white,
      ),
    );
  }
}

class _TuileFichierListe extends StatelessWidget {
  final Tache tache;
  final bool estAudio, estFavori, selectionMode, choisi, enCoursAudio;
  final double? avancement;
  final VoidCallback onTap, onLongPress, onMenu;

  const _TuileFichierListe({
    required this.tache,
    required this.estAudio,
    required this.estFavori,
    required this.selectionMode,
    required this.choisi,
    required this.enCoursAudio,
    required this.avancement,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Verre(
        padding: const EdgeInsets.all(10),
        rayon: 20,
        teinte: enCoursAudio ? (c.sombre ? const Color(0x266366F1) : const Color(0x166366F1)) : null,
        bordure: enCoursAudio ? Border.all(color: c.indigo.withAlpha(150), width: 1.3) : null,
        onTap: onTap,
        child: Row(children: [
          if (selectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(
                choisi ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: choisi ? c.indigo : c.t3,
              ),
            ),
          Stack(children: [
            Miniature(tache.miniature, largeur: 112, rayon: 10, texteDuree: formaterDuree(tache.duree)),
            Positioned(
              left: 5,
              top: 5,
              child: _BadgeTypeMedia(
                estAudio: estAudio,
                enCoursAudio: enCoursAudio,
                selectionMode: false,
                choisi: choisi,
              ),
            ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                tache.titre,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: enCoursAudio ? c.indigo : c.t1,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                [if (tache.pistes.isNotEmpty) tache.pistes, formaterTaille(tache.tailleFichier)].join(' · '),
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
                      value: avancement,
                      minHeight: 3,
                      color: c.indigo,
                      backgroundColor: c.trait2,
                    ),
                  ),
                ),
              if (tache.message == 'Fichier déplacé ou supprimé')
                Text(tache.message, style: TextStyle(color: c.ambre, fontSize: 11.5)),
              if (tache.fichiers.length > 1)
                Text('${tache.fichiers.length} fichiers', style: TextStyle(color: c.t3, fontSize: 11.5)),
            ]),
          ),
          if (estFavori) Icon(Icons.star_rounded, size: 18, color: c.ambre),
          IconButton(
            tooltip: 'Options',
            icon: Icon(Icons.more_vert_rounded, color: c.t2),
            onPressed: onMenu,
          ),
        ]),
      ),
    );
  }
}

class _CarteFichierGrille extends StatelessWidget {
  final Tache tache;
  final bool estAudio, estFavori, selectionMode, choisi, enCoursAudio;
  final double? avancement;
  final VoidCallback onTap, onLongPress, onMenu;

  const _CarteFichierGrille({
    required this.tache,
    required this.estAudio,
    required this.estFavori,
    required this.selectionMode,
    required this.choisi,
    required this.enCoursAudio,
    required this.avancement,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final meta = tache.message == 'Fichier déplacé ou supprimé'
        ? tache.message
        : [
            if (tache.chaine != null && tache.chaine!.isNotEmpty) tache.chaine!,
            formaterTaille(tache.tailleFichier),
          ].join(' · ');

    return GestureDetector(
      onLongPress: onLongPress,
      child: Verre(
        padding: const EdgeInsets.all(8),
        rayon: 18,
        teinte: choisi || enCoursAudio ? (c.sombre ? const Color(0x286366F1) : const Color(0x166366F1)) : null,
        bordure: choisi || enCoursAudio ? Border.all(color: c.indigo.withAlpha(170), width: 1.4) : null,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Miniature(
                  tache.miniature,
                  largeur: double.infinity,
                  rayon: 12,
                  texteDuree: formaterDuree(tache.duree),
                ),
                Positioned(
                  left: 6,
                  top: 6,
                  child: _BadgeTypeMedia(
                    estAudio: estAudio,
                    enCoursAudio: enCoursAudio,
                    selectionMode: selectionMode,
                    choisi: choisi,
                  ),
                ),
                if (estFavori)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: Colors.black.withAlpha(165), borderRadius: BorderRadius.circular(7)),
                      child: Icon(Icons.star_rounded, size: 12, color: c.ambre),
                    ),
                  ),
                if (avancement != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                      child: LinearProgressIndicator(
                        value: avancement,
                        minHeight: 3,
                        color: c.indigo,
                        backgroundColor: Colors.black45,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      tache.titre,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: enCoursAudio ? c.indigo : c.t1,
                        fontSize: 12.8,
                        height: 1.2,
                      ),
                    ),
                  ),
                  Row(children: [
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tache.message == 'Fichier déplacé ou supprimé' ? c.ambre : c.t3,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Options',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                      icon: Icon(Icons.more_vert_rounded, color: c.t2, size: 18),
                      onPressed: onMenu,
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Atelier stockage : temporaires, références manquantes et fichiers orphelins sur disque.
class _FeuilleStockage extends StatefulWidget {
  final int tempInitial;
  final ({int libre, int total, List<FichierPublie> fichiers})? stockageInitial;
  final List<FichierPublie> orphelinsInit;
  final Future<void> Function() onActualise;
  const _FeuilleStockage({
    required this.tempInitial,
    required this.stockageInitial,
    required this.orphelinsInit,
    required this.onActualise,
  });

  @override
  State<_FeuilleStockage> createState() => _FeuilleStockageState();
}

class _FeuilleStockageState extends State<_FeuilleStockage> {
  bool _chargement = false;
  late int _temp = widget.tempInitial;
  int _manquants = 0;
  late int _libre = widget.stockageInitial?.libre ?? 0;
  late int _total = widget.stockageInitial?.total ?? 0;
  late List<FichierPublie> _orphelins = widget.orphelinsInit;

  @override
  void initState() {
    super.initState();
    unawaited(_analyser());
  }

  Future<void> _analyser() async {
    setState(() => _chargement = true);
    var temp = _temp;
    var libre = _libre, total = _total;
    var fichiersDisque = widget.stockageInitial?.fichiers ?? <FichierPublie>[];
    try {
      temp = await gestionnaire.tailleTemporairesAsync();
    } catch (_) {}
    try {
      final etat = await Natif.etatStockage();
      libre = etat.libre;
      total = etat.total;
      fichiersDisque = etat.fichiers;
    } catch (_) {}

    final termines = gestionnaire.taches.where((t) => t.statut == 'termine').toList();
    final uris = {
      for (final t in termines)
        for (final f in t.fichiers)
          if (f.uri.isNotEmpty) f.uri,
    };
    final chemins = {
      for (final t in termines)
        for (final f in t.fichiers)
          if (f.chemin.isNotEmpty) f.chemin,
    };
    final orphelins = [
      for (final f in fichiersDisque)
        if (!uris.contains(f.uri) && (f.chemin.isEmpty || !chemins.contains(f.chemin))) f,
    ];

    var absents = 0;
    for (final t in termines) {
      final f = t.fichierPrincipal;
      if (f == null || f.uri.isEmpty) {
        absents++;
        continue;
      }
      try {
        if (!await Natif.existe(f.uri)) absents++;
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _temp = temp;
      _libre = libre;
      _total = total;
      _orphelins = orphelins;
      _manquants = absents;
      _chargement = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tailleOrphelins = _orphelins.fold(0, (a, f) => a + f.taille);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(gradient: gradVert, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.sd_storage_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Stockage & nettoyage', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.t1)),
              Text(
                _total > 0
                    ? 'Libre : ${formaterTaille(_libre)} sur ${formaterTaille(_total)}'
                    : 'Dossier Téléchargements/YT-NEXUS',
                style: TextStyle(color: c.t3, fontSize: 12),
              ),
            ]),
          ),
          IconButton(
            tooltip: 'Actualiser',
            icon: Icon(Icons.refresh_rounded, color: c.t2),
            onPressed: _chargement ? null : _analyser,
          ),
        ]),
        const SizedBox(height: 12),
        if (_chargement) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(minHeight: 3, color: c.cyan, backgroundColor: c.verre3),
          ),
          const SizedBox(height: 10),
        ],
        Verre(
          padding: const EdgeInsets.all(12),
          rayon: 16,
          child: Row(children: [
            Icon(Icons.cleaning_services_rounded, color: _temp > 0 ? c.ambre : c.vert, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Temporaires & caches', style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5)),
                Text(
                  _temp > 0 ? '${formaterTaille(_temp)} libérables' : 'Aucun fichier temporaire inutile',
                  style: TextStyle(color: c.t3, fontSize: 11.5),
                ),
              ]),
            ),
            if (_temp > 0)
              BoutonVerre(
                icone: Icons.delete_sweep_rounded,
                texte: 'Vider',
                couleur: c.ambre,
                onTap: () async {
                  final libere = gestionnaire.viderTemporaires();
                  await widget.onActualise();
                  await _analyser();
                  if (context.mounted) toast(context, '${formaterTaille(libere)} libérés');
                },
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Verre(
          padding: const EdgeInsets.all(12),
          rayon: 16,
          child: Row(children: [
            Icon(Icons.link_off_rounded, color: _manquants > 0 ? c.ambre : c.vert, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Références introuvables', style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5)),
                Text(
                  _manquants > 0
                      ? '$_manquants entrée${_manquants > 1 ? 's' : ''} dont le fichier a été déplacé'
                      : 'Toutes les entrées pointent vers un fichier valide',
                  style: TextStyle(color: c.t3, fontSize: 11.5),
                ),
              ]),
            ),
            if (_manquants > 0)
              BoutonVerre(
                icone: Icons.auto_fix_high_rounded,
                texte: 'Nettoyer',
                couleur: c.ambre,
                onTap: () async {
                  final n = await gestionnaire.nettoyerReferencesManquantes();
                  await widget.onActualise();
                  await _analyser();
                  if (context.mounted) toast(context, '$n référence${n > 1 ? 's' : ''} retirée${n > 1 ? 's' : ''}');
                },
              ),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(
              'ORPHELIN${_orphelins.length > 1 ? 'S' : ''} SUR DISQUE (${_orphelins.length}'
              '${tailleOrphelins > 0 ? ' · ${formaterTaille(tailleOrphelins)}' : ''})',
              style: TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: c.t3),
            ),
          ),
          if (_orphelins.length > 1)
            TextButton(
              onPressed: () async {
                for (final f in List.of(_orphelins)) {
                  await Natif.supprimerFichier(f.uri);
                }
                await widget.onActualise();
                await _analyser();
                if (context.mounted) toast(context, 'Fichiers orphelins supprimés');
              },
              child: Text('Tout supprimer', style: TextStyle(color: c.rouge, fontSize: 12)),
            ),
        ]),
        const SizedBox(height: 6),
        if (_orphelins.isEmpty)
          Verre(
            padding: const EdgeInsets.all(14),
            rayon: 16,
            child: Row(children: [
              Icon(Icons.check_circle_outline_rounded, color: c.vert, size: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Aucun fichier orphelin dans Téléchargements/YT-NEXUS.',
                  style: TextStyle(color: c.t2, fontSize: 12.5),
                ),
              ),
            ]),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.34),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _orphelins.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final f = _orphelins[i];
                return Verre(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  rayon: 14,
                  child: Row(children: [
                    Icon(
                      f.mime.startsWith('audio') ? Icons.audiotrack_rounded : Icons.movie_outlined,
                      color: c.cyan,
                      size: 19,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(f.nom,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 12.5)),
                        Text(formaterTaille(f.taille), style: TextStyle(color: c.t3, fontSize: 11)),
                      ]),
                    ),
                    IconButton(
                      tooltip: 'Importer dans la médiathèque',
                      icon: Icon(Icons.add_circle_outline_rounded, color: c.indigo, size: 20),
                      onPressed: () async {
                        gestionnaire.importerFichierOrphelin(f);
                        await widget.onActualise();
                        await _analyser();
                        if (context.mounted) toast(context, 'Fichier importé');
                      },
                    ),
                    IconButton(
                      tooltip: 'Supprimer du téléphone',
                      icon: Icon(Icons.delete_outline_rounded, color: c.rouge, size: 20),
                      onPressed: () async {
                        await Natif.supprimerFichier(f.uri);
                        await widget.onActualise();
                        await _analyser();
                        if (context.mounted) toast(context, 'Orphelin supprimé');
                      },
                    ),
                  ]),
                );
              },
            ),
          ),
      ],
    );
  }
}

void _ouvrirFeuilleVerre(BuildContext context, {required Widget child}) {
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
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.85),
          decoration: BoxDecoration(
            color: c.sombre ? const Color(0xE8101224) : const Color(0xF4FFFFFF),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: c.sombre ? c.indigo.withAlpha(75) : c.trait2, width: 1.1),
            boxShadow: [
              BoxShadow(color: Colors.black.withAlpha(c.sombre ? 110 : 30), blurRadius: 32, offset: const Offset(0, -6)),
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
                      decoration: BoxDecoration(color: c.t3.withAlpha(90), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
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

class _DialogueTexte extends StatefulWidget {
  final String titre, etiquette, initial, confirmer;
  const _DialogueTexte({
    required this.titre,
    required this.etiquette,
    required this.initial,
    required this.confirmer,
  });

  @override
  State<_DialogueTexte> createState() => _DialogueTexteState();
}

class _DialogueTexteState extends State<_DialogueTexte> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _valider() {
    final s = _ctrl.text.trim();
    if (s.isNotEmpty) Navigator.pop(context, s);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AlertDialog(
      backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(widget.titre),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          hintText: widget.etiquette,
          filled: true,
          fillColor: c.verre2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.trait)),
        ),
        onSubmitted: (_) => _valider(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.indigo, foregroundColor: Colors.white),
          onPressed: _valider,
          child: Text(widget.confirmer),
        ),
      ],
    );
  }
}
