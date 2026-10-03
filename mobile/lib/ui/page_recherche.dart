/// Onglet Recherche : recherche YouTube avec tri et filtres.
library;

import 'package:flutter/material.dart';

import '../moteur/analyse.dart' as analyse;
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
  final _filtres = analyse.Filtres();
  List<analyse.Entree>? _resultats;
  String? _erreur;
  bool _charge = false, _filtresOuverts = false;
  int _jeton = 0;

  @override
  void dispose() {
    _champ.dispose();
    super.dispose();
  }

  Future<void> _chercher() async {
    final q = _champ.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    // Un lien collé ici part directement dans l'onglet Vidéo
    if (extraireLiens(q).isNotEmpty) return ouvrirLien(q);
    final jeton = ++_jeton;
    setState(() {
      _charge = true;
      _erreur = null;
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final f = _filtres;
    return CustomScrollView(
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
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _chercher(),
                      style: TextStyle(color: c.t1),
                      decoration: InputDecoration(
                        hintText: 'Rechercher sur YouTube',
                        hintStyle: TextStyle(color: c.t3),
                        prefixIcon: Icon(Icons.search_rounded, color: c.t3),
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
        if (_charge)
          const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))
        else if (_erreur != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_erreur!, textAlign: TextAlign.center, style: TextStyle(color: c.rouge)),
            ),
          )
        else if (_resultats == null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.travel_explore_rounded, size: 52, color: c.t3),
                const SizedBox(height: 10),
                Text("Cherche une vidéo : ▶ pour l'aperçu,\ntouche-la pour choisir la piste et la qualité.",
                    textAlign: TextAlign.center, style: TextStyle(color: c.t3)),
                const SizedBox(height: 80),
              ]),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 120 + MediaQuery.paddingOf(context).bottom),
            sliver: SliverList.separated(
              itemCount: _resultats!.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _Resultat(_resultats![i]),
            ),
          ),
      ],
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Verre(
      padding: const EdgeInsets.all(10),
      rayon: 20,
      onTap: e.url == null ? null : () => ouvrirLien(e.url!),
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
        Icon(Icons.chevron_right_rounded, color: c.t3),
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
          ouvrirLien(e.url!);
        }),
      ]),
    );
  }
}
