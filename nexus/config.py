"""Chemins, réglages persistants et options yt-dlp communes."""
import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
SUR_SERVEUR = os.getenv("RENDER") == "true"


def _dossier_xdg(nom, defaut):
    try:
        r = subprocess.run(["xdg-user-dir", nom], capture_output=True, text=True, timeout=2)
        chemin = r.stdout.strip()
        if r.returncode == 0 and chemin and chemin != str(Path.home()):
            return Path(chemin)
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.home() / defaut


if SUR_SERVEUR:
    DONNEES = Path("/tmp/yt-nexus")
    CONFIG = DONNEES
    DOSSIER_DEFAUT = DONNEES / "telechargements"
else:
    DONNEES = Path(os.getenv("XDG_DATA_HOME", Path.home() / ".local/share")) / "yt-nexus"
    CONFIG = Path(os.getenv("XDG_CONFIG_HOME", Path.home() / ".config")) / "yt-nexus"
    DOSSIER_DEFAUT = _dossier_xdg("DOWNLOAD", "Downloads") / "YT-NEXUS"

for d in (DONNEES, CONFIG):
    d.mkdir(parents=True, exist_ok=True)

FICHIER_REGLAGES = CONFIG / "reglages.json"
FICHIER_COOKIES = CONFIG / "cookies.txt"
FICHIER_TACHES = DONNEES / "taches.json"
CACHE_INFOS = DONNEES / "infos"
CACHE_INFOS.mkdir(exist_ok=True)

REGLAGES_DEFAUT = {
    "dossier": str(DOSSIER_DEFAUT),
    "simultanes": 2,               # téléchargements en parallèle
    "langue_audio": "fr",          # piste doublée voulue ("original" = VO)
    "garder_vo": True,             # garder la VO en 2e piste
    "sous_titres_secours": True,   # pas de doublage → sous-titres intégrés
    "type": "video",
    "qualite": "best",
    "conteneur": "mp4",
    "format_audio": "mp3",
    "qualite_audio": "0",          # 0 = meilleure (VBR) ; sinon kbps
    "sponsorblock": False,
    "miniature": True,
    "metadonnees": True,
    "fragments": 4,
    "limite_vitesse": "",          # ex. "2M"
    "cookies_navigateur": "",      # firefox, chrome, chromium, brave…
    "modele_nom": "%(title)s [%(id)s].%(ext)s",
    "sous_dossier_playlist": True,
    "notifications": True,
    "relances": 4,                 # nouvelles tentatives automatiques
}

_verrou = threading.Lock()


def _migrer_ancien():
    """Reprend le dossier et le nombre de téléchargements de la v7."""
    ancien = Path.home() / ".yt-nexus-v4-settings.json"
    r = {}
    try:
        a = json.loads(ancien.read_text())
        if a.get("download_dir"):
            r["dossier"] = a["download_dir"]
        if a.get("preferred_format") in ("mp4", "mkv", "webm"):
            r["conteneur"] = a["preferred_format"]
        if a.get("speed_limit"):
            r["limite_vitesse"] = a["speed_limit"]
    except (OSError, ValueError):
        pass
    vieux_cookies = RACINE / "cookies.txt"
    if vieux_cookies.exists() and not FICHIER_COOKIES.exists():
        shutil.copy2(vieux_cookies, FICHIER_COOKIES)
        os.chmod(FICHIER_COOKIES, 0o600)
    return r


def lire_reglages():
    with _verrou:
        try:
            r = json.loads(FICHIER_REGLAGES.read_text())
        except (OSError, ValueError):
            r = _migrer_ancien()
            FICHIER_REGLAGES.write_text(json.dumps({**REGLAGES_DEFAUT, **r}, indent=2, ensure_ascii=False))
    return {**REGLAGES_DEFAUT, **{k: v for k, v in r.items() if k in REGLAGES_DEFAUT}}


def ecrire_reglages(modifs):
    r = lire_reglages()
    for k, v in modifs.items():
        if k not in REGLAGES_DEFAUT:
            continue
        defaut = REGLAGES_DEFAUT[k]
        if isinstance(defaut, bool):
            v = bool(v)
        elif isinstance(defaut, int):
            try:
                v = int(v)
            except (TypeError, ValueError):
                continue
        else:
            v = str(v or "").strip()
        r[k] = v
    r["simultanes"] = max(1, min(8, r["simultanes"]))
    r["fragments"] = max(1, min(16, r["fragments"]))
    r["relances"] = max(0, min(10, r["relances"]))
    if not r["dossier"]:
        r["dossier"] = str(DOSSIER_DEFAUT)
    if "%(ext)s" not in r["modele_nom"]:
        r["modele_nom"] = REGLAGES_DEFAUT["modele_nom"]
    with _verrou:
        tmp = FICHIER_REGLAGES.with_suffix(".tmp")
        tmp.write_text(json.dumps(r, indent=2, ensure_ascii=False))
        tmp.replace(FICHIER_REGLAGES)
    return r


def dossier_telechargement(reglages=None):
    d = Path((reglages or lire_reglages())["dossier"]).expanduser()
    d.mkdir(parents=True, exist_ok=True)
    return d


def options_auth(reglages=None):
    """Options yt-dlp (API) pour l'authentification."""
    r = reglages or lire_reglages()
    o = {}
    if r.get("cookies_navigateur"):
        o["cookiesfrombrowser"] = (r["cookies_navigateur"],)
    elif FICHIER_COOKIES.exists() and FICHIER_COOKIES.stat().st_size > 100:
        o["cookiefile"] = str(FICHIER_COOKIES)
    return o


def args_auth(reglages=None):
    """Mêmes options, en arguments de ligne de commande."""
    r = reglages or lire_reglages()
    if r.get("cookies_navigateur"):
        return ["--cookies-from-browser", r["cookies_navigateur"]]
    if FICHIER_COOKIES.exists() and FICHIER_COOKIES.stat().st_size > 100:
        return ["--cookies", str(FICHIER_COOKIES)]
    return []


def commande_ytdlp():
    return [sys.executable, "-m", "yt_dlp"]
