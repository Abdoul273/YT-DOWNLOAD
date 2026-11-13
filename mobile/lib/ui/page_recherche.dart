/// Onglet Recherche : fil « Pour vous » et tendances, suggestions pendant la saisie,
/// recherche YouTube avec tri et filtres.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/analyse.dart' as analyse;
import '../moteur/gouts.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'apercu.dart';
import 'etat.dart';
import 'lecteur.dart';
import 'theme.dart';

class PageRecherche extends StatefulWidget {
  const PageRecherche({super.key});
  @override
  State<PageRecherche> createState() => _PageRechercheState();
}

class _PageRechercheState extends State<PageRecherche> {
  final _champ = TextEditingController();
  final _focus = FocusNode();
  final _filtres = analyse.Filtres();
  List<analyse.Entree>? _resultats;
  String? _erreur, _requeteAffichee;
  bool _charge = false, _filtresOuverts = false;
  int _jeton = 0, _jetonSugg = 0;
  String _fil = 'pour_vous'; // pour_vous | tendances
  List<String> _suggestions = [];
  Timer? _delai;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    onglet.addListener(_ongletChange);
    gouts.addListener(_majGouts);
  }

  @override
  void dispose() {
    onglet.removeListener(_ongletChange);
    gouts.removeListener(_majGouts);
    _delai?.cancel();
    _champ.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _majGouts() {
    if (mounted) setState(() {});
  }

  void _ongletChange() {
    // Le fil se prépare à la première visite de l'onglet, puis se renouvelle toutes les heures
    if (onglet.value == 1) gouts.rafraichir();
  }

  void _saisie(String v) {
    setState(() {});
    _delai?.cancel();
    final jeton = ++_jetonSugg;
    if (v.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _delai = Timer(const Duration(milliseconds: 160), () async {
      try {
        final s = await suggestions(v);
        if (mounted && jeton == _jetonSugg) setState(() => _suggestions = s);
      } catch (_) {}
    });
  }

  Future<void> _chercher([String? requete]) async {
    if (requete != null) {
      _champ.text = requete;
      _champ.selection = TextSelection.collapsed(offset: requete.length);
    }
    final q = _champ.text.trim();
    if (q.isEmpty) return;
    _focus.unfocus();
    // Un lien collé ici part directement dans l'onglet Vidéo
    if (extraireLiens(q).isNotEmpty) return ouvrirLien(q);
    gouts.ajouterRecherche(q);
    final jeton = ++_jeton;
    setState(() {
      _charge = true;
      _erreur = null;
      _requeteAffichee = q;
    });
    try {
      final r = await analyse.rechercher(q, _filtres);
      if (jeton == _jeton) setState(() => _resultats = r);
    } catch (e) {
      if (jeton == _jeton) setState(() => _erreur = '$e');
    } finally {
      if (jeton == _jeton) setState(() => _charge = false);
    }
  }

  void _filtre(VoidCallback f) {
    setState(f);
    if (_resultats != null) _chercher();
  }

  void _retourAccueil() {
    _jeton++;
    _champ.clear();
    _focus.unfocus();
    setState(() {
      _resultats = null;
      _erreur = null;
      _charge = false;
      _requeteAffichee = null;
      _suggestions = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = _filtres;
    final enRecherche = _resultats != null || _charge || _erreur != null;
    return PopScope(
      canPop: !enRecherche && !_focus.hasFocus,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        if (_focus.hasFocus) {
          _focus.unfocus();
        } else {
          _retourAccueil();
        }
      },
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Verre(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _champ,
                        focusNode: _focus,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _chercher(),
                        onChanged: _saisie,
                        style: TextStyle(color: c.t1),
                        decoration: InputDecoration(
                          hintText: 'Rechercher sur YouTube',
                          hintStyle: TextStyle(color: c.t3),
                          prefixIcon: enRecherche || _focus.hasFocus
                              ? IconButton(
                                  icon: Icon(Icons.arrow_back_rounded, color: c.t2),
                                  onPressed: _focus.hasFocus && enRecherche ? _focus.unfocus : _retourAccueil)
                              : Icon(Icons.search_rounded, color: c.t3),
                          suffixIcon: _champ.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: Icon(Icons.close_rounded, color: c.t3),
                                  onPressed: () {
                                    _champ.clear();
                                    _saisie('');
                                    _focus.requestFocus();
                                  }),
                          filled: true,
                          fillColor: c.verre2,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Badge(
                      isLabelVisible: f.actifs || f.tri != 'pertinence',
                      smallSize: 8,
                      backgroundColor: c.indigo,
                      child: BoutonVerre(
                        icone: Icons.tune_rounded,
                        aide: 'Filtres',
                        couleur: _filtresOuverts ? c.indigo : null,
                        onTap: () => setState(() => _filtresOuverts = !_filtresOuverts),
                      ),
                    ),
                  ]),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: !_filtresOuverts
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Etiquette('Trier par'),
                              _Rangee([
                                for (final (k, l) in const [('pertinence', 'Pertinence'), ('date', 'Date'), ('vues', 'Vues'), ('note', 'Note')])
                                  Puce(l, choisie: f.tri == k, onTap: () => _filtre(() => f.tri = k)),
                              ]),
                              const SizedBox(height: 12),
                              const Etiquette('Mise en ligne'),
                              _Rangee([
                                for (final (k, l) in const [(null, 'Toutes'), ('heure', '1 h'), ('jour', 'Aujourd’hui'), ('semaine', 'Semaine'), ('mois', 'Mois'), ('annee', 'Année')])
                                  Puce(l, choisie: f.date == k, onTap: () => _filtre(() => f.date = k)),
                              ]),
                              const SizedBox(height: 12),
                              const Etiquette('Durée et qualité'),
                              _Rangee([
                                for (final (k, l) in const [('courte', '< 4 min'), ('moyenne', '4–20 min'), ('longue', '> 20 min')])
                                  Puce(l, choisie: f.duree == k, onTap: () => _filtre(() => f.duree = f.duree == k ? null : k)),
                                Puce('HD', choisie: f.hd, onTap: () => _filtre(() => f.hd = !f.hd)),
                                Puce('4K', choisie: f.k4, onTap: () => _filtre(() => f.k4 = !f.k4)),
                                Puce('Sous-titres', choisie: f.sousTitres, onTap: () => _filtre(() => f.sousTitres = !f.sousTitres)),
                              ]),
                            ]),
                          ),
                  ),
                ]),
              ),
            ),
          ),
          if (_focus.hasFocus)
            ..._suggestionsSlivers(context)
          else if (_charge)
            const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))
          else if (_erreur != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_erreur!, textAlign: TextAlign.center, style: TextStyle(color: c.rouge)),
              ),
            )
          else if (_resultats != null)
            _liste(_resultats!, vide: 'Aucun résultat pour « $_requeteAffichee ».')
          else
            ..._accueilSlivers(context),
        ],
      ),
    );
  }

  // ── suggestions ─────────────────────────────────────────────────────
  List<Widget> _suggestionsSlivers(BuildContext context) {
    final q = _champ.text.trim().toLowerCase();
    final historique = gouts.recherches
        .map((r) => r.$1)
        .where((h) => q.isEmpty || h.toLowerCase().contains(q))
        .take(q.isEmpty ? 12 : 3)
        .toList();
    final propositions = _suggestions.where((s) => !historique.any((h) => h.toLowerCase() == s.toLowerCase())).take(10);
    final lignes = [
      for (final h in historique) (h, true),
      for (final s in propositions) (s, false),
    ];
    if (lignes.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Text(q.isEmpty ? 'Tape pour voir des suggestions' : '',
                textAlign: TextAlign.center, style: TextStyle(color: context.c.t3)),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 120 + MediaQuery.paddingOf(context).bottom),
        sliver: SliverToBoxAdapter(
          child: Verre(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              for (final (texte, passe) in lignes)
                _LigneSuggestion(
                  texte: texte,
                  saisie: q,
                  historique: passe,
                  onTap: () => _chercher(texte),
                  onCompleter: () {
                    _champ.text = '$texte ';
                    _champ.selection = TextSelection.collapsed(offset: _champ.text.length);
                    _saisie(_champ.text);
                  },
                  onOublier: passe
                      ? () {
                          gouts.oublierRecherche(texte);
                          toast(context, 'Retiré de l’historique');
                        }
                      : null,
                ),
            ]),
          ),
        ),
      ),
    ];
  }

  // ── accueil : pour vous / tendances ─────────────────────────────────
  List<Widget> _accueilSlivers(BuildContext context) {
    final c = context.c;
    final froid = !gouts.aDesGouts;
    final pourVous = _fil == 'pour_vous';
    final liste = pourVous && !froid && gouts.fil.isNotEmpty ? gouts.fil : gouts.tendances;
    final interets = gouts.profil().interets(8);
    return [
      SliverToBoxAdapter(
        child: SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            children: [
              Puce('✨ Pour vous', choisie: pourVous, onTap: () => setState(() => _fil = 'pour_vous')),
              const SizedBox(width: 8),
              Puce('🔥 Tendances', choisie: !pourVous, onTap: () => setState(() => _fil = 'tendances')),
              for (final i in interets) ...[
                const SizedBox(width: 8),
                Puce(i, onTap: () => _chercher(i)),
              ],
            ],
          ),
        ),
      ),
      if (gouts.chargement)
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.fromLTRB(16, 6, 16, 0), child: LinearProgressIndicator(minHeight: 2)),
        ),
      if (pourVous && froid)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Verre(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(Icons.auto_awesome_rounded, color: c.indigo),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Recherche, regarde des aperçus et télécharge : « Pour vous » apprend tes goûts. '
                    'En attendant, voici les tendances.',
                    style: TextStyle(color: c.t2, fontSize: 12.5),
                  ),
                ),
              ]),
            ),
          ),
        ),
      if (liste.isEmpty && gouts.chargement)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverList.separated(
            itemCount: 6,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, _) => const _ResultatFantome(),
          ),
        )
      else if (liste.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(children: [
              Icon(Icons.wifi_off_rounded, size: 44, color: c.t3),
              const SizedBox(height: 10),
              Text(gouts.erreur ?? 'Rien à proposer pour l’instant.', textAlign: TextAlign.center, style: TextStyle(color: c.t3)),
              const SizedBox(height: 12),
              BoutonVerre(icone: Icons.refresh_rounded, texte: 'Réessayer', onTap: () => gouts.rafraichir(force: true)),
            ]),
          ),
        )
      else
        _liste(liste, vide: ''),
    ];
  }

  Widget _liste(List<analyse.Entree> l, {required String vide}) {
    final c = context.c;
    if (l.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(padding: const EdgeInsets.all(30), child: Text(vide, textAlign: TextAlign.center, style: TextStyle(color: c.t3))),
      );
    }
    final accueil = _resultats == null;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 120 + MediaQuery.paddingOf(context).bottom),
      sliver: SliverList.separated(
        itemCount: l.length + (accueil ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) => i == l.length
            ? Center(
                child: BoutonVerre(
                  icone: Icons.refresh_rounded,
                  texte: 'Nouvelles propositions',
                  onTap: gouts.chargement ? null : () => gouts.rafraichir(force: true),
                ),
              )
            : _Resultat(l[i], liste: l),
      ),
    );
  }
}

class _LigneSuggestion extends StatelessWidget {
  final String texte, saisie;
  final bool historique;
  final VoidCallback onTap, onCompleter;
  final VoidCallback? onOublier;
  const _LigneSuggestion(
      {required this.texte,
      required this.saisie,
      required this.historique,
      required this.onTap,
      required this.onCompleter,
      this.onOublier});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // Comme YouTube : ce qui est déjà tapé en normal, la suite en gras
    final debut = saisie.isNotEmpty && texte.toLowerCase().startsWith(saisie) ? saisie.length : 0;
    return InkWell(
      onTap: onTap,
      onLongPress: onOublier,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
        child: Row(children: [
          Icon(historique ? Icons.history_rounded : Icons.search_rounded, size: 20, color: c.t3),
          const SizedBox(width: 14),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: texte.substring(0, debut), style: TextStyle(color: c.t2)),
                TextSpan(text: texte.substring(debut), style: TextStyle(color: c.t1, fontWeight: FontWeight.w700)),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5),
            ),
          ),
          if (onOublier != null)
            IconButton(
              tooltip: 'Retirer',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 18, color: c.t3),
              onPressed: onOublier,
            ),
          IconButton(
            tooltip: 'Compléter',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.north_west_rounded, size: 18, color: c.t3),
            onPressed: onCompleter,
          ),
        ]),
      ),
    );
  }
}

class _ResultatFantome extends StatelessWidget {
  const _ResultatFantome();
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget barre(double l) =>
        Container(width: l, height: 11, decoration: BoxDecoration(color: c.verre3, borderRadius: BorderRadius.circular(6)));
    return Verre(
      padding: const EdgeInsets.all(10),
      rayon: 20,
      child: Row(children: [
        Container(
            width: 138, height: 78, decoration: BoxDecoration(color: c.verre3, borderRadius: BorderRadius.circular(12))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            barre(double.infinity),
            const SizedBox(height: 6),
            barre(120),
            const SizedBox(height: 10),
            barre(80),
          ]),
        ),
      ]),
    );
  }
}

class _Rangee extends StatelessWidget {
  final List<Widget> enfants;
  const _Rangee(this.enfants);
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: enfants);
}

void _regarderEnDirect(BuildContext context, List<analyse.Entree> liste, analyse.Entree e) {
  if (e.url == null) return;
  gouts.signalEntree('clic', e);
  final jouables = [
    for (final x in liste)
      if (x.url != null) x,
  ];
  var idx = jouables.indexOf(e);
  if (idx < 0) {
    jouables.insert(0, e);
    idx = 0;
  }
  ouvrirLecteurStream(
    context,
    entrees: jouables,
    index: idx,
  );
}

bool _peutOuvrirChaine(analyse.Entree e) =>
    (e.chaine != null && e.chaine!.trim().isNotEmpty) &&
    ((e.chaineId != null && e.chaineId!.isNotEmpty) ||
        (e.chaineUrl != null && e.chaineUrl!.isNotEmpty) ||
        (e.url != null && e.url!.isNotEmpty));

void _ouvrirPageChaine(BuildContext context, analyse.Entree e) {
  if (!_peutOuvrirChaine(e)) return;
  Navigator.of(context).push(PageRouteBuilder(
    pageBuilder: (_, _, _) => PageChaine(
      nomChaine: e.chaine!,
      chaineId: e.chaineId,
      chaineUrl: e.chaineUrl,
      videoUrlSecours: e.url,
    ),
    transitionsBuilder: (_, a, _, w) => FadeTransition(opacity: a, child: w),
  ));
}

Tache? _tacheExistantePourUrl(String url, String type) {
  final cle = Gestionnaire.cleVideo(url);
  for (final t in gestionnaire.taches) {
    if (Gestionnaire.cleVideo(t.url) != cle) continue;
    final tType = (t.options['type'] ?? 'video') as String;
    if (t.statut == 'termine' && t.fichiers.isNotEmpty && tType == type) return t;
    if (actifs.contains(t.statut) || t.statut == 'pause') return t;
  }
  return null;
}

Future<void> _telechargementRapide(BuildContext context, analyse.Entree e) async {
  final url = e.url;
  if (url == null || e.direct) return;
  HapticFeedback.mediumImpact();
  final type = (reglages['type'] as String?) ?? 'video';
  final existant = await gestionnaire.doublon(url, type);
  if (!context.mounted) return;
  if (existant != null) {
    if (existant.statut == 'termine' && existant.fichiers.isNotEmpty) {
      unawaited(ouvrirLecteur(context, [existant], 0));
      return;
    }
    toast(context, 'Déjà dans la file de téléchargement');
    return;
  }
  final aj = await gestionnaire.ajouter([
    Ajout(url, titre: e.titre, miniature: e.miniature, chaine: e.chaine, duree: e.duree),
  ], {
    'type': type,
    'qualite': reglages['qualite'] ?? '1080',
    'conteneur': reglages['conteneur'] ?? 'mp4',
    'compatible': reglages['compatible'] == true,
    'format_audio': reglages['format_audio'] ?? 'mp3',
    'langue_audio': reglages['langue_audio'] ?? 'original',
    'garder_vo': reglages['garder_vo'] ?? false,
    'sponsorblock': reglages['sponsorblock'] ?? false,
  });
  if (!context.mounted) return;
  if (aj.isEmpty) {
    toast(context, 'Déjà présent dans la file');
    return;
  }
  gouts.signal('telechargement', url: url, titre: e.titre, chaine: e.chaine, chaineId: e.chaineId);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(Icons.download_done_rounded, color: context.c.vert, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text('Ajouté à la file : ${e.titre}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      action: SnackBarAction(
        label: 'File',
        textColor: context.c.cyan,
        onPressed: () => onglet.value = 2,
      ),
    ));
}

class _Resultat extends StatelessWidget {
  final analyse.Entree e;
  final List<analyse.Entree> liste;
  final bool surChaineInterne;
  const _Resultat(this.e, {this.liste = const [], this.surChaineInterne = false});

  void _ouvrir() {
    gouts.signalEntree('clic', e);
    ouvrirLien(e.url!);
  }

  void _menu(BuildContext context) {
    HapticFeedback.lightImpact();
    final c = context.c;
    showModalBottomSheet(
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
                          Miniature(e.miniature, largeur: 76, rayon: 10, texteDuree: e.direct ? 'DIRECT' : formaterDuree(e.duree)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.titre,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 13.5, height: 1.25),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [if (e.chaine != null) e.chaine, formaterVues(e.vues), ilYA(e.date)].where((s) => s != null && s.isNotEmpty).join(' · '),
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
                    _LigneActionRecherche(
                      icone: Icons.smart_display_rounded,
                      couleur: c.cyan,
                      titre: 'Regarder en plein écran',
                      sousTitre: e.direct ? 'Lire le flux en direct sans pub' : 'Lecteur complet · résolutions & sous-titres',
                      onTap: () {
                        Navigator.pop(ctx);
                        _regarderEnDirect(context, liste, e);
                      },
                    ),
                    if (!e.direct)
                      _LigneActionRecherche(
                        icone: Icons.play_circle_outline_rounded,
                        couleur: c.indigo,
                        titre: 'Aperçu rapide',
                        sousTitre: 'Mini-lecteur avant téléchargement',
                        onTap: () {
                          Navigator.pop(ctx);
                          _FeuilleApercu.ouvrir(context, e, liste: liste);
                        },
                      ),
                    _LigneActionRecherche(
                      icone: Icons.download_rounded,
                      couleur: c.vert,
                      titre: 'Télécharger',
                      sousTitre: 'Analyser et choisir les options',
                      onTap: () {
                        Navigator.pop(ctx);
                        _ouvrir();
                      },
                    ),
                    if (!surChaineInterne && _peutOuvrirChaine(e))
                      _LigneActionRecherche(
                        icone: Icons.account_circle_outlined,
                        couleur: c.violet,
                        titre: 'Explorer la chaîne',
                        sousTitre: 'Voir toutes les vidéos de « ${e.chaine} »',
                        onTap: () {
                          Navigator.pop(ctx);
                          _ouvrirPageChaine(context, e);
                        },
                      ),
                    _LigneActionRecherche(
                      icone: Icons.not_interested_rounded,
                      couleur: c.t2,
                      titre: 'Pas intéressé',
                      sousTitre: 'Moins de propositions similaires',
                      onTap: () {
                        Navigator.pop(ctx);
                        gouts.pasInteresse(e);
                        toast(context, 'Compris, on en tiendra compte');
                      },
                    ),
                    if (e.chaine != null) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Divider(color: c.trait, height: 10),
                      ),
                      _LigneActionRecherche(
                        icone: Icons.block_rounded,
                        couleur: c.rouge,
                        titre: 'Ne plus recommander cette chaîne',
                        sousTitre: '« ${e.chaine} » masquée des propositions',
                        destructif: true,
                        onTap: () {
                          Navigator.pop(ctx);
                          gouts.bloquerChaine(e);
                          toast(context, 'Chaîne masquée des propositions');
                        },
                      ),
                    ],
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
    final peutChaine = !surChaineInterne && _peutOuvrirChaine(e);
    return Verre(
      padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
      rayon: 20,
      onTap: e.url == null ? null : _ouvrir,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: e.url == null
              ? null
              : (e.direct ? () => _regarderEnDirect(context, liste, e) : () => _FeuilleApercu.ouvrir(context, e, liste: liste)),
          child: Stack(alignment: Alignment.center, children: [
            Miniature(e.miniature, largeur: 138, texteDuree: e.direct ? 'DIRECT' : formaterDuree(e.duree)),
            if (e.url != null)
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.black.withAlpha(150), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
              ),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.titre,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5, height: 1.3)),
            const SizedBox(height: 4),
            if (e.chaine != null)
              peutChaine
                  ? InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _ouvrirPageChaine(context, e),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(
                            child: Text(
                              e.chaine!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.cyan, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(Icons.chevron_right_rounded, size: 14, color: c.cyan),
                        ]),
                      ),
                    )
                  : Text(e.chaine!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.t2, fontSize: 12)),
            Text([formaterVues(e.vues), ilYA(e.date)].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(color: c.t3, fontSize: 11.5)),
            if (e.url != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _regarderEnDirect(context, liste, e),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [c.indigo.withAlpha(c.sombre ? 65 : 35), c.cyan.withAlpha(c.sombre ? 50 : 25)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.indigo.withAlpha(c.sombre ? 130 : 90)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.play_arrow_rounded, size: 15, color: c.sombre ? c.cyan : c.indigo),
                        const SizedBox(width: 4),
                        Text(
                          e.direct ? 'En direct' : 'Regarder',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: c.t1,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                if (!e.direct)
                  ListenableBuilder(
                    listenable: gestionnaire.statuts,
                    builder: (context, _) {
                      final type = (reglages['type'] as String?) ?? 'video';
                      final existant = _tacheExistantePourUrl(e.url!, type);
                      final termine = existant?.statut == 'termine';
                      final actif = existant != null && !termine;
                      final couleur = termine ? c.vert : (actif ? c.cyan : c.vert);
                      final icone = termine
                          ? Icons.check_circle_rounded
                          : (actif ? Icons.schedule_rounded : Icons.download_rounded);
                      final libelle = termine ? 'Hors-ligne' : (actif ? 'En file' : 'Télécharger');
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            if (existant != null && termine) {
                              ouvrirLecteur(context, [existant], 0);
                            } else if (actif) {
                              onglet.value = 2;
                            } else {
                              _telechargementRapide(context, e);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: couleur.withAlpha(c.sombre ? 34 : 22),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: couleur.withAlpha(c.sombre ? 110 : 80)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(icone, size: 14.5, color: couleur),
                              const SizedBox(width: 4),
                              Text(libelle, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c.t1)),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
              ]),
            ],
          ]),
        ),
        if (e.url != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.more_vert_rounded, color: c.t3, size: 20),
            onPressed: () => _menu(context),
          ),
      ]),
    );
  }
}

/// Aperçu d'un résultat sans quitter la recherche.
class _FeuilleApercu extends StatefulWidget {
  final analyse.Entree e;
  final List<analyse.Entree> liste;
  const _FeuilleApercu(this.e, {this.liste = const []});

  static void ouvrir(BuildContext context, analyse.Entree e, {List<analyse.Entree> liste = const []}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withAlpha(context.c.sombre ? 140 : 80),
        builder: (_) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: BoxDecoration(
                color: context.c.sombre ? const Color(0xE8101224) : const Color(0xF4FFFFFF),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: context.c.sombre ? context.c.indigo.withAlpha(85) : context.c.indigo.withAlpha(50),
                    width: 1.2,
                  ),
                  left: BorderSide(color: context.c.trait),
                  right: BorderSide(color: context.c.trait),
                ),
              ),
              child: SafeArea(
                top: false,
                child: _FeuilleApercu(e, liste: liste),
              ),
            ),
          ),
        ),
      );

  @override
  State<_FeuilleApercu> createState() => _FeuilleApercuState();
}

class _FeuilleApercuState extends State<_FeuilleApercu> {
  late final Future<analyse.ResumeVideo> _video =
      analyse.infoComplete(widget.e.url!).then(analyse.resumeVideo);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final e = widget.e;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
              width: 40, height: 4, decoration: BoxDecoration(color: c.t3, borderRadius: BorderRadius.circular(2))),
        ),
        const SizedBox(height: 14),
        FutureBuilder(
          future: _video,
          builder: (context, s) {
            if (s.hasData) return Apercu(s.data!, auto: true, ongletParent: 1);
            return Stack(alignment: Alignment.center, children: [
              Miniature(e.miniature, largeur: double.infinity, rayon: 16),
              if (s.hasError)
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.black.withAlpha(180), borderRadius: BorderRadius.circular(12)),
                  child: Text('${s.error}', style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                )
              else
                const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            ]);
          },
        ),
        const SizedBox(height: 12),
        Text(e.titre,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 15, height: 1.3)),
        if (e.chaine != null) ...[
          const SizedBox(height: 4),
          _peutOuvrirChaine(e)
              ? InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    final nav = Navigator.of(context);
                    final parentCtx = nav.context;
                    nav.pop();
                    _ouvrirPageChaine(parentCtx, e);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                        child: Text(
                          e.chaine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.cyan, fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('· Voir la chaîne', style: TextStyle(color: c.indigo, fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                )
              : Text(e.chaine!, style: TextStyle(color: c.t2, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        Row(children: [
          BoutonVerre(
            icone: Icons.fullscreen_rounded,
            texte: 'Regarder',
            onTap: () {
              final nav = Navigator.of(context);
              final ctx = nav.context;
              nav.pop();
              _regarderEnDirect(ctx, widget.liste, e);
            },
          ),
          const SizedBox(width: 8),
          if (!e.direct)
            BoutonVerre(
              icone: Icons.bolt_rounded,
              texte: 'Rapide',
              couleur: c.vert,
              onTap: () {
                final nav = Navigator.of(context);
                final ctx = nav.context;
                nav.pop();
                _telechargementRapide(ctx, e);
              },
            ),
          if (!e.direct) const SizedBox(width: 8),
          Expanded(
            child: BoutonGrad('Options', icone: Icons.download_rounded, onTap: () {
              Navigator.of(context).pop();
              gouts.signalEntree('clic', e);
              ouvrirLien(e.url!);
            }),
          ),
        ]),
      ]),
    );
  }
}

String _formaterAbonnes(int? n) {
  if (n == null || n <= 0) return '';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1).replaceAll('.', ',')} M d’abonnés';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(n >= 10000 ? 0 : 1).replaceAll('.', ',')} k abonnés';
  return '$n abonnés';
}

/// Page dédiée à l'exploration d'une chaîne créateur (Vidéos, Shorts, Directs).
class PageChaine extends StatefulWidget {
  final String nomChaine;
  final String? chaineId, chaineUrl, videoUrlSecours;
  final Future<analyse.InfosChaine> Function(String section)? chargeurTest;

  const PageChaine({
    super.key,
    required this.nomChaine,
    this.chaineId,
    this.chaineUrl,
    this.videoUrlSecours,
    this.chargeurTest,
  });

  @override
  State<PageChaine> createState() => _PageChaineState();
}

class _PageChaineState extends State<PageChaine> {
  static const _sections = [
    ('videos', '🎬 Vidéos'),
    ('shorts', '⚡ Shorts'),
    ('streams', '🔴 Directs'),
  ];

  String _section = 'videos';
  String _filtre = '';
  final _filtreCtrl = TextEditingController();
  final _cache = <String, analyse.InfosChaine>{};
  final _erreurs = <String, String>{};
  bool _chargement = false;

  @override
  void initState() {
    super.initState();
    unawaited(_charger('videos'));
  }

  @override
  void dispose() {
    _filtreCtrl.dispose();
    super.dispose();
  }

  Future<void> _charger(String section, {bool force = false}) async {
    if (!force && _cache.containsKey(section)) {
      setState(() => _section = section);
      return;
    }
    setState(() {
      _section = section;
      _chargement = true;
      _erreurs.remove(section);
    });
    try {
      final info = widget.chargeurTest != null
          ? await widget.chargeurTest!(section)
          : await analyse.explorerChaine(
              chaineUrl: widget.chaineUrl,
              chaineId: widget.chaineId,
              nomChaine: widget.nomChaine,
              videoUrlSecours: widget.videoUrlSecours,
              section: section,
            );
      if (!mounted) return;
      setState(() {
        _cache[section] = info;
        _chargement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erreurs[section] = '$e';
        _chargement = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final info = _cache[_section];
    final err = _erreurs[_section];
    final q = _filtre.trim().toLowerCase();
    final entrees = [
      for (final e in info?.entrees ?? const <analyse.Entree>[])
        if (q.isEmpty || e.titre.toLowerCase().contains(q)) e,
    ];
    final titreAffiche = info?.titre ?? widget.nomChaine;
    final abonnes = _formaterAbonnes(info?.abonnes);

    return Scaffold(
      backgroundColor: c.fond,
      body: Stack(
        children: [
          const Positioned.fill(child: Aurore()),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          BoutonVerre(
                            icone: Icons.arrow_back_rounded,
                            aide: 'Retour',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Chaîne créateur',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: c.t1),
                            ),
                          ),
                          if (info != null)
                            BoutonVerre(
                              icone: Icons.playlist_add_check_rounded,
                              texte: 'Sélection lot',
                              couleur: c.indigo,
                              onTap: () {
                                Navigator.of(context).pop();
                                ouvrirLien(info.url);
                              },
                            ),
                        ]),
                        const SizedBox(height: 12),
                        Verre(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(16)),
                              alignment: Alignment.center,
                              child: Text(
                                titreAffiche.isNotEmpty ? titreAffiche.characters.first.toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(
                                  titreAffiche,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 16),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  [
                                    if (abonnes.isNotEmpty) abonnes,
                                    if (info != null) '${info.entrees.length} vidéos chargées',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.t2, fontSize: 12),
                                ),
                              ]),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final (id, label) in _sections)
                            Puce(
                              label,
                              choisie: _section == id,
                              onTap: () => _charger(id),
                            ),
                        ]),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _filtreCtrl,
                          onChanged: (v) => setState(() => _filtre = v),
                          style: TextStyle(color: c.t1),
                          decoration: InputDecoration(
                            hintText: 'Filtrer sur cette chaîne…',
                            hintStyle: TextStyle(color: c.t3, fontSize: 13.5),
                            prefixIcon: Icon(Icons.filter_list_rounded, color: c.t3),
                            suffixIcon: _filtre.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Effacer',
                                    icon: Icon(Icons.close_rounded, color: c.t3, size: 19),
                                    onPressed: () {
                                      _filtreCtrl.clear();
                                      setState(() => _filtre = '');
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
                      ],
                    ),
                  ),
                ),
                if (_chargement && info == null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    sliver: SliverList.separated(
                      itemCount: 5,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, _) => const _ResultatFantome(),
                    ),
                  )
                else if (err != null && info == null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(children: [
                        Icon(Icons.error_outline_rounded, color: c.rouge, size: 40),
                        const SizedBox(height: 10),
                        Text(err, textAlign: TextAlign.center, style: TextStyle(color: c.t2)),
                        const SizedBox(height: 12),
                        BoutonVerre(
                          icone: Icons.refresh_rounded,
                          texte: 'Réessayer',
                          onTap: () => _charger(_section, force: true),
                        ),
                      ]),
                    ),
                  )
                else if (entrees.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _filtre.trim().isNotEmpty
                            ? 'Aucune vidéo ne correspond à « $_filtre ».'
                            : 'Aucune vidéo dans cette section.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.t3),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + MediaQuery.paddingOf(context).bottom),
                    sliver: SliverList.separated(
                      itemCount: entrees.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _Resultat(entrees[i], liste: entrees, surChaineInterne: true),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LigneActionRecherche extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String? sousTitre;
  final VoidCallback onTap;
  final bool destructif;

  const _LigneActionRecherche({
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
