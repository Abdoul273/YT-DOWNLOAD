/// Onglet Recherche : fil « Pour vous » et tendances, suggestions pendant la saisie,
/// recherche YouTube avec tri et filtres.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../moteur/analyse.dart' as analyse;
import '../moteur/gouts.dart';
import '../moteur/taches.dart';
import 'apercu.dart';
import 'etat.dart';
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
            : _Resultat(l[i]),
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

class _Resultat extends StatelessWidget {
  final analyse.Entree e;
  const _Resultat(this.e);

  void _ouvrir() {
    gouts.signalEntree('clic', e);
    ouvrirLien(e.url!);
  }

  void _menu(BuildContext context) {
    final c = context.c;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: c.fond,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        Widget ligne(IconData i, String t, VoidCallback f, {Color? couleur}) => ListTile(
              leading: Icon(i, color: couleur ?? c.t2),
              title: Text(t, style: TextStyle(color: couleur ?? c.t1)),
              onTap: () {
                Navigator.pop(ctx);
                f();
              },
            );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!e.direct) ligne(Icons.play_circle_outline_rounded, 'Aperçu', () => _FeuilleApercu.ouvrir(context, e)),
            ligne(Icons.download_rounded, 'Télécharger', _ouvrir),
            ligne(Icons.not_interested_rounded, 'Pas intéressé', () {
              gouts.pasInteresse(e);
              toast(context, 'Compris, on en tiendra compte');
            }),
            if (e.chaine != null)
              ligne(Icons.block_rounded, 'Ne plus recommander « ${e.chaine} »', () {
                gouts.bloquerChaine(e);
                toast(context, 'Chaîne masquée des propositions');
              }, couleur: c.rouge),
          ]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Verre(
      padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
      rayon: 20,
      onTap: e.url == null ? null : _ouvrir,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: e.url == null || e.direct ? null : () => _FeuilleApercu.ouvrir(context, e),
          child: Stack(alignment: Alignment.center, children: [
            Miniature(e.miniature, largeur: 138, texteDuree: e.direct ? 'DIRECT' : formaterDuree(e.duree)),
            if (e.url != null && !e.direct)
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
              Text(e.chaine!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.t2, fontSize: 12)),
            Text([formaterVues(e.vues), ilYA(e.date)].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(color: c.t3, fontSize: 11.5)),
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
  const _FeuilleApercu(this.e);

  static void ouvrir(BuildContext context, analyse.Entree e) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: context.c.fond,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _FeuilleApercu(e),
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
          Text(e.chaine!, style: TextStyle(color: c.t2, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        BoutonGrad('Choisir la qualité et télécharger', icone: Icons.download_rounded, onTap: () {
          Navigator.of(context).pop();
          gouts.signalEntree('clic', e);
          ouvrirLien(e.url!);
        }),
      ]),
    );
  }
}
