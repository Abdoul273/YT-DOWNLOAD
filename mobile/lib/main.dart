import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'moteur/gouts.dart';
import 'moteur/natif.dart';
import 'moteur/reglages.dart';
import 'moteur/taches.dart';
import 'ui/etat.dart';
import 'ui/fenetre_maj.dart';
import 'ui/page_fichiers.dart';
import 'ui/page_file.dart';
import 'ui/page_recherche.dart';
import 'ui/page_reglages.dart';
import 'ui/page_video.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const App());
}

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late Future<void> _demarrage = _demarrer();
  bool _ecoutePartages = false;

  void _reessayer() => setState(() => _demarrage = _demarrer());

  Future<void> _demarrer() async {
    await Natif.init();
    await reglages.charger();
    await gestionnaire.demarrer();
    await gouts.charger();
    Natif.demanderNotifications();
    final partage = await Natif.partageInitial();
    if (partage != null) ouvrirLien(partage);
    if (!_ecoutePartages) {
      _ecoutePartages = true;
      Natif.partages.listen(ouvrirLien);
    }
    _majAuto();
  }

  /// yt-dlp doit suivre YouTube : mise à jour silencieuse une fois par jour.
  Future<void> _majAuto() async {
    final maintenant = DateTime.now().millisecondsSinceEpoch;
    if (reglages['maj_auto'] != true || maintenant - (reglages['derniere_maj'] as num) < 86400000) return;
    try {
      await Natif.majYtdlp();
      reglages['derniere_maj'] = maintenant;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: reglages,
      builder: (context, _) {
        final sombre = reglages['theme'] != 'clair';
        return MaterialApp(
          title: 'YT-NEXUS',
          debugShowCheckedModeBanner: false,
          theme: construireTheme(sombre),
          home: AnnotatedRegion<SystemUiOverlayStyle>(
            value: (sombre ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            ),
            child: FutureBuilder(
              future: _demarrage,
              builder: (context, s) {
                if (s.hasError) return _Demarrage(erreur: '${s.error}', reessayer: _reessayer);
                if (s.connectionState != ConnectionState.done) return const _Demarrage();
                return const Accueil();
              },
            ),
          ),
        );
      },
    );
  }
}

class _Demarrage extends StatelessWidget {
  final String? erreur;
  final VoidCallback? reessayer;
  const _Demarrage({this.erreur, this.reessayer});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: Aurore()),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const _Logo(taille: 34),
              const SizedBox(height: 24),
              if (erreur == null) ...[
                SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.6, color: c.indigo)),
                const SizedBox(height: 16),
                Text('Préparation du moteur…', style: TextStyle(color: c.t2)),
                const SizedBox(height: 4),
                Text('Le premier lancement prend quelques secondes', style: TextStyle(color: c.t3, fontSize: 12)),
              ] else ...[
                Text('Impossible de démarrer yt-dlp :\n$erreur', textAlign: TextAlign.center, style: TextStyle(color: c.rouge)),
                const SizedBox(height: 20),
                FilledButton.icon(onPressed: reessayer, icon: const Icon(Icons.refresh), label: const Text('Réessayer')),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Logo extends StatelessWidget {
  final double taille;
  const _Logo({this.taille = 22});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: taille * 1.15,
          height: taille * 1.15,
          decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(taille * 0.34)),
          child: Icon(Icons.download_rounded, color: Colors.white, size: taille * 0.75),
        ),
        SizedBox(width: taille * 0.4),
        Text('YT-', style: TextStyle(fontSize: taille, fontWeight: FontWeight.w800, color: context.c.t1)),
        TexteGrad('NEXUS', style: TextStyle(fontSize: taille, fontWeight: FontWeight.w800)),
      ]);
}

class Accueil extends StatelessWidget {
  const Accueil({super.key});

  static const _pages = [PageVideo(), PageRecherche(), PageFile(), PageFichiers(), PageReglages()];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        if (onglet.value != 0) {
          onglet.value = 0;
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        extendBody: true,
        resizeToAvoidBottomInset: true,
        body: Stack(children: [
          const Positioned.fill(child: Aurore()),
          SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                child: Row(children: [
                  const _Logo(),
                  const Spacer(),
                  ListenableBuilder(
                    listenable: gestionnaire,
                    builder: (context, _) {
                      final d = gestionnaire.debit;
                      if (d <= 0) return const SizedBox();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                            color: c.vert.withAlpha(30),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: c.vert.withAlpha(80))),
                        child: Row(children: [
                          Icon(Icons.south_rounded, size: 14, color: c.vert),
                          const SizedBox(width: 4),
                          Text('${formaterTaille(d)}/s', style: mono(context, taille: 11.5, couleur: c.vert)),
                        ]),
                      );
                    },
                  ),
                  const BoutonMaj(),
                  IconButton(
                    tooltip: 'Thème',
                    onPressed: () => reglages['theme'] = c.sombre ? 'clair' : 'sombre',
                    icon: Icon(c.sombre ? Icons.dark_mode_outlined : Icons.light_mode_outlined, color: c.t2),
                  ),
                ]),
              ),
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: onglet,
                  builder: (context, i, _) => IndexedStack(index: i, children: _pages),
                ),
              ),
            ]),
          ),
        ]),
        bottomNavigationBar: const _Navigation(),
      ),
    );
  }
}

class _Navigation extends StatelessWidget {
  const _Navigation();

  static const _items = [
    (Icons.play_circle_outline_rounded, Icons.play_circle_rounded, 'Vidéo'),
    (Icons.search_rounded, Icons.search_rounded, 'Recherche'),
    (Icons.downloading_outlined, Icons.downloading_rounded, 'En cours'),
    (Icons.folder_outlined, Icons.folder_rounded, 'Fichiers'),
    (Icons.tune_outlined, Icons.tune_rounded, 'Réglages'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bas = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bas + 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: c.sombre ? const Color(0xB30E1020) : const Color(0xC7FFFFFF),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: c.trait2),
            ),
            child: ValueListenableBuilder(
              valueListenable: onglet,
              builder: (context, actuel, _) => LayoutBuilder(builder: (context, cs) {
                final l = cs.maxWidth / _items.length;
                return Stack(children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutBack,
                    left: l * actuel + 6,
                    top: 6,
                    bottom: 6,
                    width: l - 12,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        color: c.indigo.withAlpha(c.sombre ? 45 : 28),
                        border: Border.all(color: c.indigo.withAlpha(110)),
                      ),
                    ),
                  ),
                  Row(children: [
                    for (var i = 0; i < _items.length; i++)
                      Expanded(
                        child: InkResponse(
                          onTap: () => onglet.value = i,
                          radius: 36,
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            ListenableBuilder(
                              listenable: gestionnaire,
                              builder: (_, _) => Badge(
                                isLabelVisible: i == 2 && gestionnaire.nbActifs > 0,
                                backgroundColor: c.indigo,
                                label: Text('${gestionnaire.nbActifs}'),
                                child: Icon(actuel == i ? _items[i].$2 : _items[i].$1,
                                    color: actuel == i ? c.t1 : c.t3, size: 24),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(_items[i].$3,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: actuel == i ? FontWeight.w700 : FontWeight.w500,
                                    color: actuel == i ? c.t1 : c.t3)),
                          ]),
                        ),
                      ),
                  ]),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

