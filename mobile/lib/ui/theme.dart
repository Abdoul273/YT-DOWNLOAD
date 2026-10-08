/// YT-NEXUS — « liquid glass » : verre dépoli sur aurore animée (comme l'interface web).
library;

import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class Couleurs extends ThemeExtension<Couleurs> {
  final Color fond, verre, verre2, verre3, trait, trait2, t1, t2, t3;
  final Color violet, indigo, bleu, cyan, rose, vert, ambre, rouge;
  final List<Color> aurore;
  final bool sombre;

  const Couleurs({
    required this.fond, required this.verre, required this.verre2, required this.verre3,
    required this.trait, required this.trait2, required this.t1, required this.t2, required this.t3,
    required this.violet, required this.indigo, required this.bleu, required this.cyan, required this.rose,
    required this.vert, required this.ambre, required this.rouge, required this.aurore, required this.sombre,
  });

  static const sombreC = Couleurs(
    fond: Color(0xFF05060D), verre: Color(0x0BFFFFFF), verre2: Color(0x13FFFFFF), verre3: Color(0x1CFFFFFF),
    trait: Color(0x14FFFFFF), trait2: Color(0x26FFFFFF),
    t1: Color(0xFFF4F5FB), t2: Color(0xFFA6ACC4), t3: Color(0xFF686F8C),
    violet: Color(0xFFA78BFA), indigo: Color(0xFF818CF8), bleu: Color(0xFF60A5FA), cyan: Color(0xFF22D3EE),
    rose: Color(0xFFF472B6), vert: Color(0xFF34D399), ambre: Color(0xFFFBBF24), rouge: Color(0xFFFB7185),
    aurore: [Color(0x577C3AED), Color(0x522563EB), Color(0x520891B2), Color(0x33DB2777)],
    sombre: true,
  );

  static const clairC = Couleurs(
    fond: Color(0xFFEEF0F8), verre: Color(0x8CFFFFFF), verre2: Color(0xB8FFFFFF), verre3: Color(0xE6FFFFFF),
    trait: Color(0x171E2350), trait2: Color(0x2E1E2350),
    t1: Color(0xFF12142A), t2: Color(0xFF4C5272), t3: Color(0xFF8A8FAB),
    violet: Color(0xFF7C3AED), indigo: Color(0xFF4F46E5), bleu: Color(0xFF2563EB), cyan: Color(0xFF0891B2),
    rose: Color(0xFFDB2777), vert: Color(0xFF059669), ambre: Color(0xFFB45309), rouge: Color(0xFFE11D48),
    aurore: [Color(0x73A78BFA), Color(0x6660A5FA), Color(0x4D22D3EE), Color(0x40F472B6)],
    sombre: false,
  );

  @override
  Couleurs copyWith() => this;

  @override
  Couleurs lerp(Couleurs? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension CouleursContexte on BuildContext {
  Couleurs get c => Theme.of(this).extension<Couleurs>()!;
}

const gradTexte = LinearGradient(colors: [Color(0xFFC4B5FD), Color(0xFF818CF8), Color(0xFF60A5FA), Color(0xFF22D3EE)]);
const gradBouton = LinearGradient(
  begin: Alignment(-1, -0.4),
  end: Alignment(1, 0.4),
  colors: [Color(0xFF7C3AED), Color(0xFF4F46E5), Color(0xFF2563EB), Color(0xFF0891B2)],
);
const gradVert = LinearGradient(colors: [Color(0xFF10B981), Color(0xFF22D3EE)]);

ThemeData construireTheme(bool sombre) {
  final c = sombre ? Couleurs.sombreC : Couleurs.clairC;
  final base = ThemeData(
    brightness: sombre ? Brightness.dark : Brightness.light,
    useMaterial3: true,
    fontFamily: 'PlusJakartaSans',
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.indigo,
      brightness: sombre ? Brightness.dark : Brightness.light,
      primary: c.indigo,
    ),
    scaffoldBackgroundColor: c.fond,
    extensions: [c],
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PlusJakartaSans', bodyColor: c.t1, displayColor: c.t1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: sombre ? const Color(0xFF1A1C2E) : Colors.white,
      contentTextStyle: TextStyle(color: c.t1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : c.t2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.indigo : c.verre3),
      trackOutlineColor: WidgetStateProperty.all(c.trait2),
    ),
  );
}

TextStyle mono(BuildContext context, {double taille = 12, Color? couleur, FontWeight poids = FontWeight.w600}) =>
    TextStyle(fontFamily: 'JetBrainsMono', fontSize: taille, color: couleur ?? context.c.t2, fontWeight: poids);

/// Fond : aurore de couleurs floues qui dérivent lentement.
///
/// Peinte directement (sans reconstruire de widgets) et limitée à ~20 images/s : le mouvement
/// est si lent que c'est invisible, mais le GPU et la batterie respirent. En pause quand l'app
/// est en arrière-plan ou que l'écran est recouvert (TickerMode).
class Aurore extends StatefulWidget {
  const Aurore({super.key});
  @override
  State<Aurore> createState() => _AuroreState();
}

class _AuroreState extends State<Aurore> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _periode = 40000; // ms pour un tour complet
  static const _intervalle = 50; // ms entre deux images
  final _phase = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tic);
  Duration _decalage = Duration.zero, _derniere = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker.start();
  }

  void _tic(Duration t) {
    if ((t - _derniere).inMilliseconds < _intervalle) return;
    _derniere = t;
    _phase.value = ((_decalage + t).inMilliseconds % _periode) / _periode;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState etat) {
    if (etat == AppLifecycleState.resumed) {
      if (!_ticker.isActive) {
        _derniere = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _decalage += _derniere;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RepaintBoundary(
      child: CustomPaint(painter: _PeintreAurore(_phase, c.fond, c.aurore), size: Size.infinite),
    );
  }
}

class _PeintreAurore extends CustomPainter {
  final ValueNotifier<double> phase;
  final Color fond;
  final List<Color> couleurs;
  _PeintreAurore(this.phase, this.fond, this.couleurs) : super(repaint: phase);

  @override
  void paint(Canvas canvas, Size taille) {
    canvas.drawRect(Offset.zero & taille, Paint()..color = fond);
    final t = phase.value * 2 * pi;
    void tache(int i, double x, double y, double r) {
      final centre = Offset(taille.width * x, taille.height * y);
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..shader = RadialGradient(colors: [couleurs[i], couleurs[i].withAlpha(0)])
              .createShader(Rect.fromCircle(center: centre, radius: r)),
      );
    }

    tache(0, 0.15 + 0.12 * sin(t), 0.12 + 0.06 * cos(t), taille.width * 0.75);
    tache(1, 0.9 + 0.1 * cos(t * 2), 0.3 + 0.08 * sin(t), taille.width * 0.7);
    tache(2, 0.3 + 0.15 * cos(t), 0.8 + 0.05 * sin(t * 2), taille.width * 0.8);
    tache(3, 0.85 + 0.08 * sin(t * 3), 0.9 + 0.04 * cos(t), taille.width * 0.55);
  }

  @override
  bool shouldRepaint(_PeintreAurore old) => old.fond != fond || old.couleurs != couleurs;
}

/// Panneau de verre dépoli.
///
/// Sur l'aurore (déjà floue) un vrai flou d'arrière-plan ne change rien à l'œil mais coûte
/// très cher : chaque panneau recalculait le flou de tout ce qui est derrière lui à chaque
/// image. Le flou n'est donc appliqué que si [flou] > 0 est demandé explicitement.
class Verre extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double rayon;
  final double flou;
  final Color? teinte;
  final VoidCallback? onTap;
  final Border? bordure;

  const Verre({
    super.key, required this.child, this.padding = const EdgeInsets.all(16), this.rayon = 24, this.flou = 0,
    this.teinte, this.onTap, this.bordure,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final br = BorderRadius.circular(rayon);
    final base = teinte ?? c.verre;
    Widget contenu = Padding(padding: padding, child: child);
    if (onTap != null) contenu = InkWell(onTap: onTap, borderRadius: br, child: contenu);
    Widget w = Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          border: bordure ?? Border.all(color: c.trait),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [base.withAlpha((base.a * 255 * 1.6).clamp(0, 255).round()), base],
          ),
        ),
        child: contenu,
      ),
    );
    if (flou > 0) {
      w = ClipRRect(
        borderRadius: br,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: flou, sigmaY: flou), child: w),
      );
    } else if (onTap != null) {
      w = ClipRRect(borderRadius: br, child: w); // garde l'effet d'appui dans les coins arrondis
    }
    return w;
  }
}

/// Bouton principal en dégradé.
class BoutonGrad extends StatelessWidget {
  final String texte;
  final IconData? icone;
  final VoidCallback? onTap;
  final bool charge;
  final Gradient gradient;
  const BoutonGrad(this.texte,
      {super.key, this.icone, this.onTap, this.charge = false, this.gradient = gradBouton});

  @override
  Widget build(BuildContext context) {
    final actif = onTap != null && !charge;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: actif || charge ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: const Color(0xFF6366F1).withAlpha(90), blurRadius: 24, offset: const Offset(0, 8), spreadRadius: -6)],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: actif ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (charge)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                else if (icone != null)
                  Icon(icone, color: Colors.white, size: 20),
                if (charge || icone != null) const SizedBox(width: 10),
                Flexible(
                  child: Text(texte,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bouton secondaire en verre.
class BoutonVerre extends StatelessWidget {
  final String? texte;
  final IconData icone;
  final VoidCallback? onTap;
  final Color? couleur;
  final String? aide;
  const BoutonVerre({super.key, this.texte, required this.icone, this.onTap, this.couleur, this.aide});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final w = Material(
      color: c.verre2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.trait)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: texte == null ? 10 : 14, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icone, size: 19, color: couleur ?? c.t1),
            if (texte != null) ...[
              const SizedBox(width: 8),
              Text(texte!, style: TextStyle(fontWeight: FontWeight.w600, color: couleur ?? c.t1, fontSize: 14)),
            ],
          ]),
        ),
      ),
    );
    return aide != null ? Tooltip(message: aide!, child: w) : w;
  }
}

/// Puce sélectionnable (langue, qualité, filtre…).
class Puce extends StatelessWidget {
  final String texte;
  final String? sous;
  final bool choisie;
  final VoidCallback? onTap;
  final String? badge;
  const Puce(this.texte, {super.key, this.sous, this.choisie = false, this.onTap, this.badge});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: choisie ? c.indigo.withAlpha(c.sombre ? 50 : 30) : c.verre2,
        border: Border.all(color: choisie ? c.indigo.withAlpha(200) : c.trait, width: choisie ? 1.4 : 1),
        boxShadow: choisie ? [BoxShadow(color: c.indigo.withAlpha(60), blurRadius: 16, spreadRadius: -4)] : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(texte, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: choisie ? c.t1 : c.t1)),
                if (badge != null && badge!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(gradient: gradBouton, borderRadius: BorderRadius.circular(6)),
                    child: Text(badge!, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
              if (sous != null) Text(sous!, style: mono(context, taille: 10.5, couleur: c.t3)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Titre de section en petites capitales.
class Etiquette extends StatelessWidget {
  final String texte;
  final Widget? fin;
  const Etiquette(this.texte, {super.key, this.fin});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Row(children: [
          Expanded(
            child: Text(texte.toUpperCase(),
                style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: context.c.t3)),
          ),
          ?fin,
        ]),
      );
}

/// Texte en dégradé (logo, titres).
class TexteGrad extends StatelessWidget {
  final String texte;
  final TextStyle style;
  const TexteGrad(this.texte, {super.key, required this.style});
  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => gradTexte.createShader(r),
        child: Text(texte, style: style.copyWith(color: Colors.white)),
      );
}

/// Miniature arrondie avec durée.
class Miniature extends StatelessWidget {
  final String? url;
  final int? duree;
  final double largeur;
  final double rayon;
  final String texteDuree;
  const Miniature(this.url, {super.key, this.duree, this.largeur = 120, this.rayon = 12, this.texteDuree = ''});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ClipRRect(
      borderRadius: BorderRadius.circular(rayon),
      child: SizedBox(
        width: largeur,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(fit: StackFit.expand, children: [
            Container(color: c.verre3),
            if (url != null)
              Image.network(
                url!,
                fit: BoxFit.cover,
                // Décodée à la taille affichée : YouTube sert souvent du 1280×720 pour une vignette de 112 px
                cacheWidth: ((largeur.isFinite ? largeur : MediaQuery.sizeOf(context).width) *
                        MediaQuery.devicePixelRatioOf(context))
                    .round(),
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                frameBuilder: (_, image, frame, synchrone) => synchrone
                    ? image
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        child: image,
                      ),
                errorBuilder: (_, _, _) => Icon(Icons.movie_outlined, color: c.t3),
              ),
            if (texteDuree.isNotEmpty)
              Positioned(
                right: 5,
                bottom: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(color: Colors.black.withAlpha(190), borderRadius: BorderRadius.circular(6)),
                  child: Text(texteDuree, style: mono(context, taille: 10, couleur: Colors.white)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

void toast(BuildContext context, String message, {bool erreur = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(erreur ? Icons.error_outline : Icons.check_circle_outline,
            color: erreur ? context.c.rouge : context.c.vert, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
    ));
}
