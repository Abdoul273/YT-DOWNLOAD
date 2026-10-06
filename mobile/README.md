# YT-NEXUS mobile (Android)

App Android **autonome** : yt-dlp, Python et ffmpeg sont embarqués
([youtubedl-android](https://github.com/JunkFood02/youtubedl-android)), aucun PC ni serveur nécessaire.
Même logique que la version web : piste doublée française en 1ʳᵉ piste, VO en 2ᵉ, sinon VO + sous-titres FR.

- **Vidéo** : colle un lien (ou *Partager → YT-NEXUS* depuis YouTube), choisis la piste, la qualité, le format.
  Playlists, chaînes et lots de plusieurs liens.
- **Recherche** YouTube avec tri et filtres.
- **En cours** : file en direct, pause/reprise réelles, relances automatiques, notification de progression.
- **Fichiers** : rangés dans `Téléchargements/YT-NEXUS`, ouvrir/partager/supprimer. Tri, favoris, filtre par
  playlist, sélection multiple (appui long), barre « reprendre » sur les vidéos entamées.
- **Lecteur** : lecture en arrière-plan avec notification média (écran verrouillé, casque), image dans l'image
  (bouton ou automatique en quittant l'app).
- **Mises à jour** : au lancement et à chaque retour dans l'app, une petite fenêtre présente la nouvelle version
  (« Mettre à jour » / « Annuler »). Rien n'est téléchargé sans accord (données mobiles comptées).
- **Téléchargements** : option Wi-Fi uniquement (mise en attente si le Wi-Fi est perdu) et plage horaire (la nuit).
- **Réglages** : langue, qualité, MP4/MKV/WebM, MP3/M4A/Opus/FLAC, mise à jour de yt-dlp, cookies.

## Construire

```fish
cd mobile
flutter build apk --release --split-per-abi
```

APK dans `build/app/outputs/flutter-apk/` (prendre `app-arm64-v8a-release.apk` pour un téléphone récent).

## Organisation

```
lib/moteur/   portage Dart de nexus/ : langues, formats (← le cœur), erreurs, analyse, taches, reglages
lib/moteur/natif.dart   canal vers MainActivity.kt (exécution yt-dlp, MediaStore, notifications)
lib/ui/       interface « liquid glass » (5 onglets)
android/…/MainActivity.kt          yt-dlp embarqué, lignes en direct, publication dans Téléchargements
android/…/ServiceTelechargement.kt service de premier plan pendant les téléchargements
```
