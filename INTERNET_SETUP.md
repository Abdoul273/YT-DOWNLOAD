# Configuration pour Internet (Render.com)

## 🚀 Problèmes d'authentification YouTube

L'application sur Render peut rencontrer des problèmes avec YouTube qui demande une authentification pour confirmer que vous n'êtes pas un bot.

## ✅ Solutions

### Solution 1: Attendre quelques minutes
YouTube bloque temporairement les requêtes. Attendez 5-10 minutes et réessayez.

### Solution 2: Utiliser des Cookies YouTube (Recommandé)

1. **Exporter vos cookies YouTube depuis votre navigateur:**
   - Chrome/Brave: Utilisez l'extension [EditThisCookie](https://chrome.google.com/webstore/detail/editthiscookie/fngmhnnpilhplaeedifhccceomclgfbg)
   - Firefox: Utilisez l'extension [Cookie Editor](https://addons.mozilla.org/firefox/addon/cookie-editor/)

2. **Étapes:**
   - Allez sur https://youtube.com
   - Connectez-vous à votre compte
   - Ouvrez l'extension de cookies
   - Exportez les cookies en JSON/TXT
   - Sauvegardez le fichier sous `cookies.txt`

3. **Uploader les cookies dans l'app:**
   - Dans l'interface de YT-NEXUS, allez aux paramètres
   - Cherchez "Upload Cookies"
   - Sélectionnez votre fichier `cookies.txt`
   - Cliquez sur "Upload"

### Solution 3: Utiliser yt-dlp en local

Pour les téléchargements problématiques:

```bash
# Exporter les cookies depuis votre navigateur
yt-dlp --cookies-from-browser chrome --dump-json "VIDEO_URL" > info.json

# Puis télécharger avec les cookies
yt-dlp --cookies cookies.txt -f best "VIDEO_URL"
```

## 🔧 Configuration Render automatique

L'app est déjà configurée avec:
- User-Agent personnalisé
- Options YouTube optimisées
- Gestion des erreurs d'authentification
- Fallback sur les clients alternatifs

## ⚠️ Limitations sur Render

- **Espace disque limité**: Les fichiers sont stockés temporairement dans `/tmp/`
- **Pas de persistance**: Les téléchargements redémarrent après 1 heure
- **Bande passante limitée**: Pour les fichiers volumineux

## 💡 Tips

1. Les vidéos publiques de YouTube fonctionnent généralement sans cookies
2. Certaines régions/contenus restreinx peuvent nécessiter les cookies
3. L'app tente automatiquement plusieurs approches avant d'échouer
4. Si ça persiste, les cookies sont la meilleure solution

## 📝 Fichier cookies.txt format

Le fichier doit être au format Netscape (standard de yt-dlp):

```
# Netscape HTTP Cookie File
.youtube.com	TRUE	/	TRUE	0	COOKIE_NAME	COOKIE_VALUE
.youtube.com	TRUE	/	TRUE	0	VISITOR_ID	xxxxxxxxxxx
```

Sinon, les extensions de navigateur exportent automatiquement dans ce format.
