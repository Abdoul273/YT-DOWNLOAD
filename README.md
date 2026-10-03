# YT-NEXUS 8

Téléchargeur YouTube **avec les pistes audio traduites** : quand YouTube propose un doublage (humain ou IA) dans le menu « Piste audio », YT-NEXUS le récupère, le met en piste principale et garde la VO en 2ᵉ piste. Comme 4K Video Downloader, en mieux.

## Ce que ça fait

- **Doublage FR automatique** : piste française par défaut + VO en bonus, pistes nommées (« Français », « Anglais (VO) »).
- **Pas de doublage ?** VO + sous-titres français intégrés (traduits automatiquement par YouTube si besoin).
- Vidéos, **playlists**, **chaînes entières**, plusieurs liens d'un coup, **recherche** YouTube.
- Choix de la langue, de la qualité (jusqu'à 8K, HDR) avec taille estimée, MP4 / MKV / WebM.
- Audio seul : MP3, M4A, Opus, FLAC, WAV ou original sans conversion.
- File d'attente en direct : téléchargements en parallèle, **pause / reprise réelles** (repart des fichiers partiels), nouvelles tentatives automatiques, reprise après redémarrage, téléchargements programmés.
- Extraits (début/fin), découpage par chapitres, SponsorBlock, sous-titres au choix.
- Bibliothèque : lecture intégrée, ouvrir, afficher dans le dossier, enregistrer sur un autre appareil.
- Cookies du navigateur ou `cookies.txt` si YouTube bloque, mise à jour de yt-dlp en un clic.
- Coller n'importe où (Ctrl+V), glisser-déposer, thème clair/sombre, mobile, installable (PWA).

## Installation (Arch / CachyOS)

```fish
./install
```

Puis lance **YT-NEXUS** depuis le menu, ou `yt-nexus` (ou `yt-nexus "https://youtu.be/…"`).
L'interface est sur http://localhost:5050.

Lancement manuel : `python3 app.py`. Accès depuis le téléphone (même Wi-Fi) : `HOST=0.0.0.0 python3 app.py`.

## App Android

Version mobile autonome (yt-dlp embarqué) dans [`mobile/`](mobile/README.md).

## Organisation

```
app.py              point d'entrée
nexus/config.py     réglages (~/.config/yt-nexus), chemins, cookies
nexus/analyse.py    infos vidéo / playlist / chaîne / recherche (API yt-dlp, cache)
nexus/formats.py    pistes audio et sélection des formats ← le cœur
nexus/taches.py     file : parallélisme, pause/reprise, relances, persistance
nexus/web.py        API HTTP + flux temps réel (SSE)
static/             interface (HTML/CSS/JS sans framework)
tests/              tests unitaires (pytest)
```

Données : `~/.local/share/yt-nexus` (file de téléchargement), réglages : `~/.config/yt-nexus`.
