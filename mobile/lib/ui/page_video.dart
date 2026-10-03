/// Onglet Vidéo : coller un lien, choisir la piste audio, la qualité, télécharger.
/// Gère aussi les playlists/chaînes et les lots de plusieurs liens.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../moteur/analyse.dart' as analyse;
import '../moteur/formats.dart' show Qualite;
import '../moteur/langues.dart' as langues;
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'apercu.dart';
import 'etat.dart';
import 'theme.dart';

class PageVideo extends StatefulWidget {
  const PageVideo({super.key});
  @override
  State<PageVideo> createState() => _PageVideoState();
}

class _PageVideoState extends State<PageVideo> {
  final _champ = TextEditingController();
  bool _charge = false;
  String? _erreur;
  Object? _resultat; // ResumeVideo | Playlist | List<String> (lot)
  int _jeton = 0;

  @override
  void initState() {
    super.initState();
    lienAAnalyser.addListener(_lienRecu);
    WidgetsBinding.instance.addPostFrameCallback((_) => _lienRecu());
  }

  @override
  void dispose() {
    lienAAnalyser.removeListener(_lienRecu);
    _champ.dispose();
    super.dispose();
  }

  void _lienRecu() {
    final t = lienAAnalyser.value;
    if (t == null) return;
    lienAAnalyser.value = null;
    _champ.text = t;
    _analyser();
  }

  Future<void> _coller() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text == null || d!.text!.trim().isEmpty) {
      if (mounted) toast(context, 'Presse-papiers vide', erreur: true);
      return;
    }
    _champ.text = d.text!.trim();
    _analyser();
  }

  Future<void> _analyser() async {
    FocusScope.of(context).unfocus();
    final texte = _champ.text.trim();
    if (texte.isEmpty) return;
    final liens = extraireLiens(texte);
    final jeton = ++_jeton;
    if (liens.length > 1) {
      setState(() {
        _resultat = liens;
        _erreur = null;
      });
      return;
    }
    setState(() {
      _charge = true;
      _erreur = null;
      _resultat = null;
    });
    try {
      final r = await analyse.analyser(liens.isNotEmpty ? liens.first : texte);
      if (jeton == _jeton) setState(() => _resultat = r);
    } catch (e) {
      if (jeton == _jeton) setState(() => _erreur = '$e');
    } finally {
      if (jeton == _jeton) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = _resultat;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 120 + MediaQuery.paddingOf(context).bottom),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Verre(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Télécharger', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: c.t1)),
            const SizedBox(height: 2),
            Text('Doublage français en piste principale, VO en bonus.', style: TextStyle(color: c.t2, fontSize: 13)),
            const SizedBox(height: 14),
            TextField(
              controller: _champ,
              onSubmitted: (_) => _analyser(),
              textInputAction: TextInputAction.go,
              keyboardType: TextInputType.url,
              minLines: 1,
              maxLines: 4,
              style: TextStyle(color: c.t1, fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Lien YouTube, playlist, chaîne… ou plusieurs liens',
                hintStyle: TextStyle(color: c.t3, fontSize: 14),
                filled: true,
                fillColor: c.verre2,
                prefixIcon: Icon(Icons.link_rounded, color: c.t3),
                suffixIcon: _champ.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close_rounded, color: c.t3),
                        onPressed: () => setState(() {
                          _champ.clear();
                          _resultat = null;
                          _erreur = null;
                        }),
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.trait)),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.trait)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c.indigo, width: 1.5)),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(children: [
              BoutonVerre(icone: Icons.content_paste_rounded, texte: 'Coller', onTap: _coller),
              const SizedBox(width: 10),
              Expanded(child: BoutonGrad('Analyser', icone: Icons.auto_awesome_rounded, charge: _charge, onTap: _analyser)),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (w, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a), child: w),
          ),
          child: _erreur != null
              ? _Erreur(_erreur!, key: const ValueKey('erreur'), onReessayer: _analyser)
              : _charge
                  ? const _Squelette(key: ValueKey('charge'))
                  : r is analyse.ResumeVideo
                      ? _VueVideo(r, key: ValueKey(r.url))
                      : r is analyse.Playlist
                          ? _VuePlaylist(r, key: ValueKey(r.url))
                          : r is List<String>
                              ? _VueLot(r, key: ValueKey(r.join()))
                              : const _Astuces(key: ValueKey('vide')),
        ),
      ],
    );
  }
}

class _Erreur extends StatelessWidget {
  final String message;
  final VoidCallback onReessayer;
  const _Erreur(this.message, {super.key, required this.onReessayer});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Verre(
      teinte: c.rouge.withAlpha(25),
      bordure: Border.all(color: c.rouge.withAlpha(90)),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, color: c.rouge),
        const SizedBox(width: 12),
        Expanded(child: Text(message, style: TextStyle(color: c.t1))),
        IconButton(onPressed: onReessayer, icon: Icon(Icons.refresh_rounded, color: c.t2)),
      ]),
    );
  }
}

class _Squelette extends StatelessWidget {
  const _Squelette({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget barre(double l, [double h = 12]) => Container(
        width: l, height: h, decoration: BoxDecoration(color: c.verre3, borderRadius: BorderRadius.circular(8)));
    return Verre(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(decoration: BoxDecoration(color: c.verre3, borderRadius: BorderRadius.circular(16)))),
        const SizedBox(height: 14),
        barre(260, 16),
        const SizedBox(height: 8),
        barre(160),
        const SizedBox(height: 16),
        Text('Analyse des pistes audio et des qualités…', style: TextStyle(color: c.t3, fontSize: 12.5)),
      ]),
    );
  }
}

class _Astuces extends StatelessWidget {
  const _Astuces({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget ligne(IconData i, String t, String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: c.indigo.withAlpha(30), borderRadius: BorderRadius.circular(12)),
              child: Icon(i, size: 18, color: c.indigo),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: c.t1)),
                Text(s, style: TextStyle(color: c.t2, fontSize: 12.5)),
              ]),
            ),
          ]),
        );
    return Verre(
      child: Column(children: [
        ligne(Icons.translate_rounded, 'Pistes doublées', "Quand YouTube propose un doublage (humain ou IA), il passe en piste principale."),
        ligne(Icons.subtitles_outlined, 'Pas de doublage ?', 'VO + sous-titres français intégrés, traduits par YouTube si besoin.'),
        ligne(Icons.share_rounded, 'Partager vers YT-NEXUS', "Depuis l'app YouTube : Partager → YT-NEXUS."),
        ligne(Icons.playlist_play_rounded, 'Playlists et chaînes', 'Colle le lien, coche les vidéos, tout part en file.'),
      ]),
    );
  }
}

// ── Vidéo seule ───────────────────────────────────────────────────────
class _VueVideo extends StatefulWidget {
  final analyse.ResumeVideo v;
  const _VueVideo(this.v, {super.key});
  @override
  State<_VueVideo> createState() => _VueVideoState();
}

class _VueVideoState extends State<_VueVideo> {
  late String _type = reglages['type'];
  late String _langue; // code de piste ou "original"
  late bool _garderVo = reglages['garder_vo'];
  late String _qualite = reglages['qualite'];
  late String _conteneur = reglages['conteneur'];
  late String _formatAudio = reglages['format_audio'];
  final Set<String> _sousTitres = {};
  bool _stAuto = false, _stFichier = false, _chapitres = false;
  late bool _sponsor = reglages['sponsorblock'];
  final _debut = TextEditingController(), _fin = TextEditingController();

  @override
  void initState() {
    super.initState();
    final v = widget.v;
    _langue = v.pisteVoulue ?? (reglages['langue_audio'] == 'original' ? 'original' : (v.originale ?? 'original'));
    // Qualité par défaut : la meilleure disponible sous le réglage
    final qs = v.qualitesPour(null).$1;
    final h = int.tryParse(_qualite);
    if (h != null && qs.isNotEmpty && !qs.any((q) => q.hauteur == h)) {
      final sous = qs.where((q) => q.hauteur <= h);
      _qualite = sous.isNotEmpty ? '${sous.first.hauteur}' : '${qs.last.hauteur}';
    }
  }

  @override
  void dispose() {
    _debut.dispose();
    _fin.dispose();
    super.dispose();
  }

  bool get _sansDoublage =>
      reglages['langue_audio'] != 'original' &&
      widget.v.pisteVoulue == null &&
      !langues.memeLangue(widget.v.originale, reglages['langue_audio']);

  void _telecharger() {
    final v = widget.v;
    final langue = _langue == 'original' || _langue == v.originale ? 'original' : _langue;
    gestionnaire.ajouter([
      Ajout(v.url, titre: v.titre, miniature: v.miniature, chaine: v.chaine, duree: v.duree)
    ], {
      'type': _type,
      'qualite': _qualite,
      'conteneur': _conteneur,
      'format_audio': _formatAudio,
      // langue voulue : la piste choisie ; si VO choisie alors qu'aucun doublage n'existe, on garde
      // le réglage pour déclencher les sous-titres de secours
      'langue_audio': langue == 'original' && _sansDoublage ? reglages['langue_audio'] : langue,
      'garder_vo': _garderVo,
      'sous_titres': _sousTitres.toList(),
      'sous_titres_auto': _stAuto,
      'sous_titres_fichier': _stFichier,
      'chapitres_separes': _chapitres,
      'sponsorblock': _sponsor,
      'debut': _debut.text,
      'fin': _fin.text,
    });
    toast(context, 'Ajouté à la file');
    onglet.value = 2;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = widget.v;
    final piste = _langue == 'original' ? v.originale : _langue;
    final (qualites, tailleAudio) = v.qualitesPour(piste);
    final doublee = _langue != 'original' && _langue != v.originale;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Verre(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Apercu(v),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.titre, style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: c.t1, height: 1.3)),
              const SizedBox(height: 6),
              Text(
                [
                  v.chaine,
                  formaterVues(v.vues),
                  if (v.date != null && v.date!.length == 8) '${v.date!.substring(6)}/${v.date!.substring(4, 6)}/${v.date!.substring(0, 4)}',
                ].where((s) => s != null && s.isNotEmpty).join(' · '),
                style: TextStyle(color: c.t2, fontSize: 12.5),
              ),
              if (v.playlist != null) ...[
                const SizedBox(height: 10),
                BoutonVerre(
                    icone: Icons.playlist_play_rounded,
                    texte: 'Ouvrir la playlist',
                    onTap: () => ouvrirLien(v.playlist!)),
              ],
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      if (v.direct)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _Bandeau(Icons.live_tv_rounded, c.rouge, 'Direct en cours : attends la fin du live pour le télécharger.'),
        ),
      Verre(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Etiquette('Format'),
          Row(children: [
            Expanded(
                child: Puce('🎬  Vidéo',
                    choisie: _type == 'video', onTap: () => setState(() => _type = 'video'))),
            const SizedBox(width: 10),
            Expanded(
                child: Puce('🎧  Audio seul',
                    choisie: _type == 'audio', onTap: () => setState(() => _type = 'audio'))),
          ]),
          const SizedBox(height: 18),
          Etiquette('Piste audio', fin: Text('${v.pistes.length} piste${v.pistes.length > 1 ? 's' : ''}', style: mono(context, taille: 11, couleur: c.t3))),
          if (_sansDoublage)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _Bandeau(
                Icons.subtitles_outlined,
                c.ambre,
                'Pas de doublage ${langues.nom(reglages['langue_audio']).toLowerCase()} pour cette vidéo'
                '${reglages['sous_titres_secours'] == true && _type == 'video' ? ' → VO + sous-titres intégrés' : ''}.',
              ),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in v.pistes)
              Puce('${p.drapeau} ${p.nom}',
                  sous: p.genre,
                  choisie: _langue == p.code || (_langue == 'original' && p.originale),
                  onTap: () => setState(() => _langue = p.originale ? 'original' : p.code)),
            if (v.pistes.isEmpty) Puce('🌐 Piste unique', choisie: true, onTap: () {}),
          ]),
          if (doublee && _type == 'video')
            _Interrupteur('Garder la VO en 2ᵉ piste', '${langues.drapeau(v.originale)} ${v.originaleNom ?? 'Originale'}',
                _garderVo, (x) => setState(() => _garderVo = x)),
          const SizedBox(height: 14),
          if (_type == 'video') ...[
            const Etiquette('Qualité'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final q in qualites)
                Puce(q.libelle,
                    badge: q.hdr ? 'HDR' : q.badge,
                    sous: formaterTaille(q.taille),
                    choisie: _qualite == '${q.hauteur}',
                    onTap: () => setState(() => _qualite = '${q.hauteur}')),
              if (qualites.isEmpty) Puce('Meilleure', choisie: true, onTap: () {}),
            ]),
            const SizedBox(height: 16),
            const Etiquette('Conteneur'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (k, l, s) in const [('mp4', 'MP4', 'compatible'), ('mkv', 'MKV', 'pistes nommées'), ('webm', 'WebM', 'VP9/AV1')])
                Puce(l, sous: s, choisie: _conteneur == k, onTap: () => setState(() => _conteneur = k)),
            ]),
          ] else ...[
            const Etiquette('Format audio'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (k, l) in const [('mp3', 'MP3'), ('m4a', 'M4A'), ('opus', 'Opus'), ('flac', 'FLAC'), ('wav', 'WAV'), ('original', 'Original')])
                Puce(l, choisie: _formatAudio == k, onTap: () => setState(() => _formatAudio = k)),
            ]),
            const SizedBox(height: 6),
            Text('≈ ${formaterTaille(tailleAudio)}', style: mono(context, taille: 11, couleur: c.t3)),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Verre(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            iconColor: c.t2,
            collapsedIconColor: c.t3,
            title: Text('Options avancées', style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 14.5)),
            subtitle: Text('Sous-titres, extrait, chapitres, SponsorBlock', style: TextStyle(color: c.t3, fontSize: 12)),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_type == 'video') ...[
                const Etiquette('Sous-titres'),
                if (v.sousTitres.manuels.isEmpty)
                  Text('Aucun sous-titre manuel${v.sousTitres.auto ? ' (automatiques disponibles)' : ''}.',
                      style: TextStyle(color: c.t3, fontSize: 12.5))
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final code in v.sousTitres.manuels)
                      Puce('${langues.drapeau(code)} ${langues.nom(code)}',
                          choisie: _sousTitres.contains(code),
                          onTap: () => setState(() => _sousTitres.contains(code) ? _sousTitres.remove(code) : _sousTitres.add(code))),
                  ]),
                if (v.sousTitres.auto)
                  _Interrupteur('Inclure les sous-titres automatiques', 'Traduits par YouTube', _stAuto,
                      (x) => setState(() => _stAuto = x)),
                _Interrupteur('Fichier .srt séparé', 'Au lieu de les intégrer à la vidéo', _stFichier,
                    (x) => setState(() => _stFichier = x)),
                if (v.chapitres > 0)
                  _Interrupteur('Découper par chapitres', '${v.chapitres} chapitres → un fichier chacun', _chapitres,
                      (x) => setState(() => _chapitres = x)),
              ],
              _Interrupteur('SponsorBlock', 'Retirer sponsors, autopromo, rappels d’abonnement', _sponsor,
                  (x) => setState(() => _sponsor = x)),
              const SizedBox(height: 10),
              const Etiquette('Extrait'),
              Row(children: [
                Expanded(child: _ChampTemps(_debut, 'Début (0:30)')),
                const SizedBox(width: 10),
                Expanded(child: _ChampTemps(_fin, 'Fin (2:15)')),
              ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      BoutonGrad(
        _type == 'audio'
            ? 'Télécharger l’audio'
            : 'Télécharger ${qualites.where((q) => '${q.hauteur}' == _qualite).map((Qualite q) => q.libelle).firstOrNull ?? ''}',
        icone: Icons.download_rounded,
        onTap: v.direct ? null : _telecharger,
      ),
    ]);
  }
}

class _Bandeau extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String texte;
  const _Bandeau(this.icone, this.couleur, this.texte);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: couleur.withAlpha(28),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: couleur.withAlpha(80)),
        ),
        child: Row(children: [
          Icon(icone, size: 18, color: couleur),
          const SizedBox(width: 10),
          Expanded(child: Text(texte, style: TextStyle(color: context.c.t1, fontSize: 12.5))),
        ]),
      );
}

class _Interrupteur extends StatelessWidget {
  final String titre, sous;
  final bool valeur;
  final ValueChanged<bool> onChanged;
  const _Interrupteur(this.titre, this.sous, this.valeur, this.onChanged);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!valeur),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(titre, style: TextStyle(fontWeight: FontWeight.w600, color: c.t1, fontSize: 14)),
              Text(sous, style: TextStyle(color: c.t3, fontSize: 12)),
            ]),
          ),
          Switch(value: valeur, onChanged: onChanged),
        ]),
      ),
    );
  }
}

class _ChampTemps extends StatelessWidget {
  final TextEditingController ctrl;
  final String indice;
  const _ChampTemps(this.ctrl, this.indice);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.datetime,
      style: mono(context, taille: 13, couleur: c.t1),
      decoration: InputDecoration(
        hintText: indice,
        hintStyle: TextStyle(color: c.t3, fontSize: 13),
        isDense: true,
        filled: true,
        fillColor: c.verre2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.trait)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.trait)),
      ),
    );
  }
}

// ── Options rapides (playlist, lot) ───────────────────────────────────
class _OptionsRapides extends StatelessWidget {
  final String type, qualite;
  final ValueChanged<String> onType, onQualite;
  const _OptionsRapides(this.type, this.qualite, this.onType, this.onQualite);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Puce('🎬  Vidéo', choisie: type == 'video', onTap: () => onType('video'))),
        const SizedBox(width: 10),
        Expanded(child: Puce('🎧  Audio (${(reglages['format_audio'] as String).toUpperCase()})', choisie: type == 'audio', onTap: () => onType('audio'))),
      ]),
      if (type == 'video') ...[
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, l) in const [('best', 'Max'), ('2160', '4K'), ('1440', '2K'), ('1080', '1080p'), ('720', '720p'), ('480', '480p')])
            Puce(l, choisie: qualite == k, onTap: () => onQualite(k)),
        ]),
      ],
      const SizedBox(height: 10),
      Text(
        'Piste : ${langues.drapeau(reglages['langue_audio'])} ${reglages['langue_audio'] == 'original' ? 'VO' : langues.nom(reglages['langue_audio'])}'
        '${reglages['garder_vo'] == true ? ' + VO' : ''} · ${(reglages['conteneur'] as String).toUpperCase()} — modifiable dans Réglages',
        style: TextStyle(color: c.t3, fontSize: 12),
      ),
    ]);
  }
}

class _VuePlaylist extends StatefulWidget {
  final analyse.Playlist p;
  const _VuePlaylist(this.p, {super.key});
  @override
  State<_VuePlaylist> createState() => _VuePlaylistState();
}

class _VuePlaylistState extends State<_VuePlaylist> {
  late final Set<int> _choisies = {for (var i = 0; i < widget.p.entrees.length; i++) i};
  late String _type = reglages['type'], _qualite = reglages['qualite'];

  void _telecharger() {
    final p = widget.p;
    final elements = [
      for (final i in _choisies.toList()..sort())
        if (p.entrees[i].url != null)
          Ajout(p.entrees[i].url!,
              titre: p.entrees[i].titre,
              miniature: p.entrees[i].miniature,
              chaine: p.entrees[i].chaine,
              duree: p.entrees[i].duree,
              groupe: p.titre)
    ];
    gestionnaire.ajouter(elements, {'type': _type, 'qualite': _qualite});
    toast(context, '${elements.length} vidéo${elements.length > 1 ? 's' : ''} ajoutée${elements.length > 1 ? 's' : ''}');
    onglet.value = 2;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = widget.p;
    final tout = _choisies.length == p.entrees.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Verre(
        child: Row(children: [
          Miniature(p.miniature, largeur: 110),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.titre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: c.t1, fontSize: 15.5)),
              if (p.chaine != null) Text(p.chaine!, style: TextStyle(color: c.t2, fontSize: 12.5)),
              Text('${p.entrees.length} vidéos', style: mono(context, taille: 11.5, couleur: c.indigo)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Verre(child: _OptionsRapides(_type, _qualite, (x) => setState(() => _type = x), (x) => setState(() => _qualite = x))),
      const SizedBox(height: 12),
      Row(children: [
        Text('${_choisies.length} / ${p.entrees.length} sélectionnées', style: TextStyle(color: c.t2, fontSize: 13)),
        const Spacer(),
        TextButton(
          onPressed: () => setState(() => tout
              ? _choisies.clear()
              : _choisies.addAll(List.generate(p.entrees.length, (i) => i))),
          child: Text(tout ? 'Tout décocher' : 'Tout cocher'),
        ),
      ]),
      Verre(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          for (var i = 0; i < p.entrees.length; i++)
            InkWell(
              onTap: () => setState(() => _choisies.contains(i) ? _choisies.remove(i) : _choisies.add(i)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(children: [
                  Checkbox(
                    value: _choisies.contains(i),
                    onChanged: (_) => setState(() => _choisies.contains(i) ? _choisies.remove(i) : _choisies.add(i)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  Miniature(p.entrees[i].miniature, largeur: 96, rayon: 10, texteDuree: formaterDuree(p.entrees[i].duree)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(p.entrees[i].titre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.t1, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      BoutonGrad('Télécharger ${_choisies.length} vidéo${_choisies.length > 1 ? 's' : ''}',
          icone: Icons.download_rounded, onTap: _choisies.isEmpty ? null : _telecharger),
    ]);
  }
}

class _VueLot extends StatefulWidget {
  final List<String> liens;
  const _VueLot(this.liens, {super.key});
  @override
  State<_VueLot> createState() => _VueLotState();
}

class _VueLotState extends State<_VueLot> {
  late String _type = reglages['type'], _qualite = reglages['qualite'];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Verre(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Etiquette('Lot de ${widget.liens.length} liens'),
          for (final l in widget.liens)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(Icons.link_rounded, size: 15, color: c.t3),
                const SizedBox(width: 8),
                Expanded(child: Text(l, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(context, taille: 11.5))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Verre(child: _OptionsRapides(_type, _qualite, (x) => setState(() => _type = x), (x) => setState(() => _qualite = x))),
      const SizedBox(height: 16),
      BoutonGrad('Tout télécharger', icone: Icons.download_rounded, onTap: () {
        gestionnaire.ajouter([for (final l in widget.liens) Ajout(l)], {'type': _type, 'qualite': _qualite});
        toast(context, '${widget.liens.length} liens ajoutés');
        onglet.value = 2;
      }),
    ]);
  }
}
