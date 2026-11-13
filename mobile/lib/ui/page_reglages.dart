/// Onglet Réglages : centre de contrôle Liquid Glass organisé par catégories,
/// avec tableau de bord, recherche instantanée et sous-sections claires.
library;

import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/gouts.dart';
import '../moteur/langues.dart' as langues;
import '../moteur/maj.dart';
import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'etat.dart';
import 'fenetre_maj.dart';
import 'theme.dart';
import 'verrou.dart';

Future<bool> modifierCookies(BuildContext context) async {
  final texte = reglages.aDesCookies ? await reglages.fichierCookies.readAsString().catchError((_) => '') : '';
  if (!context.mounted) return false;
  final c = context.c;
  final ctrl = TextEditingController(text: texte);
  final ok = await showModalBottomSheet<bool>(
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
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                Text('Cookies YouTube', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c.t1)),
                const SizedBox(height: 6),
                Text(
                  'Si YouTube demande de prouver que tu n’es pas un robot, ou pour les vidéos réservées aux adultes/membres : '
                  'exporte tes cookies au format Netscape (extension « Get cookies.txt LOCALLY » sur PC) et colle-les ici.',
                  style: TextStyle(color: c.t2, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  maxLines: 8,
                  style: mono(ctx, taille: 11, couleur: c.t1, poids: FontWeight.w500),
                  decoration: InputDecoration(
                    hintText: '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\t…',
                    hintStyle: mono(ctx, taille: 11, couleur: c.t3, poids: FontWeight.w500),
                    filled: true,
                    fillColor: c.verre2,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  BoutonVerre(
                    icone: Icons.delete_outline_rounded,
                    texte: 'Effacer',
                    onTap: () {
                      ctrl.clear();
                      Navigator.pop(ctx, true);
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: BoutonGrad('Enregistrer', icone: Icons.check_rounded, onTap: () => Navigator.pop(ctx, true))),
                ]),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
  final contenu = ctrl.text;
  if (ok == true) {
    await reglages.enregistrerCookies(contenu);
    if (context.mounted) toast(context, contenu.trim().isEmpty ? 'Cookies effacés' : 'Cookies enregistrés');
  }
  return ok == true && contenu.trim().isNotEmpty;
}

class PageReglages extends StatefulWidget {
  const PageReglages({super.key});
  @override
  State<PageReglages> createState() => _PageReglagesState();
}

enum _Categorie { tout, medias, reseau, lecteur, systeme }

class _PageReglagesState extends State<PageReglages> {
  static const _categories = [
    (_Categorie.tout, 'Tout', Icons.apps_rounded),
    (_Categorie.medias, 'Médias', Icons.high_quality_rounded),
    (_Categorie.reseau, 'Réseau & File', Icons.wifi_rounded),
    (_Categorie.lecteur, 'Lecteur', Icons.play_circle_outline_rounded),
    (_Categorie.systeme, 'Système', Icons.shield_outlined),
  ];

  bool _maj = false;
  int? _temporaires;
  _Categorie _categorie = _Categorie.tout;
  String _recherche = '';
  final _ctrlRecherche = TextEditingController();

  @override
  void initState() {
    super.initState();
    onglet.addListener(_ongletChange);
  }

  @override
  void dispose() {
    onglet.removeListener(_ongletChange);
    _ctrlRecherche.dispose();
    super.dispose();
  }

  void _ongletChange() {
    if (onglet.value == 4) _mesurerTemporaires();
  }

  Future<void> _mesurerTemporaires() async {
    final n = await gestionnaire.tailleTemporairesAsync();
    if (mounted && n != _temporaires) setState(() => _temporaires = n);
  }

  Future<void> _mettreAJour({bool nightly = false}) async {
    setState(() => _maj = true);
    try {
      final (statut, version) = await Natif.majYtdlp(nightly: nightly);
      reglages['derniere_maj'] = DateTime.now().millisecondsSinceEpoch;
      if (mounted) toast(context, statut == 'DONE' ? 'yt-dlp mis à jour : $version' : 'yt-dlp est à jour ($version)');
    } catch (e) {
      if (mounted) toast(context, 'Mise à jour impossible : $e', erreur: true);
    } finally {
      if (mounted) setState(() => _maj = false);
    }
  }

  Future<void> _choisirHeure(String cle) async {
    final m = (reglages[cle] as num).toInt();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      builder: (ctx, w) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: w!,
      ),
    );
    if (t != null) reglages[cle] = t.hour * 60 + t.minute;
  }

  Future<void> _code() async {
    if (verrouActif) {
      final action = await showModalBottomSheet<String>(
        context: context,
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
                  top: BorderSide(color: ctx.c.sombre ? ctx.c.indigo.withAlpha(85) : ctx.c.indigo.withAlpha(50), width: 1.2),
                  left: BorderSide(color: ctx.c.trait),
                  right: BorderSide(color: ctx.c.trait),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    ListTile(
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: ctx.c.indigo.withAlpha(30), borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.edit_rounded, color: ctx.c.indigo, size: 20),
                      ),
                      title: Text('Changer le code', style: TextStyle(fontWeight: FontWeight.w700, color: ctx.c.t1)),
                      onTap: () => Navigator.pop(ctx, 'changer'),
                    ),
                    ListTile(
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: ctx.c.rouge.withAlpha(30), borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.lock_open_rounded, color: ctx.c.rouge, size: 20),
                      ),
                      title: Text('Désactiver le verrouillage', style: TextStyle(fontWeight: FontWeight.w700, color: ctx.c.rouge)),
                      onTap: () => Navigator.pop(ctx, 'off'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
      if (action == 'off') {
        definirCode(null);
        if (mounted) toast(context, 'Verrouillage désactivé');
        return;
      }
      if (action != 'changer') return;
    }
    if (!mounted) return;
    final code = await demanderNouveauCode(context);
    if (code == null) return;
    definirCode(code);
    if (mounted) toast(context, 'Code enregistré : demandé au lancement et après 20 s hors de l’app');
  }

  Future<void> _viderTemporaires() async {
    final n = gestionnaire.viderTemporaires();
    setState(() => _temporaires = 0);
    toast(context, n > 0 ? '${formaterTaille(n)} libérés' : 'Rien à nettoyer');
  }

  Future<void> _effacerHistorique() async {
    final c = context.c;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Effacer l’historique ?'),
        content: const Text('Les recherches mémorisées et préférences de recommandations seront supprimées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Effacer', style: TextStyle(color: c.rouge, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok == true) {
      gouts.effacer();
      if (mounted) toast(context, 'Historique effacé');
    }
  }

  Future<void> _reinitialiserDefauts() async {
    final c = context.c;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.sombre ? const Color(0xFF14162A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Réinitialiser les réglages ?'),
        content: const Text('Les réglages par défaut seront restaurés. Ton code PIN, tes favoris et tes fichiers sont conservés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Réinitialiser', style: TextStyle(color: c.ambre, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    const garder = {'pin_hash', 'pin_sel', 'favoris', 'derniere_maj', 'dernier_lien_propose', 'tri_fichiers'};
    for (final e in reglagesDefaut.entries) {
      if (!garder.contains(e.key)) {
        reglages.ecrireSansPrevenir(e.key, e.value is List ? List.of(e.value as List) : e.value);
      }
    }
    reglages['theme'] = reglagesDefaut['theme'];
    if (mounted) toast(context, 'Réglages remis par défaut');
  }

  Future<void> _exporter() async {
    final copie = Map<String, dynamic>.of(reglages.tout)
      ..removeWhere((k, _) => const ['pin_hash', 'pin_sel', 'derniere_maj', 'dernier_lien_propose'].contains(k));
    await Clipboard.setData(ClipboardData(text: jsonEncode({'yt_nexus': 1, 'reglages': copie})));
    if (mounted) toast(context, 'Sauvegarde copiée : colle-la dans une note ou un message');
  }

  Future<void> _importer() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final donnees = jsonDecode(d?.text ?? '') as Map;
      if (donnees['yt_nexus'] == null) throw const FormatException();
      var n = 0;
      for (final e in (donnees['reglages'] as Map).entries) {
        if (reglagesDefaut.containsKey(e.key) && !const ['pin_hash', 'pin_sel'].contains(e.key)) {
          reglages.ecrireSansPrevenir('${e.key}', e.value);
          n++;
        }
      }
      reglages['theme'] = reglages['theme'];
      if (mounted) toast(context, 'Sauvegarde restaurée ($n réglages, favoris, positions de lecture)');
    } catch (_) {
      if (mounted) toast(context, 'Le presse-papiers ne contient pas de sauvegarde YT-NEXUS', erreur: true);
    }
  }

  Future<void> _rapport() async {
    await Clipboard.setData(ClipboardData(text: gestionnaire.rapport()));
    if (mounted) toast(context, 'Rapport copié : colle-le pour signaler un problème');
  }

  bool _correspond(String motsCles) {
    final q = _recherche.trim().toLowerCase();
    if (q.isEmpty) return true;
    return motsCles.toLowerCase().contains(q);
  }

  bool _visible(_Categorie cat, String motsCles) {
    if (_recherche.trim().isNotEmpty) return _correspond(motsCles);
    return _categorie == _Categorie.tout || _categorie == cat;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: Listenable.merge([reglages, gestionnaire, maj]),
      builder: (context, _) {
        final r = reglages;
        final enRecherche = _recherche.trim().isNotEmpty;
        final termines = gestionnaire.taches.where((t) => t.statut == 'termine').toList();
        final poidsTotal = termines.fold(0, (a, t) => a + t.tailleFichier);
        final qualiteLib = switch (r['qualite']) {
          'best' => 'Max',
          '2160' => '4K',
          '1440' => '2K',
          final q => '${q}p',
        };
        final resumeMedias = r['type'] == 'audio'
            ? '${'${r['format_audio']}'.toUpperCase()} · ${r['langue_audio'] == 'original' ? 'VO' : '${r['langue_audio']}'.toUpperCase()}'
            : '$qualiteLib ${'${r['conteneur']}'.toUpperCase()} · ${r['langue_audio'] == 'original' ? 'VO' : '${r['langue_audio']}'.toUpperCase()}';
        final resumeReseau = '${r['simultanes']} sim.${r['wifi_seulement'] == true ? ' · Wi-Fi' : ''}${r['eco_donnees'] == true ? ' · Éco' : ''}';
        final resumeLecteur = '${(r['lecteur_saut'] as num?)?.toInt() ?? 10} s${r['pip_auto'] == true ? ' · PiP' : ''}';

        Widget inter(String cle, IconData ic, Color col, String titre, String sous) => _Ligne(
              icone: ic,
              couleur: col,
              titre: titre,
              sous: sous,
              fin: Switch(value: r[cle] == true, onChanged: (v) => r[cle] = v),
              onTap: () => r[cle] = r[cle] != true,
            );

        final widgets = <Widget>[];
        void ajouterSection(Widget w) {
          if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 14));
          widgets.add(w);
        }

        // 1. APPARENCE & CONFORT
        const cleApparence =
            'theme sombre clair apparence couleur nuit cristal lien copie presse papiers detecte auto notification fin telechargement';
        if (_visible(_Categorie.systeme, cleApparence)) {
          final lignes = <Widget>[
            if (!enRecherche || _correspond('theme sombre clair apparence couleur nuit cristal'))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _SousEtiquette('Thème de l’interface'),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _ChoixSegment(
                        icone: Icons.dark_mode_rounded,
                        titre: 'Sombre',
                        sous: 'Nuit Aurore',
                        actif: c.sombre,
                        couleur: c.indigo,
                        onTap: () => r['theme'] = 'sombre',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ChoixSegment(
                        icone: Icons.light_mode_rounded,
                        titre: 'Clair',
                        sous: 'Cristal pur',
                        actif: !c.sombre,
                        couleur: c.ambre,
                        onTap: () => r['theme'] = 'clair',
                      ),
                    ),
                  ]),
                ]),
              ),
            if (!enRecherche || _correspond('lien copie presse papiers detecte auto'))
              inter('presse_papiers_auto', Icons.content_paste_go_rounded, c.cyan, 'Détection du presse-papiers',
                  'Propose d’analyser un lien YouTube copié à l’ouverture'),
            if (!enRecherche || _correspond('notification fin telechargement'))
              inter('notifications', Icons.notifications_active_outlined, c.bleu, 'Notifications de fin',
                  'Avertit dès qu’un téléchargement est prêt'),
          ];
          if (lignes.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.palette_outlined,
              couleur: c.violet,
              titre: 'Apparence & Confort',
              resume: c.sombre ? 'Sombre' : 'Clair',
              enfants: lignes,
            ));
          }
        }

        // 2. MÉDIAS (AUDIO, VIDÉO & QUALITÉ PAR DÉFAUT)
        const cleMedias =
            'piste audio langue francais vo original doublage sous titres secours par defaut video audio qualite 4k 2k 1080 720 mp4 mkv webm mp3 m4a opus flac wav vbr bitrate tiktok reels compatible sponsorblock miniature chapitre paroles dossier playlist';
        if (_visible(_Categorie.medias, cleMedias)) {
          final sousBlocs = <Widget>[];

          // Langue & Doublage
          if (!enRecherche || _correspond('piste audio langue francais vo original doublage sous titres secours')) {
            sousBlocs.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _SousEtiquette('Langue & Doublage'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final code in langues.languesCourantes)
                  Puce('${langues.drapeau(code)} ${langues.nom(code)}',
                      choisie: r['langue_audio'] == code, onTap: () => r['langue_audio'] = code),
                Puce('🌐 VO seule', choisie: r['langue_audio'] == 'original', onTap: () => r['langue_audio'] = 'original'),
              ]),
              const SizedBox(height: 8),
              inter('garder_vo', Icons.translate_rounded, c.indigo, 'Garder la VO en 2ᵉ piste',
                  'Doublage en priorité, VO sélectionnable dans le lecteur'),
              inter('sous_titres_secours', Icons.closed_caption_rounded, c.cyan, 'Sous-titres de secours',
                  'Sans doublage disponible → VO + sous-titres dans ta langue'),
            ]));
          }

          // Mode & Qualités Video/Audio
          if (!enRecherche || _correspond('video audio qualite 4k 2k 1080 720 mp4 mkv webm mp3 m4a opus flac wav vbr bitrate')) {
            sousBlocs.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _SousEtiquette('Profil de téléchargement'),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: _ChoixSegment(
                    icone: Icons.movie_creation_outlined,
                    titre: 'Vidéo',
                    sous: '$qualiteLib · ${'${r['conteneur']}'.toUpperCase()}',
                    actif: r['type'] == 'video',
                    couleur: c.indigo,
                    onTap: () => r['type'] = 'video',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ChoixSegment(
                    icone: Icons.headphones_rounded,
                    titre: 'Audio seul',
                    sous: '${r['format_audio']}'.toUpperCase(),
                    actif: r['type'] == 'audio',
                    couleur: c.rose,
                    onTap: () => r['type'] = 'audio',
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Text('Qualité vidéo', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (k, l) in const [('best', 'Max'), ('2160', '4K'), ('1440', '2K'), ('1080', '1080p'), ('720', '720p'), ('480', '480p'), ('360', '360p')])
                  Puce(l, choisie: r['qualite'] == k, onTap: () => r['qualite'] = k),
              ]),
              const SizedBox(height: 12),
              Text('Conteneur vidéo', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in const ['mp4', 'mkv', 'webm'])
                  Puce(k.toUpperCase(), choisie: r['conteneur'] == k, onTap: () => r['conteneur'] = k),
              ]),
              const SizedBox(height: 12),
              Text('Format & qualité audio', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in const ['mp3', 'm4a', 'opus', 'flac', 'wav', 'original'])
                  Puce(k == 'original' ? 'Original' : k.toUpperCase(),
                      choisie: r['format_audio'] == k, onTap: () => r['format_audio'] = k),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (k, l) in const [('0', 'VBR Max'), ('320K', '320k'), ('256K', '256k'), ('192K', '192k'), ('128K', '128k')])
                  Puce(l, choisie: '${r['qualite_audio']}' == k, onTap: () => r['qualite_audio'] = k),
              ]),
            ]));
          }

          // Traitements & Options
          if (!enRecherche || _correspond('compatible tiktok reels youtube sponsorblock miniature chapitres paroles dossier playlist')) {
            sousBlocs.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _SousEtiquette('Compatibilité & Enrichissement'),
              const SizedBox(height: 4),
              inter('compatible', Icons.verified_rounded, c.vert, 'Prête à publier (TikTok, Reels)',
                  'MP4 H.264 + AAC, 1 piste audio, 1080p max sans erreur de codec'),
              inter('sponsorblock', Icons.fast_forward_rounded, c.ambre, 'SponsorBlock automatique',
                  'Coupe les intros, sponsors et rappels d’abonnement'),
              inter('miniature', Icons.image_outlined, c.bleu, 'Miniature intégrée',
                  'Ajoute la pochette dans le fichier (hors mode TikTok)'),
              inter('metadonnees', Icons.label_outline_rounded, c.violet, 'Métadonnées et chapitres',
                  'Intègre titre, chaîne, date et chapitres au fichier'),
              inter('paroles_audio', Icons.lyrics_outlined, c.rose, 'Paroles en mode audio (.srt)',
                  'Télécharge les sous-titres pour le karaoké Onde Studio'),
              inter('sous_dossier_playlist', Icons.create_new_folder_outlined, c.cyan, 'Un dossier par playlist',
                  'Range dans Téléchargements/YT-NEXUS/<playlist>'),
            ]));
          }

          if (sousBlocs.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.high_quality_rounded,
              couleur: c.indigo,
              titre: 'Médias & Qualité par défaut',
              resume: resumeMedias,
              enfants: sousBlocs,
            ));
          }
        }

        // 3. RÉSEAU, FILE & PLANIFICATION
        const cleReseau =
            'file telechargements simultanes fragments connexions tentatives relances coupure 403 erreur vitesse debit limite bande passante wifi wi-fi seulement uniquement donnees mobiles eco economie 240 360 480 720 plage horaire nuit heure debut fin';
        if (_visible(_Categorie.reseau, cleReseau)) {
          final lignes = <Widget>[];
          if (!enRecherche || _correspond('simultanes parallele batterie')) {
            lignes.add(_Ligne(
              icone: Icons.layers_rounded,
              couleur: c.indigo,
              titre: 'Téléchargements simultanés',
              sous: 'Plus = plus rapide, mais sollicite davantage le téléphone',
              fin: _Compteur(r['simultanes'], 1, 5, (v) => r['simultanes'] = v),
            ));
          }
          if (!enRecherche || _correspond('fragments connexions parallele')) {
            lignes.add(_Ligne(
              icone: Icons.bolt_rounded,
              couleur: c.cyan,
              titre: 'Connexions par fichier',
              sous: 'Fragments téléchargés en parallèle par vidéo',
              fin: _Compteur(r['fragments'], 1, 16, (v) => r['fragments'] = v),
            ));
          }
          if (!enRecherche || _correspond('tentatives relances coupure 403 erreur')) {
            lignes.add(_Ligne(
              icone: Icons.replay_rounded,
              couleur: c.ambre,
              titre: 'Nouvelles tentatives',
              sous: 'Relance automatique après coupure réseau ou erreur 403',
              fin: _Compteur(r['relances'], 0, 10, (v) => r['relances'] = v),
            ));
          }
          if (!enRecherche || _correspond('limite vitesse debit bande passante')) {
            lignes.add(Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _SousEtiquette('Plafond de vitesse'),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (k, l) in const [('', 'Illimitée'), ('5M', '5 Mo/s'), ('2M', '2 Mo/s'), ('1M', '1 Mo/s'), ('500K', '500 Ko/s')])
                    Puce(l, choisie: '${r['limite_vitesse']}' == k, onTap: () => r['limite_vitesse'] = k),
                ]),
              ]),
            ));
          }
          if (!enRecherche || _correspond('wifi wi-fi seulement uniquement donnees mobiles')) {
            lignes.add(inter('wifi_seulement', Icons.wifi_rounded, c.bleu, 'Wi-Fi uniquement',
                'Met en attente sur 4G/5G pour ne pas consommer le forfait'));
          }
          if (!enRecherche || _correspond('eco economie donnees mobiles 240 360 480 720')) {
            lignes.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              inter('eco_donnees', Icons.data_saver_on_rounded, c.vert, 'Économie de données mobiles',
                  'Plafonne la qualité vidéo automatiquement hors Wi-Fi'),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: r['eco_donnees'] == true
                    ? Padding(
                        padding: const EdgeInsets.only(left: 48, bottom: 8, top: 2),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final q in const ['240', '360', '480', '720'])
                            Puce('${q}p max', choisie: r['eco_qualite'] == q, onTap: () => r['eco_qualite'] = q),
                        ]),
                      )
                    : const SizedBox.shrink(),
              ),
            ]));
          }
          if (!enRecherche || _correspond('plage horaire nuit heure debut fin')) {
            lignes.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              inter('plage_active', Icons.nightlight_outlined, c.violet, 'Plage horaire programmée',
                  'Télécharge uniquement pendant ce créneau (ex. la nuit)'),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: r['plage_active'] == true
                    ? Padding(
                        padding: const EdgeInsets.only(left: 48, bottom: 8, top: 4),
                        child: Row(children: [
                          Expanded(
                            child: BoutonVerre(
                              icone: Icons.schedule_rounded,
                              texte: 'Début ${Gestionnaire.heure((r['plage_debut'] as num).toInt())}',
                              onTap: () => _choisirHeure('plage_debut'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: BoutonVerre(
                              icone: Icons.schedule_send_rounded,
                              texte: 'Fin ${Gestionnaire.heure((r['plage_fin'] as num).toInt())}',
                              onTap: () => _choisirHeure('plage_fin'),
                            ),
                          ),
                        ]),
                      )
                    : const SizedBox.shrink(),
              ),
            ]));
          }
          if (lignes.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.speed_rounded,
              couleur: c.cyan,
              titre: 'Réseau & File de téléchargement',
              resume: resumeReseau,
              enfants: lignes,
            ));
          }
        }

        // 4. LECTEUR VIDÉO & AUDIO
        const cleLecteur =
            'lecteur pip image dans image auto suivant enchainer reprendre position gestes luminosite volume saut secondes orientation portrait paysage rotation sous titres vitesse maintien appui long';
        if (_visible(_Categorie.lecteur, cleLecteur)) {
          final lignes = <Widget>[
            if (!enRecherche || _correspond('pip image dans image fenetre flottante'))
              inter('pip_auto', Icons.picture_in_picture_alt_rounded, c.indigo, 'Image dans l’image (PiP)',
                  'Réduit la vidéo en mini-fenêtre quand tu quittes l’app'),
            if (!enRecherche || _correspond('enchainer suivant auto lecture automatique'))
              inter('lecteur_auto', Icons.playlist_play_rounded, c.cyan, 'Enchaîner le suivant',
                  'Lance la vidéo suivante après un court décompte'),
            if (!enRecherche || _correspond('reprendre position memoire'))
              inter('lecteur_reprendre', Icons.history_rounded, c.vert, 'Reprendre la position',
                  'Reprend exactement là où tu as arrêté la vidéo'),
            if (!enRecherche || _correspond('gestes tactiles luminosite volume recherche'))
              inter('lecteur_gestes', Icons.touch_app_rounded, c.violet, 'Gestes tactiles',
                  'Glisser verticalement (luminosité / volume) et horizontalement'),
            if (!enRecherche || _correspond('sous titres defaut afficher'))
              inter('lecteur_st', Icons.closed_caption_rounded, c.bleu, 'Sous-titres activés par défaut',
                  'Affiche les sous-titres dès qu’une piste locale existe'),
            if (!enRecherche || _correspond('duree saut avance recul 5 10 15 30'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _SousEtiquette('Durée des sauts (double appui)'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in const [5, 10, 15, 30])
                      Puce('$s s', choisie: (r['lecteur_saut'] as num?)?.toInt() == s, onTap: () => r['lecteur_saut'] = s),
                  ]),
                ]),
              ),
            if (!enRecherche || _correspond('vitesse maintien appui long 1.5 2 2.5 3'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _SousEtiquette('Vitesse en appui maintenu'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final v in const [1.5, 2.0, 2.5, 3.0])
                      Puce('${'$v'.replaceAll('.0', '')}×',
                          choisie: (((r['lecteur_vitesse_maintien'] as num?)?.toDouble() ?? 2.0) - v).abs() < 0.05,
                          onTap: () => r['lecteur_vitesse_maintien'] = v),
                  ]),
                ]),
              ),
            if (!enRecherche || _correspond('orientation rotation auto portrait paysage deux sens'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _SousEtiquette('Orientation par défaut'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final (v, label) in const [(0, 'Automatique'), (1, 'Portrait'), (2, 'Paysage · 2 sens')])
                      Puce(label,
                          choisie: ((r['lecteur_orientation'] as num?)?.toInt() ?? 0) == v,
                          onTap: () => r['lecteur_orientation'] = v),
                  ]),
                ]),
              ),
          ];
          if (lignes.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.smart_display_rounded,
              couleur: c.rose,
              titre: 'Lecteur vidéo & gestes',
              resume: resumeLecteur,
              enfants: lignes,
            ));
          }
        }

        // 5. SYSTÈME : MOTEUR YT-DLP, SÉCURITÉ, STOCKAGE & SAUVEGARDE
        const cleSysteme =
            'yt-dlp moteur nightly mise a jour cookies youtube securite verrouillage pin code stockage fichiers temporaires nettoyer sauvegarde exporter restaurer rapport erreurs historique recommandations reinitialiser';
        if (_visible(_Categorie.systeme, cleSysteme)) {
          final lignesMoteur = <Widget>[
            if (!enRecherche || _correspond('yt-dlp moteur mise a jour stable'))
              _Ligne(
                icone: Icons.terminal_rounded,
                couleur: c.indigo,
                titre: 'Moteur yt-dlp ${Natif.version}',
                sous: 'À mettre à jour si YouTube bloque une extraction',
                fin: _maj
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                      )
                    : BoutonVerre(icone: Icons.system_update_alt_rounded, texte: 'MAJ', onTap: _mettreAJour),
              ),
            if (!enRecherche || _correspond('mise a jour automatique lancement yt-dlp'))
              inter('maj_auto', Icons.autorenew_rounded, c.bleu, 'Mise à jour auto de yt-dlp',
                  'Vérifie discrètement une fois par jour au lancement'),
            if (!enRecherche || _correspond('nightly developpement instable'))
              _Ligne(
                icone: Icons.science_outlined,
                couleur: c.violet,
                titre: 'Branche Nightly',
                sous: 'Correctifs tout récents si la version stable échoue',
                fin: BoutonVerre(
                  icone: Icons.download_rounded,
                  texte: 'Tester',
                  onTap: _maj ? null : () => _mettreAJour(nightly: true),
                ),
              ),
            if (!enRecherche || _correspond('cookies youtube connexion robot age membres'))
              _Ligne(
                icone: Icons.cookie_outlined,
                couleur: reglages.aDesCookies ? c.vert : c.ambre,
                titre: 'Cookies YouTube',
                sous: reglages.aDesCookies ? 'Cookies enregistrés et actifs' : 'Utile si YouTube exige une connexion',
                fin: _PastilleEtat(
                  texte: reglages.aDesCookies ? 'Actifs' : 'Configurer',
                  couleur: reglages.aDesCookies ? c.vert : c.t3,
                ),
                onTap: () => modifierCookies(context),
              ),
            if (!enRecherche || _correspond('application app mise a jour version nouvelle'))
              _Ligne(
                icone: Icons.system_update_rounded,
                couleur: maj.dispo != null ? c.vert : c.cyan,
                titre: 'YT-NEXUS ${Natif.versionApp}',
                sous: maj.dispo != null ? 'Version ${maj.dispo!.version} prête à installer' : 'Rechercher une nouvelle version',
                fin: _PastilleEtat(
                  texte: maj.dispo != null ? 'Dispo' : 'Vérifier',
                  couleur: maj.dispo != null ? c.vert : c.t3,
                ),
                onTap: () {
                  if (maj.dispo == null) maj.verifier(force: true);
                  ouvrirFenetreMaj(context);
                },
              ),
          ];

          if (lignesMoteur.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.memory_rounded,
              couleur: c.indigo,
              titre: 'Moteur & Mises à jour',
              resume: Natif.versionApp,
              enfants: lignesMoteur,
            ));
          }

          final lignesSecu = <Widget>[
            if (!enRecherche || _correspond('verrouillage code pin securite priver'))
              _Ligne(
                icone: verrouActif ? Icons.lock_rounded : Icons.lock_open_rounded,
                couleur: verrouActif ? c.vert : c.indigo,
                titre: 'Verrouillage par code PIN',
                sous: verrouActif ? 'Protégé après 20 s hors de l’app' : 'Protège l’accès (4 à 6 chiffres)',
                fin: _PastilleEtat(
                  texte: verrouActif ? 'Protégé' : 'Désactivé',
                  couleur: verrouActif ? c.vert : c.t3,
                ),
                onTap: _code,
              ),
            if (!enRecherche || _correspond('fichiers temporaires cache nettoyer liberer'))
              _Ligne(
                icone: Icons.cleaning_services_rounded,
                couleur: (_temporaires ?? 0) > 0 ? c.ambre : c.cyan,
                titre: 'Fichiers temporaires',
                sous: _temporaires == null
                    ? 'Calcul en cours…'
                    : _temporaires! > 0
                        ? '${formaterTaille(_temporaires!)} de restes à nettoyer'
                        : 'Espace propre, rien à nettoyer',
                fin: (_temporaires ?? 0) > 0
                    ? _PastilleEtat(texte: 'Nettoyer', couleur: c.ambre)
                    : Icon(Icons.check_circle_outline_rounded, color: c.vert, size: 20),
                onTap: _viderTemporaires,
              ),
            if (!enRecherche || _correspond('recommandations gouts historique recherche effacer'))
              _Ligne(
                icone: Icons.delete_sweep_outlined,
                couleur: c.rose,
                titre: 'Effacer les recommandations',
                sous: 'Réinitialise l’historique et les goûts appris',
                fin: Icon(Icons.chevron_right_rounded, color: c.t3),
                onTap: _effacerHistorique,
              ),
            if (!enRecherche || _correspond('sauvegarder exporter copier reglage favoris'))
              _Ligne(
                icone: Icons.upload_file_rounded,
                couleur: c.bleu,
                titre: 'Exporter une sauvegarde',
                sous: 'Copie réglages, favoris et positions de lecture',
                fin: Icon(Icons.copy_rounded, color: c.t3, size: 19),
                onTap: _exporter,
              ),
            if (!enRecherche || _correspond('restaurer importer sauvegarde presse papiers'))
              _Ligne(
                icone: Icons.restore_page_outlined,
                couleur: c.cyan,
                titre: 'Restaurer une sauvegarde',
                sous: 'Coller une sauvegarde YT-NEXUS depuis le presse-papiers',
                fin: Icon(Icons.paste_rounded, color: c.t3, size: 19),
                onTap: _importer,
              ),
            if (!enRecherche || _correspond('rapport erreurs diagnostic bug support'))
              _Ligne(
                icone: Icons.bug_report_outlined,
                couleur: c.t2,
                titre: 'Rapport technique',
                sous: 'Copie versions et derniers journaux en cas d’erreur',
                fin: Icon(Icons.chevron_right_rounded, color: c.t3),
                onTap: _rapport,
              ),
            if (!enRecherche || _correspond('reinitialiser defaut usine reset'))
              _Ligne(
                icone: Icons.restart_alt_rounded,
                couleur: c.rouge,
                titre: 'Rétablir les valeurs par défaut',
                sous: 'Conserve ton code PIN, tes favoris et tes fichiers',
                fin: Icon(Icons.chevron_right_rounded, color: c.t3),
                onTap: _reinitialiserDefauts,
              ),
          ];

          if (lignesSecu.isNotEmpty) {
            ajouterSection(_Section(
              icone: Icons.shield_outlined,
              couleur: c.vert,
              titre: 'Confidentialité, Stockage & Sauvegarde',
              resume: formaterTaille(poidsTotal),
              enfants: lignesSecu,
            ));
          }
        }

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 6, 16, 120 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (r.avertissement != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Verre(
                  teinte: c.ambre.withAlpha(24),
                  bordure: Border.all(color: c.ambre.withAlpha(90)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, color: c.ambre, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(r.avertissement!, style: TextStyle(color: c.t1, fontSize: 12.5))),
                  ]),
                ),
              ),

            // ── Tableau de bord en verre ─────────────────────────────
            _TableauDeBord(
              nbFichiers: termines.length,
              poidsTotal: poidsTotal,
              majDispo: maj.dispo?.version,
              majYtdlpEnCours: _maj,
              cookiesActifs: reglages.aDesCookies,
              sombre: c.sombre,
              onToggleTheme: () => r['theme'] = c.sombre ? 'clair' : 'sombre',
              onTapMajApp: () {
                if (maj.dispo == null) maj.verifier(force: true);
                ouvrirFenetreMaj(context);
              },
              onTapBibliotheque: () => onglet.value = 3,
              onTapYtdlp: _maj ? null : () => _mettreAJour(),
              onTapCookies: () => modifierCookies(context),
            ),

            const SizedBox(height: 12),

            // ── Barre de recherche ───────────────────────────────────
            TextField(
              controller: _ctrlRecherche,
              onChanged: (v) => setState(() => _recherche = v),
              style: TextStyle(color: c.t1, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Rechercher un réglage (qualité, wifi, PIN, gestes…)',
                hintStyle: TextStyle(color: c.t3, fontSize: 13.5),
                prefixIcon: Icon(Icons.search_rounded, color: c.t3, size: 20),
                suffixIcon: enRecherche
                    ? IconButton(
                        tooltip: 'Effacer',
                        icon: Icon(Icons.close_rounded, color: c.t3, size: 18),
                        onPressed: () {
                          _ctrlRecherche.clear();
                          setState(() => _recherche = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: c.verre2,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.trait)),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.trait)),
                focusedBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.indigo, width: 1.4)),
              ),
            ),

            // ── Onglets catégories ───────────────────────────────────
            if (!enRecherche) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (cat, label, ic) in _categories)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _OngletCategorie(
                          icone: ic,
                          label: label,
                          actif: _categorie == cat,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _categorie = cat);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),

            if (widgets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 42),
                child: Column(children: [
                  Icon(Icons.search_off_rounded, size: 42, color: c.t3),
                  const SizedBox(height: 8),
                  Text('Aucun réglage trouvé pour « $_recherche »', style: TextStyle(color: c.t2, fontSize: 13.5)),
                ]),
              )
            else
              ...widgets,

            const SizedBox(height: 22),
            Center(
              child: Text(
                'YT-NEXUS v${Natif.versionApp} · yt-dlp + ffmpeg embarqués',
                style: TextStyle(color: c.t3, fontSize: 11.5),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TableauDeBord extends StatelessWidget {
  final int nbFichiers, poidsTotal;
  final String? majDispo;
  final bool majYtdlpEnCours, cookiesActifs, sombre;
  final VoidCallback onToggleTheme, onTapMajApp, onTapBibliotheque, onTapCookies;
  final VoidCallback? onTapYtdlp;

  const _TableauDeBord({
    required this.nbFichiers,
    required this.poidsTotal,
    required this.majDispo,
    required this.majYtdlpEnCours,
    required this.cookiesActifs,
    required this.sombre,
    required this.onToggleTheme,
    required this.onTapMajApp,
    required this.onTapBibliotheque,
    required this.onTapYtdlp,
    required this.onTapCookies,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Verre(
      rayon: 26,
      teinte: sombre ? const Color(0x284F46E5) : const Color(0x186366F1),
      bordure: Border.all(color: c.indigo.withAlpha(sombre ? 105 : 60), width: 1.2),
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: gradBouton,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: c.indigo.withAlpha(80), blurRadius: 14)],
            ),
            child: const Icon(Icons.tune_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('YT-NEXUS', style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 16)),
                const SizedBox(width: 7),
                Text('v${Natif.versionApp}', style: mono(context, taille: 11.5, couleur: c.t3)),
              ]),
              const SizedBox(height: 3),
              GestureDetector(
                onTap: onTapMajApp,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: majDispo != null ? c.ambre : c.vert,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    majDispo != null ? 'Mise à jour v$majDispo disponible' : 'Application à jour',
                    style: TextStyle(
                      color: majDispo != null ? c.ambre : c.t2,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ]),
              ),
            ]),
          ),
          BoutonVerre(
            icone: sombre ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
            texte: sombre ? 'Sombre' : 'Clair',
            couleur: sombre ? c.indigo : c.ambre,
            onTap: onToggleTheme,
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _TuileStat(
              icone: Icons.folder_copy_outlined,
              couleur: c.cyan,
              titre: 'Bibliothèque',
              valeur: '$nbFichiers · ${formaterTaille(poidsTotal)}',
              onTap: onTapBibliotheque,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TuileStat(
              icone: Icons.terminal_rounded,
              couleur: c.indigo,
              titre: 'yt-dlp',
              valeur: majYtdlpEnCours ? 'MAJ…' : (Natif.version.isEmpty ? 'Prêt' : Natif.version),
              onTap: onTapYtdlp,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TuileStat(
              icone: Icons.cookie_outlined,
              couleur: cookiesActifs ? c.vert : c.ambre,
              titre: 'Cookies',
              valeur: cookiesActifs ? 'Actifs ✓' : 'Aucun',
              onTap: onTapCookies,
            ),
          ),
        ]),
      ]),
    );
  }
}

class _TuileStat extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre, valeur;
  final VoidCallback? onTap;

  const _TuileStat({
    required this.icone,
    required this.couleur,
    required this.titre,
    required this.valeur,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: c.sombre ? const Color(0x20FFFFFF) : const Color(0xBBFFFFFF),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: c.trait),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icone, size: 15, color: couleur),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  titre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.t3, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              valeur,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, taille: 11.5, couleur: c.t1, poids: FontWeight.w700),
            ),
          ]),
        ),
      ),
    );
  }
}

class _OngletCategorie extends StatelessWidget {
  final IconData icone;
  final String label;
  final bool actif;
  final VoidCallback onTap;

  const _OngletCategorie({
    required this.icone,
    required this.label,
    required this.actif,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        gradient: actif ? gradBouton : null,
        color: actif ? null : c.verre2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: actif ? Colors.transparent : c.trait),
        boxShadow: actif ? [BoxShadow(color: c.indigo.withAlpha(65), blurRadius: 12, offset: const Offset(0, 3))] : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icone, size: 16, color: actif ? Colors.white : c.t2),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: actif ? Colors.white : c.t1,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String? resume;
  final List<Widget> enfants;

  const _Section({
    required this.icone,
    required this.couleur,
    required this.titre,
    this.resume,
    required this.enfants,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Verre(
      rayon: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: couleur.withAlpha(c.sombre ? 44 : 28),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: couleur.withAlpha(90)),
            ),
            child: Icon(icone, size: 17, color: couleur),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              titre,
              style: TextStyle(fontWeight: FontWeight.w800, color: c.t1, fontSize: 15),
            ),
          ),
          if (resume != null && resume!.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: c.verre2,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.trait),
              ),
              child: Text(resume!, style: mono(context, taille: 11, couleur: c.t2, poids: FontWeight.w600)),
            ),
        ]),
        const SizedBox(height: 12),
        for (var i = 0; i < enfants.length; i++) ...[
          if (i > 0) Divider(height: 14, thickness: 1, color: c.trait),
          enfants[i],
        ],
      ]),
    );
  }
}

class _SousEtiquette extends StatelessWidget {
  final String texte;
  const _SousEtiquette(this.texte);

  @override
  Widget build(BuildContext context) => Text(
        texte.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w800,
          color: context.c.t3,
        ),
      );
}

class _ChoixSegment extends StatelessWidget {
  final IconData icone;
  final String titre, sous;
  final bool actif;
  final Color couleur;
  final VoidCallback onTap;

  const _ChoixSegment({
    required this.icone,
    required this.titre,
    required this.sous,
    required this.actif,
    required this.couleur,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: actif ? couleur.withAlpha(c.sombre ? 52 : 28) : c.verre2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: actif ? couleur.withAlpha(180) : c.trait, width: actif ? 1.4 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: actif ? couleur.withAlpha(55) : c.verre,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icone, size: 18, color: actif ? couleur : c.t2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(titre, style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 13.5)),
                  Text(sous, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.t3, fontSize: 11)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _PastilleEtat extends StatelessWidget {
  final String texte;
  final Color couleur;
  const _PastilleEtat({required this.texte, required this.couleur});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: couleur.withAlpha(28),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: couleur.withAlpha(90)),
        ),
        child: Text(texte, style: TextStyle(color: couleur, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
}

class _Ligne extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre, sous;
  final Widget fin;
  final VoidCallback? onTap;

  const _Ligne({
    required this.icone,
    required this.couleur,
    required this.titre,
    required this.sous,
    required this.fin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: couleur.withAlpha(c.sombre ? 34 : 22),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: couleur.withAlpha(c.sombre ? 65 : 40)),
            ),
            child: Icon(icone, size: 18, color: couleur),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(titre, style: TextStyle(fontWeight: FontWeight.w600, color: c.t1, fontSize: 13.8)),
              const SizedBox(height: 1),
              Text(sous, style: TextStyle(color: c.t3, fontSize: 11.8, height: 1.25)),
            ]),
          ),
          const SizedBox(width: 8),
          fin,
        ]),
      ),
    );
  }
}

class _Compteur extends StatelessWidget {
  final dynamic valeur;
  final int mini, maxi;
  final ValueChanged<int> onChanged;
  const _Compteur(this.valeur, this.mini, this.maxi, this.onChanged);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = (valeur as num).toInt();
    return Container(
      decoration: BoxDecoration(color: c.verre2, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.trait)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: v > mini ? () => onChanged(v - 1) : null,
          icon: const Icon(Icons.remove_rounded, size: 18),
        ),
        SizedBox(width: 22, child: Text('$v', textAlign: TextAlign.center, style: mono(context, taille: 14, couleur: c.t1))),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: v < maxi ? () => onChanged(v + 1) : null,
          icon: const Icon(Icons.add_rounded, size: 18),
        ),
      ]),
    );
  }
}
