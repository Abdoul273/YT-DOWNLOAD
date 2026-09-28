# YT-NEXUS AETHER v7.0 ULTRA PREMIUM

Une application web avancée de téléchargement multimédia utilisant Flask et yt-dlp.

## Fonctionnalités

- 🎥 Support multi-plateformes (YouTube, TikTok, Instagram, Twitter/X, Vimeo, etc.)
- ⚡ Mode Turbo avec fragments multiples
- 🎵 Téléchargement audio et vidéo
- 📋 Support des playlists
- 🎯 Sélection de format et qualité
- 🌍 Sous-titres multi-langues
- 📅 Planification des téléchargements
- 🔒 Aperçu sécurisé des contenus

## Installation locale

### Prérequis
- Python 3.8+
- FFmpeg (optionnel, pour meilleure qualité)
- pip

### Étapes

1. Clonez le repository
```bash
git clone https://github.com/Abdoul273/YT-DOWNLOAD.git
cd YT-DOWNLOAD
```

2. Créez un environnement virtuel
```bash
python -m venv venv
source venv/bin/activate  # Sur Windows: venv\Scripts\activate
```

3. Installez les dépendances
```bash
pip install -r requirements.txt
```

4. Lancez l'application
```bash
python app.py
```

5. Accédez à `http://localhost:5050` dans votre navigateur

## Déploiement sur Render.com

L'application est configurée pour fonctionner sur Render.com.

### Configuration requise sur Render

1. Créez un nouveau Web Service
2. Connectez votre repository GitHub
3. Sélectionnez la branche `main`
4. Assurez-vous que le `Procfile` est détecté automatiquement
5. Déployez

L'application utilisera automatiquement le port fourni par Render et stockera les fichiers temporaires dans `/tmp`.

## Structure du projet

```
YT-DOWNLOAD/
├── app.py              # Application Flask principale
├── requirements.txt    # Dépendances Python
├── Procfile           # Configuration Render
├── .gitignore         # Fichiers à ignorer dans Git
├── static/
│   ├── index.html     # Interface utilisateur
│   ├── premium.css    # Styles
│   ├── premium.js     # Scripts JavaScript
│   └── manifest.json  # Manifeste PWA
└── tests/             # Tests unitaires
```

## Variables d'environnement

- `PORT` : Port sur lequel l'application écoute (défaut: 5050)
- `RENDER` : Automatiquement défini à `true` par Render.com

## Support

Pour les bugs ou demandes de fonctionnalités, ouvrez une issue sur GitHub.

## Licence

MIT
