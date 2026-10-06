/// Onglet Réglages : pistes, qualité, file, yt-dlp, cookies.
library;

import 'package:flutter/material.dart';

import '../moteur/langues.dart' as langues;
import '../moteur/gouts.dart';
import '../moteur/maj.dart';
import '../moteur/natif.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'fenetre_maj.dart';
import 'theme.dart';

class PageReglages extends StatefulWidget {
  const PageReglages({super.key});
  @override
  State<PageReglages> createState() => _PageReglagesState();
}

class _PageReglagesState extends State<PageReglages> {
  bool _maj = false;

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

  Future<void> _cookies() async {
    final c = context.c;
    final ctrl = TextEditingController(text: reglages.aDesCookies ? reglages.fichierCookies.readAsStringSync() : '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.sombre ? const Color(0xFF10121F) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            BoutonVerre(icone: Icons.delete_outline_rounded, texte: 'Effacer', onTap: () {
              ctrl.clear();
              Navigator.pop(ctx, true);
            }),
            const SizedBox(width: 10),
            Expanded(child: BoutonGrad('Enregistrer', icone: Icons.check_rounded, onTap: () => Navigator.pop(ctx, true))),
          ]),
        ]),
      ),
    );
    if (ok == true) {
      await reglages.enregistrerCookies(ctrl.text);
      if (mounted) toast(context, ctrl.text.trim().isEmpty ? 'Cookies effacés' : 'Cookies enregistrés');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: reglages,
      builder: (context, _) {
        final r = reglages;
        Widget inter(String cle, String titre, String sous) => _Ligne(
              titre: titre,
              sous: sous,
              fin: Switch(value: r[cle] == true, onChanged: (v) => r[cle] = v),
              onTap: () => r[cle] = r[cle] != true,
            );
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 120 + MediaQuery.paddingOf(context).bottom),
          children: [
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('Piste audio'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final code in langues.languesCourantes)
                    Puce('${langues.drapeau(code)} ${langues.nom(code)}',
                        choisie: r['langue_audio'] == code, onTap: () => r['langue_audio'] = code),
                  Puce('🌐 VO seule', choisie: r['langue_audio'] == 'original', onTap: () => r['langue_audio'] = 'original'),
                ]),
                const SizedBox(height: 6),
                inter('garder_vo', 'Garder la VO en 2ᵉ piste', 'Doublage par défaut, VO sélectionnable dans le lecteur'),
                inter('sous_titres_secours', 'Sous-titres de secours', 'Pas de doublage → VO + sous-titres dans ta langue'),
              ]),
            ),
            const SizedBox(height: 12),
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('Par défaut'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  Puce('🎬 Vidéo', choisie: r['type'] == 'video', onTap: () => r['type'] = 'video'),
                  Puce('🎧 Audio', choisie: r['type'] == 'audio', onTap: () => r['type'] = 'audio'),
                ]),
                const SizedBox(height: 14),
                Text('Qualité vidéo', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (k, l) in const [('best', 'Max'), ('2160', '4K'), ('1440', '2K'), ('1080', '1080p'), ('720', '720p'), ('480', '480p'), ('360', '360p')])
                    Puce(l, choisie: r['qualite'] == k, onTap: () => r['qualite'] = k),
                ]),
                const SizedBox(height: 14),
                Text('Conteneur', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final k in const ['mp4', 'mkv', 'webm'])
                    Puce(k.toUpperCase(), choisie: r['conteneur'] == k, onTap: () => r['conteneur'] = k),
                ]),
                const SizedBox(height: 14),
                Text('Format audio', style: TextStyle(color: c.t2, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in const ['mp3', 'm4a', 'opus', 'flac', 'wav', 'original'])
                    Puce(k == 'original' ? 'Original' : k.toUpperCase(),
                        choisie: r['format_audio'] == k, onTap: () => r['format_audio'] = k),
                ]),
                const SizedBox(height: 6),
                inter('sponsorblock', 'SponsorBlock', 'Retirer les passages sponsorisés'),
                inter('miniature', 'Miniature intégrée', 'Pochette dans le fichier'),
                inter('metadonnees', 'Métadonnées et chapitres', 'Titre, chaîne, date, chapitres'),
              ]),
            ),
            const SizedBox(height: 12),
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('File de téléchargement'),
                _Ligne(
                  titre: 'Téléchargements simultanés',
                  sous: 'Plus = plus rapide, mais plus de batterie',
                  fin: _Compteur(r['simultanes'], 1, 5, (v) => r['simultanes'] = v),
                ),
                _Ligne(
                  titre: 'Connexions par fichier',
                  sous: 'Fragments téléchargés en parallèle',
                  fin: _Compteur(r['fragments'], 1, 16, (v) => r['fragments'] = v),
                ),
                _Ligne(
                  titre: 'Nouvelles tentatives',
                  sous: 'Après une coupure réseau ou un 403',
                  fin: _Compteur(r['relances'], 0, 10, (v) => r['relances'] = v),
                ),
                inter('wifi_seulement', 'Wi-Fi uniquement', 'Les téléchargements attendent le Wi-Fi (pas de données mobiles)'),
                inter('plage_active', 'Plage horaire', 'Ne télécharger que la nuit, par exemple'),
                if (r['plage_active'] == true) ...[
                  _Ligne(
                    titre: 'Début',
                    sous: 'Les téléchargements démarrent à cette heure',
                    fin: BoutonVerre(
                        icone: Icons.schedule_rounded,
                        texte: Gestionnaire.heure((r['plage_debut'] as num).toInt()),
                        onTap: () => _choisirHeure('plage_debut')),
                  ),
                  _Ligne(
                    titre: 'Fin',
                    sous: 'Plus aucun nouveau téléchargement après',
                    fin: BoutonVerre(
                        icone: Icons.schedule_rounded,
                        texte: Gestionnaire.heure((r['plage_fin'] as num).toInt()),
                        onTap: () => _choisirHeure('plage_fin')),
                  ),
                ],
                inter('sous_dossier_playlist', 'Un dossier par playlist', 'Téléchargements/YT-NEXUS/<playlist>'),
                inter('notifications', 'Notification à la fin', 'Quand un téléchargement est terminé'),
                inter('presse_papiers_auto', 'Lien copié détecté', 'Propose de télécharger un lien YouTube copié, à l’ouverture de l’app'),
              ]),
            ),
            const SizedBox(height: 12),
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('Lecteur'),
                inter('pip_auto', 'Image dans l’image', 'Une vidéo en lecture reste en petite fenêtre quand tu quittes l’app'),
              ]),
            ),
            const SizedBox(height: 12),
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('Moteur'),
                _Ligne(
                  titre: 'yt-dlp ${Natif.version}',
                  sous: 'À mettre à jour quand YouTube change quelque chose',
                  fin: _maj
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                        )
                      : BoutonVerre(icone: Icons.system_update_alt_rounded, aide: 'Mettre à jour', onTap: _mettreAJour),
                ),
                inter('maj_auto', 'Mise à jour automatique', 'Vérifie une fois par jour au lancement'),
                _Ligne(
                  titre: 'Version de développement',
                  sous: 'Si la version stable ne marche plus (nightly)',
                  fin: BoutonVerre(icone: Icons.science_outlined, aide: 'Installer la nightly', onTap: _maj ? null : () => _mettreAJour(nightly: true)),
                ),
                _Ligne(
                  titre: 'Cookies YouTube',
                  sous: reglages.aDesCookies ? 'Enregistrés ✓' : 'Aucun — utile si YouTube bloque',
                  fin: Icon(Icons.chevron_right_rounded, color: c.t3),
                  onTap: _cookies,
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Verre(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Etiquette('Application'),
                ListenableBuilder(
                  listenable: maj,
                  builder: (context, _) => _Ligne(
                    titre: 'YT-NEXUS ${Natif.versionApp}',
                    sous: maj.dispo != null ? 'Version ${maj.dispo!.version} disponible' : 'Rechercher une mise à jour',
                    fin: Icon(maj.dispo != null ? Icons.new_releases_rounded : Icons.chevron_right_rounded,
                        color: maj.dispo != null ? c.indigo : c.t3),
                    onTap: () {
                      if (maj.dispo == null) maj.verifier(force: true);
                      ouvrirFenetreMaj(context);
                    },
                  ),
                ),
                _Ligne(
                  titre: 'Recommandations',
                  sous: 'Effacer l’historique de recherche et les goûts appris',
                  fin: Icon(Icons.delete_sweep_outlined, color: c.t3),
                  onTap: () {
                    gouts.effacer();
                    toast(context, 'Historique effacé');
                  },
                ),
              ]),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text('YT-NEXUS mobile · yt-dlp + ffmpeg embarqués',
                  style: TextStyle(color: c.t3, fontSize: 11.5)),
            ),
          ],
        );
      },
    );
  }
}

class _Ligne extends StatelessWidget {
  final String titre, sous;
  final Widget fin;
  final VoidCallback? onTap;
  const _Ligne({required this.titre, required this.sous, required this.fin, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(titre, style: TextStyle(fontWeight: FontWeight.w600, color: c.t1, fontSize: 14)),
              Text(sous, style: TextStyle(color: c.t3, fontSize: 12)),
            ]),
          ),
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
            icon: const Icon(Icons.remove_rounded, size: 18)),
        SizedBox(width: 22, child: Text('$v', textAlign: TextAlign.center, style: mono(context, taille: 14, couleur: c.t1))),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: v < maxi ? () => onChanged(v + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18)),
      ]),
    );
  }
}
