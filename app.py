#!/usr/bin/env python3
"""
YT-NEXUS AETHER v7.0 ULTRA PREMIUM — Flask + yt-dlp
- Multi-plateformes (YouTube, TikTok, Instagram, Twitter/X, Vimeo, …)
- Turbo fragments, queue, batch, playlist
- Aperçu/stream sécurisé par download_id, profils, sous-titres multi-langues
- v7: SponsorBlock, watch later, schedule, disk stats

Note: les sections Bibliothèque média, Moniteur de chaînes et Fichiers ont
été retirées à la demande — le code correspondant (backend + frontend) a
été supprimé, pas seulement masqué.
"""

APP_VERSION = "7.0.0"

import os
import json
import re
import threading
import time
import subprocess
import shutil
import hashlib
import platform
import signal
import sys
from pathlib import Path
from flask import Flask, request, jsonify, Response, send_from_directory
from flask_cors import CORS

app = Flask(__name__, static_folder='static')
CORS(app)

# ─── CONFIG ──────────────────────────────────────────────────
RENDER_ENV = os.getenv('RENDER') == 'true'

if RENDER_ENV:
    DEFAULT_DOWNLOAD_DIR = Path('/tmp/yt-nexus-downloads')
    SETTINGS_FILE = Path('/tmp/.yt-nexus-v4-settings.json')
else:
    DEFAULT_DOWNLOAD_DIR = Path.home() / 'Downloads' / 'YT-NEXUS'
    SETTINGS_FILE = Path.home() / '.yt-nexus-v4-settings.json'

def load_settings():
    try:
        if SETTINGS_FILE.exists():
            with open(SETTINGS_FILE) as f:
                return json.load(f)
    except:
        pass
    return {
        'download_dir': str(DEFAULT_DOWNLOAD_DIR),
        'concurrent_downloads': 3,  # Augmenté à 3 téléchargements simultanés
        'auto_update_ytdlp': True,  # Auto-update activé par défaut
        'preferred_format': 'mp4',
        'preferred_quality': 'best',
        'theme': 'dark',
        'notifications': True,
        'speed_limit': '',  # Pas de limite par défaut pour vitesse max
        'turbo_default': True,  # Mode turbo activé par défaut
        'turbo_fragments': 16,  # 16 connexions par défaut
    }

def save_settings(data):
    try:
        with open(SETTINGS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
        return True
    except:
        return False

def get_download_dir():
    s = load_settings()
    d = Path(s.get('download_dir', str(DEFAULT_DOWNLOAD_DIR)))
    d.mkdir(parents=True, exist_ok=True)
    return d

# ─── CACHE POUR LES INFOS VIDÉO ─────────────────────────────────────
video_info_cache = {}
CACHE_DURATION = 3600  # 1 heure

def get_cached_video_info(url):
    """Récupérer les infos vidéo du cache si disponible et valide"""
    cache_key = hashlib.md5(url.encode()).hexdigest()
    if cache_key in video_info_cache:
        cached_data, timestamp = video_info_cache[cache_key]
        if time.time() - timestamp < CACHE_DURATION:
            return cached_data
        else:
            # Cache expiré, supprimer
            del video_info_cache[cache_key]
    return None

def set_cached_video_info(url, data):
    """Mettre en cache les infos vidéo"""
    cache_key = hashlib.md5(url.encode()).hexdigest()
    video_info_cache[cache_key] = (data, time.time())
    # Limiter la taille du cache
    if len(video_info_cache) > 100:
        # Supprimer l'entrée la plus ancienne
        oldest_key = min(video_info_cache.keys(), key=lambda k: video_info_cache[k][1])
        del video_info_cache[oldest_key]

# ─── STATE ───────────────────────────────────────────────────
class ProgressDict(dict):
    """Dict thread-safe pour downloads_progress.

    Plusieurs threads (téléchargement en cours, suppression, cleanup,
    retry...) lisent/écrivent cette structure en parallèle. Avant, un
    thread de téléchargement qui faisait `downloads_progress[id][...] = x`
    après qu'un autre thread ait fait `.pop(id)` provoquait un KeyError
    fatal et faisait planter le thread (et parfois la requête HTTP qui
    l'avait déclenché). Ici, un accès à un id manquant recrée silencieusement
    une entrée minimale au lieu de lever une exception, et toutes les
    opérations sont protégées par un verrou.
    """
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._lock = threading.RLock()

    def __getitem__(self, key):
        with self._lock:
            if not super().__contains__(key):
                super().__setitem__(key, {'status': 'unknown', 'percent': 0})
            return super().__getitem__(key)

    def __setitem__(self, key, value):
        with self._lock:
            super().__setitem__(key, value)

    def __delitem__(self, key):
        with self._lock:
            super().__delitem__(key)

    def __contains__(self, key):
        with self._lock:
            return super().__contains__(key)

    def pop(self, key, *default):
        with self._lock:
            return super().pop(key, *default)

    def get(self, key, default=None):
        with self._lock:
            return super().get(key, default)

    def items(self):
        with self._lock:
            return list(super().items())

    def values(self):
        with self._lock:
            return list(super().values())

    def keys(self):
        with self._lock:
            return list(super().keys())

    def update(self, *args, **kwargs):
        with self._lock:
            return super().update(*args, **kwargs)

    def setdefault(self, key, default=None):
        with self._lock:
            return super().setdefault(key, default)


downloads_progress = ProgressDict()
downloads_history = []
active_procs = {}
paused_ids = set()
# IDs et chemins de fichiers partiels explicitement supprimés par l'utilisateur
# (évite qu'ils réapparaissent au scan disque / redémarrage)
dismissed_download_ids = set()
dismissed_partial_paths = set()

ACTIVE_STATUSES = {'queued', 'starting', 'downloading', 'merging', 'converting', 'retrying', 'resuming'}
RETRYABLE_STATUSES = {'failed', 'error', 'stopped', 'paused', 'restored', 'incomplete'}
TERMINAL_STATUSES = {'done', 'failed', 'error', 'stopped'}
PARTIAL_SUFFIXES = ('.part', '.ytdl', '.aria2')

# Chemins absolus (indépendants du cwd au lancement)
_APP_DIR = Path(__file__).resolve().parent
STATE_FILE = _APP_DIR / 'downloads_state.json'
DISMISSED_FILE = _APP_DIR / 'dismissed_downloads.json'
_state_lock = threading.Lock()

def format_bytes(num_bytes):
    try:
        size = float(num_bytes or 0)
    except:
        return '—'
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    idx = 0
    while size >= 1024 and idx < len(units) - 1:
        size /= 1024
        idx += 1
    if idx == 0:
        return f'{int(size)} {units[idx]}'
    return f'{size:.1f} {units[idx]}'

def is_partial_file(path):
    name = path.name.lower()
    return path.is_file() and (path.suffix.lower() in PARTIAL_SUFFIXES or any(name.endswith(s) for s in PARTIAL_SUFFIXES))

def partial_matches_download(part_path, info):
    filename = (info.get('filename') or '').strip()
    title = (info.get('title') or '').strip()
    part_name = part_path.name.lower()
    if filename:
        fn = Path(filename).name.lower()
        if fn and (fn in part_name or part_name.startswith(fn)):
            return True
        stem = Path(filename).stem.lower()
        if stem and len(stem) > 8 and stem in part_name:
            return True
    if title:
        safe_title = re.sub(r'[^a-z0-9]+', ' ', title.lower()).strip()
        safe_part = re.sub(r'[^a-z0-9]+', ' ', part_name).strip()
        if safe_title and len(safe_title) > 8 and safe_title[:40] in safe_part:
            return True
    return False

def scan_incomplete_downloads():
    """Detect partial files in the configured download folder and attach retry metadata when possible."""
    download_dir = get_download_dir()
    partials = []
    try:
        partials = [p for p in download_dir.rglob('*') if is_partial_file(p)]
    except Exception as e:
        print(f'Erreur scan fichiers incomplets: {e}')
        return []

    incomplete_items = []
    matched_paths = set()

    for dl_id, info in list(downloads_progress.items()):
        if dl_id in dismissed_download_ids:
            continue
        matched = []
        info_dir = Path(info.get('download_dir', download_dir))
        for part in partials:
            try:
                if part in matched_paths:
                    continue
                try:
                    part.relative_to(info_dir)
                except ValueError:
                    continue
                if partial_matches_download(part, info):
                    matched.append(part)
                    matched_paths.add(part)
            except:
                continue
        if matched:
            total_size = sum((part.stat().st_size for part in matched if part.exists()), 0)
            info['partial_files'] = [{'name': part.name, 'path': str(part), 'size': format_bytes(part.stat().st_size)} for part in matched if part.exists()]
            info['partial_size'] = format_bytes(total_size)
            info['can_retry'] = bool(info.get('url') and info.get('opts'))
            if info.get('status') in ('done',):
                continue
            if info.get('status') not in ACTIVE_STATUSES and info.get('status') not in RETRYABLE_STATUSES:
                info['status'] = 'incomplete'

    for part in partials:
        if part in matched_paths:
            continue
        try:
            part_resolved = str(part.resolve())
            # Ne pas ressusciter les partiels explicitement supprimés
            if part_resolved in dismissed_partial_paths or str(part) in dismissed_partial_paths:
                continue
            orphan_id = 'incomplete_' + hashlib.md5(part_resolved.encode()).hexdigest()[:12]
            if orphan_id in dismissed_download_ids:
                continue
            stat = part.stat()
            incomplete_items.append({
                'id': orphan_id,
                'status': 'incomplete',
                'percent': 0,
                'speed': '—',
                'downloaded': format_bytes(stat.st_size),
                'total': '—',
                'eta': '—',
                'filename': part.name,
                'title': part.name.replace('.part', '').replace('.ytdl', '').replace('.aria2', ''),
                'type': 'single',
                'format_type': 'unknown',
                'started': stat.st_mtime,
                'download_dir': str(download_dir),
                'partial_files': [{'name': part.name, 'path': str(part), 'size': format_bytes(stat.st_size)}],
                'partial_size': format_bytes(stat.st_size),
                'can_retry': False,
                'error': 'Fichier incomplet détecté, mais URL d’origine absente. Relancez depuis l’URL pour reprendre.',
            })
        except:
            pass
    return incomplete_items
_search_cache = {}  # cache pagination recherche: {md5(query): {query, items, ts}}

# ─── DIAGNOSTICS ─────────────────────────────────────────────
def check_dependencies():
    """Vérifie toutes les dépendances système"""
    deps = {}
    
    # yt-dlp
    try:
        r = subprocess.run(['yt-dlp', '--version'], capture_output=True, text=True, timeout=5)
        deps['yt_dlp'] = {'ok': r.returncode == 0, 'version': r.stdout.strip(), 'path': shutil.which('yt-dlp')}
    except:
        deps['yt_dlp'] = {'ok': False, 'version': None, 'path': None}
    
    # ffmpeg
    try:
        r = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, timeout=5)
        ver_line = r.stdout.split('\n')[0] if r.stdout else ''
        ver_match = re.search(r'version\s+(\S+)', ver_line)
        deps['ffmpeg'] = {'ok': r.returncode == 0, 'version': ver_match.group(1) if ver_match else 'unknown', 'path': shutil.which('ffmpeg')}
    except:
        deps['ffmpeg'] = {'ok': False, 'version': None, 'path': None}
    
    # ffprobe
    try:
        r = subprocess.run(['ffprobe', '-version'], capture_output=True, text=True, timeout=5)
        deps['ffprobe'] = {'ok': r.returncode == 0, 'path': shutil.which('ffprobe')}
    except:
        deps['ffprobe'] = {'ok': False, 'path': None}
    
    # aria2c (pour téléchargements directs ultra-rapides)
    try:
        r = subprocess.run(['aria2c', '--version'], capture_output=True, text=True, timeout=5)
        ver_line = r.stdout.split('\n')[0] if r.stdout else ''
        ver_match = re.search(r'aria2\s+version\s+(\S+)', ver_line)
        deps['aria2c'] = {'ok': r.returncode == 0, 'version': ver_match.group(1) if ver_match else 'unknown', 'path': shutil.which('aria2c')}
    except:
        deps['aria2c'] = {'ok': False, 'version': None, 'path': None}
        # Tenter d'installer aria2c en arrière-plan (non-bloquant : peut prendre
        # plusieurs dizaines de secondes selon le gestionnaire de paquets, et ne
        # doit jamais retarder le démarrage du serveur ni une requête HTTP).
        threading.Thread(target=install_aria2c, daemon=True).start()

    return deps

def get_ydl_path():
    """Trouve le chemin de yt-dlp"""
    return shutil.which('yt-dlp') or 'yt-dlp'

# ─── LANGUAGE MAP ────────────────────────────────────────────
LANG_NAMES = {
    'ab': 'Abkhaze', 'aa': 'Afar', 'af': 'Afrikaans', 'ak': 'Akan',
    'sq': 'Albanais', 'am': 'Amharique', 'ar': 'Arabe', 'an': 'Aragonais',
    'hy': 'Arménien', 'as': 'Assamais', 'av': 'Avar', 'ay': 'Aymara',
    'az': 'Azéri', 'bm': 'Bambara', 'ba': 'Bachkir', 'eu': 'Basque',
    'be': 'Biélorusse', 'bn': 'Bengali', 'bho': 'Bhodjpouri', 'bs': 'Bosniaque',
    'br': 'Breton', 'bg': 'Bulgare', 'my': 'Birman', 'ca': 'Catalan',
    'ceb': 'Cebuano', 'ch': 'Chamorro', 'ce': 'Tchétchène', 'zh': 'Chinois',
    'zh-hans': 'Chinois simplifié', 'zh-hant': 'Chinois traditionnel',
    'co': 'Corse', 'cr': 'Cri', 'hr': 'Croate', 'cs': 'Tchèque',
    'da': 'Danois', 'dv': 'Maldivien', 'nl': 'Néerlandais', 'dz': 'Dzongkha',
    'en': 'Anglais', 'eo': 'Espéranto', 'et': 'Estonien', 'ee': 'Éwé',
    'fo': 'Féroïen', 'fj': 'Fidjien', 'fil': 'Filipino', 'fi': 'Finnois',
    'fr': 'Français', 'fy': 'Frison', 'ff': 'Peul', 'gl': 'Galicien',
    'ka': 'Géorgien', 'de': 'Allemand', 'el': 'Grec', 'gn': 'Guarani',
    'gu': 'Gujarati', 'ht': 'Créole haïtien', 'ha': 'Haoussa', 'haw': 'Hawaïen',
    'he': 'Hébreu', 'iw': 'Hébreu', 'hi': 'Hindi', 'hmn': 'Hmong',
    'hu': 'Hongrois', 'is': 'Islandais', 'ig': 'Igbo', 'id': 'Indonésien',
    'ga': 'Irlandais', 'it': 'Italien', 'ja': 'Japonais', 'jv': 'Javanais',
    'kn': 'Kannada', 'kk': 'Kazakh', 'km': 'Khmer', 'rw': 'Kinyarwanda',
    'ko': 'Coréen', 'ku': 'Kurde', 'ky': 'Kirghize', 'lo': 'Lao',
    'la': 'Latin', 'lv': 'Letton', 'ln': 'Lingala', 'lt': 'Lituanien',
    'lb': 'Luxembourgeois', 'mk': 'Macédonien', 'mg': 'Malgache',
    'ms': 'Malais', 'ml': 'Malayalam', 'mt': 'Maltais', 'mi': 'Maori',
    'mr': 'Marathi', 'mn': 'Mongol', 'ne': 'Népalais', 'no': 'Norvégien',
    'nb': 'Norvégien bokmål', 'nn': 'Norvégien nynorsk', 'ny': 'Chichewa',
    'or': 'Odia', 'om': 'Oromo', 'ps': 'Pachto', 'fa': 'Persan',
    'pl': 'Polonais', 'pt': 'Portugais', 'pa': 'Pendjabi', 'qu': 'Quechua',
    'ro': 'Roumain', 'ru': 'Russe', 'sm': 'Samoan', 'sa': 'Sanskrit',
    'gd': 'Gaélique écossais', 'sr': 'Serbe', 'sn': 'Shona', 'sd': 'Sindhi',
    'si': 'Cingalais', 'sk': 'Slovaque', 'sl': 'Slovène', 'so': 'Somali',
    'st': 'Sesotho', 'es': 'Espagnol', 'su': 'Soundanais', 'sw': 'Swahili',
    'sv': 'Suédois', 'tg': 'Tadjik', 'ta': 'Tamoul', 'tt': 'Tatar',
    'te': 'Télougou', 'th': 'Thaï', 'ti': 'Tigrinya', 'to': 'Tongien',
    'tr': 'Turc', 'tk': 'Turkmène', 'uk': 'Ukrainien', 'ur': 'Ourdou',
    'ug': 'Ouïghour', 'uz': 'Ouzbek', 'vi': 'Vietnamien', 'cy': 'Gallois',
    'wo': 'Wolof', 'xh': 'Xhosa', 'yi': 'Yiddish', 'yo': 'Yoruba',
    'zu': 'Zoulou',
}

LANG_FLAGS = {
    'af': '🇿🇦', 'ar': '🇸🇦', 'az': '🇦🇿', 'be': '🇧🇾', 'bg': '🇧🇬',
    'bn': '🇧🇩', 'bs': '🇧🇦', 'ca': '🏳️', 'cs': '🇨🇿', 'da': '🇩🇰',
    'de': '🇩🇪', 'el': '🇬🇷', 'en': '🇬🇧', 'es': '🇪🇸', 'et': '🇪🇪',
    'eu': '🏳️', 'fa': '🇮🇷', 'fi': '🇫🇮', 'fil': '🇵🇭', 'fr': '🇫🇷',
    'ga': '🇮🇪', 'gl': '🇪🇸', 'gu': '🇮🇳', 'ha': '🇳🇬', 'he': '🇮🇱',
    'hi': '🇮🇳', 'hr': '🇭🇷', 'hu': '🇭🇺', 'hy': '🇦🇲', 'id': '🇮🇩',
    'is': '🇮🇸', 'it': '🇮🇹', 'ja': '🇯🇵', 'ka': '🇬🇪', 'kk': '🇰🇿',
    'km': '🇰🇭', 'kn': '🇮🇳', 'ko': '🇰🇷', 'ky': '🇰🇬', 'lo': '🇱🇦',
    'lt': '🇱🇹', 'lv': '🇱🇻', 'mk': '🇲🇰', 'ml': '🇮🇳', 'mn': '🇲🇳',
    'mr': '🇮🇳', 'ms': '🇲🇾', 'my': '🇲🇲', 'ne': '🇳🇵', 'nl': '🇳🇱',
    'no': '🇳🇴', 'nb': '🇳🇴', 'nn': '🇳🇴', 'pa': '🇮🇳', 'pl': '🇵🇱',
    'pt': '🇵🇹', 'ro': '🇷🇴', 'ru': '🇷🇺', 'si': '🇱🇰', 'sk': '🇸🇰',
    'sl': '🇸🇮', 'so': '🇸🇴', 'sq': '🇦🇱', 'sr': '🇷🇸', 'sv': '🇸🇪',
    'sw': '🇹🇿', 'ta': '🇮🇳', 'te': '🇮🇳', 'th': '🇹🇭', 'tr': '🇹🇷',
    'uk': '🇺🇦', 'ur': '🇵🇰', 'uz': '🇺🇿', 'vi': '🇻🇳', 'zh': '🇨🇳',
    'zh-hans': '🇨🇳', 'zh-hant': '🇹🇼', 'zu': '🇿🇦',
}

def get_lang_name(code):
    if not code:
        return 'Inconnue'
    normalized = str(code).strip().lower().replace('_', '-')
    parts = normalized.split('-')
    base = parts[0]
    name = LANG_NAMES.get(normalized) or LANG_NAMES.get(base)
    if not name:
        return str(code).upper()
    if len(parts) > 1 and normalized not in LANG_NAMES:
        region = '-'.join(parts[1:]).upper()
        return f'{name} ({region})'
    return name

def country_code_to_flag(country_code):
    if not country_code or len(country_code) != 2 or not country_code.isalpha():
        return None
    base = 127397
    return ''.join(chr(base + ord(char)) for char in country_code.upper())

def get_lang_flag(code):
    if not code:
        return '🌐'
    normalized = str(code).strip().lower().replace('_', '-')
    parts = normalized.split('-')
    if len(parts) > 1:
        region_flag = country_code_to_flag(parts[-1])
        if region_flag:
            return region_flag
    return LANG_FLAGS.get(normalized) or LANG_FLAGS.get(parts[0]) or '🌐'

def build_subtitle_langs(subtitles, auto_captions):
    # Keep yt-dlp language codes as values, but expose readable labels for the UI.
    results = []
    seen = set()
    for source, langs in (('manual', subtitles or {}), ('auto', auto_captions or {})):
        for code in langs.keys():
            if not code:
                continue
            clean_code = str(code).strip()
            key = clean_code.lower()
            if key in seen:
                continue
            seen.add(key)
            suffix = 'Sous-titres' if source == 'manual' else 'Auto'
            results.append({
                'code': clean_code,
                'name': get_lang_name(clean_code),
                'flag': get_lang_flag(clean_code),
                'type': source,
                'label': f'{get_lang_name(clean_code)} ({suffix})',
            })
    return sorted(results, key=lambda item: (item['type'] != 'manual', item['name'].lower(), item['code'].lower()))

def install_aria2c():
    """Installer aria2c automatiquement pour des téléchargements ultra-rapides"""
    try:
        # Vérifier si aria2c est déjà installé
        if shutil.which('aria2c'):
            return True

        print("Installation automatique d'aria2c pour performances maximales...")

        # Détecter le système d'exploitation
        system = platform.system().lower()

        if system == 'linux':
            # Essayer différents gestionnaires de paquets
            for cmd in [
                ['apt-get', 'update'],
                ['apt-get', 'install', '-y', 'aria2'],
                ['yum', 'install', '-y', 'aria2'],
                ['dnf', 'install', '-y', 'aria2'],
                ['pacman', '-S', '--noconfirm', 'aria2'],
                ['zypper', 'install', '-y', 'aria2']
            ]:
                try:
                    result = subprocess.run(cmd, capture_output=True, timeout=60)
                    if result.returncode == 0:
                        print("aria2c installé avec succès !")
                        return True
                except:
                    continue

        elif system == 'darwin':  # macOS
            try:
                result = subprocess.run(['brew', 'install', 'aria2'], capture_output=True, timeout=120)
                if result.returncode == 0:
                    print("aria2c installé avec succès sur macOS !")
                    return True
            except:
                pass

        elif system == 'windows':
            # Sur Windows, aria2c pourrait être disponible via choco ou scoop
            try:
                result = subprocess.run(['choco', 'install', 'aria2', '-y'], capture_output=True, timeout=120)
                if result.returncode == 0:
                    print("aria2c installé avec succès sur Windows !")
                    return True
            except:
                pass

        print("Impossible d'installer aria2c automatiquement. Utilisation de wget/curl.")
        return False

    except Exception as e:
        print(f"Erreur lors de l'installation d'aria2c: {e}")
        return False

# ─── SUPPORTED PLATFORMS ─────────────────────────────────────
SUPPORTED_PLATFORMS = {
    # Streaming/Video Platforms
    'youtube.com': {'name': 'YouTube', 'icon': '▶️', 'color': '#ff0000'},
    'youtu.be': {'name': 'YouTube', 'icon': '▶️', 'color': '#ff0000'},
    'tiktok.com': {'name': 'TikTok', 'icon': '🎵', 'color': '#010101'},
    'instagram.com': {'name': 'Instagram', 'icon': '📸', 'color': '#e1306c'},
    'twitter.com': {'name': 'Twitter/X', 'icon': '🐦', 'color': '#1da1f2'},
    'x.com': {'name': 'Twitter/X', 'icon': '🐦', 'color': '#000000'},
    'vimeo.com': {'name': 'Vimeo', 'icon': '🎬', 'color': '#1ab7ea'},
    'dailymotion.com': {'name': 'Dailymotion', 'icon': '🎥', 'color': '#0066dc'},
    'twitch.tv': {'name': 'Twitch', 'icon': '🎮', 'color': '#9146ff'},
    'soundcloud.com': {'name': 'SoundCloud', 'icon': '🎵', 'color': '#ff5500'},
    'reddit.com': {'name': 'Reddit', 'icon': '🤖', 'color': '#ff4500'},
    'facebook.com': {'name': 'Facebook', 'icon': '👍', 'color': '#1877f2'},
    'fb.com': {'name': 'Facebook', 'icon': '👍', 'color': '#1877f2'},
    'bilibili.com': {'name': 'Bilibili', 'icon': '📺', 'color': '#00a1d6'},
    'nicovideo.jp': {'name': 'Niconico', 'icon': '🎌', 'color': '#ffffff'},

    # Direct Download Sites
    'mediafire.com': {'name': 'MediaFire', 'icon': '📁', 'color': '#0066ff'},
    'mega.nz': {'name': 'Mega', 'icon': '🔒', 'color': '#d90007'},
    'dropbox.com': {'name': 'Dropbox', 'icon': '📦', 'color': '#0061ff'},
    'drive.google.com': {'name': 'Google Drive', 'icon': '📊', 'color': '#4285f4'},
    'onedrive.live.com': {'name': 'OneDrive', 'icon': '☁️', 'color': '#0078d4'},
    'github.com': {'name': 'GitHub', 'icon': '🐙', 'color': '#181717'},
    'sourceforge.net': {'name': 'SourceForge', 'icon': '🔧', 'color': '#ff6600'},
    'archive.org': {'name': 'Internet Archive', 'icon': '🏛️', 'color': '#666666'},

    # General Download Links
    'direct': {'name': 'Téléchargement Direct', 'icon': '⬇️', 'color': '#00ff00'},
    'http': {'name': 'Lien HTTP', 'icon': '🌐', 'color': '#0066cc'},
    'https': {'name': 'Lien HTTPS', 'icon': '🔒', 'color': '#00aa00'},
}

def detect_platform(url):
    """Détecte la plateforme d'une URL"""
    try:
        from urllib.parse import urlparse
        parsed = urlparse(url.lower())
        domain = parsed.netloc.replace('www.', '')

        # Chercher dans les plateformes supportées
        for platform_domain, platform_info in SUPPORTED_PLATFORMS.items():
            if platform_domain in domain:
                return platform_info

        # Si c'est un lien direct (fichier avec extension)
        path = parsed.path.lower()
        if any(ext in path for ext in ['.zip', '.rar', '.7z', '.tar.gz', '.exe', '.msi', '.dmg', '.pkg', '.deb', '.rpm', '.iso', '.img']):
            return SUPPORTED_PLATFORMS.get('direct', {'name': 'Direct', 'icon': '⬇️', 'color': '#00ff00'})

        # Par défaut, considérer comme lien HTTP/HTTPS
        if parsed.scheme == 'https':
            return SUPPORTED_PLATFORMS.get('https', {'name': 'HTTPS', 'icon': '🔒', 'color': '#00aa00'})
        else:
            return SUPPORTED_PLATFORMS.get('http', {'name': 'HTTP', 'icon': '🌐', 'color': '#0066cc'})

    except:
        return {'name': 'Inconnu', 'icon': '❓', 'color': '#666666'}

def download_direct_file(url, output_path, progress_callback=None):
    """Télécharge un fichier direct avec aria2c pour performances maximales"""
    try:
        # Essayer aria2c d'abord (ultra-rapide avec multi-connexions)
        if shutil.which('aria2c'):
            cmd = [
                'aria2c',
                '--max-connection-per-server=16',  # 16 connexions par serveur
                '--split=16',                      # 16 splits
                '--min-split-size=1M',             # Taille minimale de split
                '--max-tries=10',                  # 10 tentatives
                '--retry-wait=1',                  # Attente 1s entre retries
                '--timeout=120',                   # Timeout 2 minutes
                '--allow-overwrite=true',
                '--auto-file-renaming=false',
                '--continue=true',                 # Reprise automatique
                '--out', output_path,
                url
            ]

            if progress_callback:
                # Pour la progression avec aria2c, on peut utiliser --on-download-complete
                # mais pour simplifier, on lance le processus et on surveille la taille du fichier
                pass

            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            return proc

        # Fallback vers wget si aria2c n'est pas disponible
        elif shutil.which('wget'):
            cmd = [
                'wget',
                '--continue',                      # Reprise
                '--tries=10',                     # 10 tentatives
                '--timeout=120',                  # Timeout
                '--output-document', output_path,
                url
            ]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            return proc

        # Fallback vers curl
        elif shutil.which('curl'):
            cmd = [
                'curl',
                '--continue-at', '-',             # Reprise
                '--retry', '10',                  # 10 tentatives
                '--retry-delay', '1',             # Délai 1s
                '--max-time', '3600',             # Timeout 1 heure
                '--output', output_path,
                url
            ]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            return proc

        else:
            raise Exception("Aucun outil de téléchargement trouvé (aria2c, wget, curl)")

    except Exception as e:
        raise Exception(f"Erreur lors du téléchargement direct: {str(e)}")

def discover_downloadable_files(url, max_depth=2):
    """Découvre les fichiers téléchargeables sur une page web"""
    try:
        import requests
        from bs4 import BeautifulSoup
        import urllib.parse

        discovered_files = []
        visited_urls = set()

        def crawl_page(page_url, depth=0):
            if depth > max_depth or page_url in visited_urls:
                return
            visited_urls.add(page_url)

            try:
                headers = {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
                }
                response = requests.get(page_url, headers=headers, timeout=10, verify=False)
                response.raise_for_status()

                soup = BeautifulSoup(response.content, 'html.parser')

                # Chercher les liens de téléchargement
                for link in soup.find_all('a', href=True):
                    href = link['href']
                    full_url = urllib.parse.urljoin(page_url, href)

                    # Détecter les fichiers téléchargeables
                    if any(ext in href.lower() for ext in [
                        '.zip', '.rar', '.7z', '.tar.gz', '.tar.bz2', '.tar.xz',
                        '.exe', '.msi', '.dmg', '.pkg', '.deb', '.rpm',
                        '.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv',
                        '.mp3', '.wav', '.flac', '.aac', '.ogg',
                        '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
                        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp',
                        '.iso', '.img', '.dmg', '.vhd', '.vhdx'
                    ]):
                        file_info = {
                            'url': full_url,
                            'filename': os.path.basename(urllib.parse.urlparse(full_url).path),
                            'title': link.get_text().strip() or os.path.basename(href),
                            'platform': detect_platform(full_url),
                            'type': 'direct'
                        }
                        if file_info not in discovered_files:
                            discovered_files.append(file_info)

                # Chercher récursivement dans les sous-pages si depth permet
                if depth < max_depth:
                    for link in soup.find_all('a', href=True):
                        href = link['href']
                        full_url = urllib.parse.urljoin(page_url, href)

                        # Éviter les liens externes et les ancres
                        if (full_url.startswith(page_url.split('/')[0] + '//' + page_url.split('/')[2]) and
                            '#' not in href and
                            not href.startswith('mailto:') and
                            not href.startswith('javascript:')):
                            crawl_page(full_url, depth + 1)

            except Exception as e:
                print(f"Erreur lors du crawling de {page_url}: {e}")

        crawl_page(url)
        return discovered_files

    except ImportError:
        print("BeautifulSoup4 et requests requis pour la découverte de fichiers")
        return []

def monitor_download_progress(proc, download_id, url, opts):
    """Surveille la progression d'un téléchargement yt-dlp"""
    try:
        download_dir = get_download_dir()
        stderr_lines = []

        while proc.poll() is None:
            if download_id in paused_ids:
                proc.terminate()
                downloads_progress[download_id]['status'] = 'paused'
                active_procs.pop(download_id, None)
                return

            # Lire stderr pour les messages de progression yt-dlp
            if proc.stderr:
                line = proc.stderr.readline()
                if line:
                    line = line.strip()
                    stderr_lines.append(line)

                    # Analyser les messages de progression yt-dlp
                    if '[download]' in line:
                        progress_match = re.search(r'\[download\]\s+(\d+(?:\.\d+)?)%', line)
                        if progress_match:
                            percent = float(progress_match.group(1))
                            downloads_progress[download_id]['percent'] = percent

                        # Extraire la vitesse
                        speed_match = re.search(r'at\s+([\d\.]+\s*(?:KiB|MiB|GiB)/s)', line)
                        if speed_match:
                            downloads_progress[download_id]['speed'] = speed_match.group(1)

                        # Extraire la taille téléchargée
                        size_match = re.search(r'of\s+([\d\.]+\s*(?:KiB|MiB|GiB))', line)
                        if size_match:
                            downloads_progress[download_id]['downloaded'] = size_match.group(1)

                        # ETA
                        eta_match = re.search(r'ETA\s+([\d:]+)', line)
                        if eta_match:
                            downloads_progress[download_id]['eta'] = eta_match.group(1)

            time.sleep(0.3)  # Mise à jour SSE optimisée

        active_procs.pop(download_id, None)
        downloads_progress[download_id]['stderr_log'] = stderr_lines[-10:]

        if proc.returncode == 0:
            # Téléchargement réussi
            downloads_progress[download_id].update({
                'status': 'done',
                'percent': 100,
                'completed_at': time.time()
            })

            # Essayer de trouver le fichier final
            try:
                files = list(download_dir.glob("*"))
                files.sort(key=lambda x: x.stat().st_mtime, reverse=True)
                if files:
                    latest_file = files[0]
                    final_size = latest_file.stat().st_size
                    downloads_progress[download_id]['downloaded'] = f'{final_size / (1024*1024):.1f} MB'
                    downloads_progress[download_id]['filename'] = latest_file.name

                    # Ajouter à l'historique
                    downloads_history.insert(0, {
                        'id': download_id,
                        'url': url,
                        'title': downloads_progress[download_id].get('title', ''),
                        'filename': latest_file.name,
                        'quality': opts.get('format', 'best'),
                        'format': opts.get('ext', 'mp4'),
                        'type': 'video',
                        'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                        'dir': str(download_dir),
                        'platform': detect_platform(url),
                    })
                    if len(downloads_history) > 200:
                        downloads_history.pop()
            except Exception as e:
                print(f"Erreur lors de la finalisation: {e}")

        else:
            # Échec du téléchargement - marquer comme 'failed' pour permettre la reprise
            error_msg = format_error('\n'.join(stderr_lines), proc.returncode)
            downloads_progress[download_id].update({
                'status': 'failed',  # 'failed' au lieu de 'error' pour permettre la reprise
                'error': error_msg
            })

    except Exception as e:
        active_procs.pop(download_id, None)
        downloads_progress[download_id].update({
            'status': 'failed',
            'error': f'Erreur surveillance: {str(e)}'
        })

def run_ydl_download(url, opts, download_id):
    """Lance un téléchargement yt-dlp et retourne le processus"""
    download_dir = get_download_dir()
    cmd = build_ydl_cmd(url, opts, download_dir)
    
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True, bufsize=1
        )
        return proc
    except Exception as e:
        raise Exception(f"Erreur lancement yt-dlp: {str(e)}")

# ─── PERSISTENCE ─────────────────────────────────────────────
def save_dismissed():
    """Persiste les IDs/chemins supprimés par l'utilisateur."""
    try:
        payload = {
            'ids': sorted(dismissed_download_ids),
            'paths': sorted(dismissed_partial_paths),
            'updated': time.time(),
        }
        with open(DISMISSED_FILE, 'w', encoding='utf-8') as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"❌ Erreur sauvegarde dismissed: {e}")


def load_dismissed():
    global dismissed_download_ids, dismissed_partial_paths
    try:
        if not DISMISSED_FILE.exists():
            return
        with open(DISMISSED_FILE, 'r', encoding='utf-8') as f:
            data = json.load(f)
        dismissed_download_ids = set(data.get('ids') or [])
        dismissed_partial_paths = set(data.get('paths') or [])
        print(f"✅ Dismissed chargé: {len(dismissed_download_ids)} ids, {len(dismissed_partial_paths)} chemins")
    except Exception as e:
        print(f"❌ Erreur chargement dismissed: {e}")


def _collect_related_partial_paths(info):
    """Chemins de fichiers partiels liés à un téléchargement (pour dismissal)."""
    paths = set()
    for pf in (info or {}).get('partial_files') or []:
        p = pf.get('path') if isinstance(pf, dict) else None
        if p:
            try:
                paths.add(str(Path(p).resolve()))
            except Exception:
                paths.add(str(p))
    # Scan disque pour .part correspondants
    try:
        download_dir = Path(info.get('download_dir') or get_download_dir())
        for part in download_dir.rglob('*'):
            if not is_partial_file(part):
                continue
            if partial_matches_download(part, info or {}):
                try:
                    paths.add(str(part.resolve()))
                except Exception:
                    paths.add(str(part))
    except Exception:
        pass
    return paths


def dismiss_download_permanently(download_id, info=None, delete_partials=True):
    """
    Supprime définitivement un téléchargement de la liste + mémoire persistante.
    - Ajoute l'id à la blacklist
    - Blacklist les chemins .part associés
    - Optionnellement supprime les fichiers .part du disque
    """
    global downloads_progress, active_procs, paused_ids, download_queue

    info = info or downloads_progress.get(download_id) or {}
    partial_paths = _collect_related_partial_paths(info)

    # Stop process
    proc = active_procs.get(download_id)
    if proc:
        try:
            proc.terminate()
        except Exception:
            pass
    active_procs.pop(download_id, None)
    paused_ids.discard(download_id)

    # Retirer de la progression
    downloads_progress.pop(download_id, None)

    # Retirer de la file d'attente
    try:
        with queue_lock:
            download_queue[:] = [q for q in download_queue if q.get('id') != download_id]
    except Exception:
        pass

    # Blacklist permanente
    dismissed_download_ids.add(download_id)
    for p in partial_paths:
        dismissed_partial_paths.add(p)
        # Aussi l'id orphan stable pour ce chemin
        try:
            orphan_id = 'incomplete_' + hashlib.md5(p.encode()).hexdigest()[:12]
            dismissed_download_ids.add(orphan_id)
        except Exception:
            pass

    # Supprimer les fichiers partiels du disque (pas le fichier final terminé)
    deleted_files = []
    if delete_partials:
        for p in list(partial_paths):
            try:
                fp = Path(p)
                if fp.exists() and is_partial_file(fp):
                    fp.unlink()
                    deleted_files.append(str(fp))
            except Exception as e:
                print(f"⚠️ Impossible de supprimer {p}: {e}")

    save_dismissed()
    save_download_state()
    return {
        'removed': download_id,
        'dismissed_paths': list(partial_paths),
        'deleted_partials': deleted_files,
    }


def save_download_state():
    """Sauvegarde l'état des téléchargements dans un fichier JSON (chemin absolu)."""
    try:
        with _state_lock:
            # Sauvegarder uniquement les téléchargements non terminés / récupérables
            # et JAMAIS les ids dismissed
            active_state = {}
            for dl_id, info in downloads_progress.items():
                if dl_id in dismissed_download_ids:
                    continue
                if info.get('status') in ACTIVE_STATUSES or info.get('status') in RETRYABLE_STATUSES:
                    # Copie JSON-safe (évite sets non sérialisables)
                    try:
                        active_state[dl_id] = json.loads(json.dumps(info, default=str))
                    except Exception:
                        active_state[dl_id] = {k: v for k, v in info.items() if k != 'stderr_log'}

            state = {
                'downloads_progress': {},  # ne plus recharger l'ancien dump complet
                'downloads_history': downloads_history[:200],
                'timestamp': time.time(),
                'active_downloads': active_state,
            }

            tmp = str(STATE_FILE) + f'.tmp.{os.getpid()}'
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(state, f, indent=2, ensure_ascii=False)
                f.flush()
                try:
                    os.fsync(f.fileno())
                except OSError:
                    pass
            os.replace(tmp, STATE_FILE)

        print(f"✅ État sauvegardé: {len(active_state)} téléchargements actifs → {STATE_FILE}")
    except Exception as e:
        print(f"❌ Erreur sauvegarde état: {e}")


def load_download_state():
    """Charge l'état des téléchargements depuis le fichier JSON"""
    global downloads_progress, downloads_history

    load_dismissed()

    try:
        # Compat: ancien chemin relatif au cwd
        candidates = [STATE_FILE, Path('downloads_state.json').resolve()]
        state_path = next((p for p in candidates if p.exists()), None)
        if not state_path:
            print("ℹ️ Aucun état sauvegardé trouvé")
            return

        with open(state_path, 'r', encoding='utf-8') as f:
            state = json.load(f)

        # Restaurer l'historique
        if 'downloads_history' in state:
            downloads_history[:] = state['downloads_history']

        # Restaurer les téléchargements actifs (sauf dismissed)
        restored = 0
        if 'active_downloads' in state:
            for dl_id, info in (state.get('active_downloads') or {}).items():
                if dl_id in dismissed_download_ids:
                    continue
                if not isinstance(info, dict):
                    continue
                if info.get('status') in ACTIVE_STATUSES or info.get('status') in RETRYABLE_STATUSES:
                    info = dict(info)
                    info['status'] = 'restored'
                    info['restored_at'] = time.time()
                    downloads_progress[dl_id] = info
                    restored += 1

        saved_time = state.get('timestamp', 0)
        age_hours = (time.time() - saved_time) / 3600 if saved_time else 0
        print(f"✅ État chargé: {restored} téléchargements restaurés ({age_hours:.1f}h) depuis {state_path}")

        # Réécrire proprement au bon chemin absolu
        if state_path != STATE_FILE or restored != len(state.get('active_downloads') or {}):
            save_download_state()

    except Exception as e:
        print(f"❌ Erreur chargement état: {e}")

# ─── URL HELPERS ─────────────────────────────────────────────
def clean_url(url):
    url = url.strip()
    if not url:
        return ''
    if not url.startswith('http'):
        url = 'https://' + url
    # Clean YouTube tracking params but keep essential ones
    return url

def is_valid_url(url):
    return url.startswith('http') and '.' in url

def sanitize_folder_name(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name[:80] if name else 'Playlist'

# ─── BUILD YT-DLP COMMAND ─────────────────────────────────────
def build_format_selection(quality, fmt, audio_format_id='', audio_lang='', has_ffmpeg=True):
    """Construit une sélection de format robuste pour yt-dlp avec fallback."""
    q = str(quality or 'best').lower()
    fmt_lower = str(fmt or 'mp4').lower()
    merge_fmt = 'mp4'
    if 'webm' in fmt_lower:
        merge_fmt = 'webm'
    elif 'mkv' in fmt_lower:
        merge_fmt = 'mkv'

    if not has_ffmpeg:
        q_map = {
            '4k': 2160, '2160': 2160, '2k': 1440, '1440': 1440,
            '1080': 1080, '720': 720, '480': 480, '360': 360,
            '240': 240, '144': 144,
        }
        target_height = None
        for key, h in q_map.items():
            if key in q:
                target_height = h
                break
        return (f'best[height<={target_height}]' if target_height else 'best'), merge_fmt

    q_map = {
        '4k': 2160, '2160': 2160, '2k': 1440, '1440': 1440,
        '1080': 1080, '720': 720, '480': 480, '360': 360,
        '240': 240, '144': 144,
    }
    target_height = None
    for key, h in q_map.items():
        if key in q:
            target_height = h
            break

    if target_height:
        vid_sel = f'bestvideo[height<={target_height}]'
    elif 'worst' in q or 'lowest' in q:
        vid_sel = 'worstvideo'
    else:
        vid_sel = 'bestvideo'

    if audio_format_id:
        fmt_sel = f'{vid_sel}+{audio_format_id}/bestvideo+bestaudio/best'
    elif audio_lang and audio_lang not in ('', 'und', 'none'):
        fmt_sel = f'{vid_sel}+bestaudio[language={audio_lang}]/bestvideo+bestaudio/best'
    else:
        fmt_sel = f'{vid_sel}+bestaudio/best'

    return fmt_sel, merge_fmt


def build_ydl_cmd(url, opts, download_dir=None, filename_template=None):
    """Build yt-dlp command from options — version robuste avec fallbacks"""
    if download_dir is None:
        download_dir = get_download_dir()
    
    ydl = get_ydl_path()
    cmd = [ydl]

    # Ajouter les cookies si présents
    cookies_file = Path(__file__).parent / 'cookies.txt'
    if cookies_file.exists() and cookies_file.stat().st_size > 100:
        cmd += ['--cookies', str(cookies_file)]

    # Options YouTube pour Render/Internet (évite les blocages d'authentification)
    cmd += [
        '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        '--extractor-args', 'youtube:skip_unavailable_videos=true',
        '--extractor-args', 'youtube:player_client=web',
        '--socket-timeout', '30'
    ]

    dl_type = opts.get('type', 'video').lower()
    quality = str(opts.get('quality', 'best')).lower()
    fmt = opts.get('format', 'mp4').lower()
    dl_subs = opts.get('dl_subs', False)
    sub_lang = opts.get('sub_lang', 'fr')
    sub_format = opts.get('sub_format', 'srt')
    bitrate = opts.get('bitrate', '')
    speed_limit = opts.get('speed_limit', '') or load_settings().get('speed_limit', '')
    
    # Template de sortie
    tmpl = filename_template or f'{download_dir}/%(title)s.%(ext)s'
    cmd += ['-o', tmpl]
    
    # Vérifier si ffmpeg est disponible pour le merge
    has_ffmpeg = bool(shutil.which('ffmpeg'))
    
    if dl_type == 'audio':
        # Mode audio seul (extrait)
        audio_fmt = 'mp3'
        for af in ('mp3', 'm4a', 'opus', 'wav', 'flac', 'aac'):
            if af in fmt:
                audio_fmt = af
                break
        
        cmd += ['-x', '--audio-format', audio_fmt]
        
        # Support piste audio choisie aussi en mode audio
        audio_format_id = (opts.get('audio_format_id') or '').strip()
        audio_lang = (opts.get('audio_lang') or '').strip().lower()
        if audio_format_id:
            cmd += ['-f', audio_format_id]
        elif audio_lang:
            cmd += ['-f', f'bestaudio[language={audio_lang}]']
        
        if has_ffmpeg and audio_fmt in ('mp3', 'aac', 'm4a'):
            if bitrate and 'kbps' in bitrate:
                kbps = bitrate.replace(' kbps', '').strip()
                cmd += ['--audio-quality', f'{kbps}K']
            else:
                cmd += ['--audio-quality', '0']  # best quality
    else:
        # Mode vidéo
        audio_format_id = (opts.get('audio_format_id') or '').strip()
        audio_lang = (opts.get('audio_lang') or '').strip().lower()
        fmt_sel, merge_fmt = build_format_selection(quality, fmt, audio_format_id, audio_lang, has_ffmpeg)

        if has_ffmpeg:
            cmd += ['-f', fmt_sel, '--merge-output-format', merge_fmt]
        else:
            # Sans ffmpeg: format déjà fusionné (moins de qualité mais fonctionnel)
            cmd += ['-f', fmt_sel if fmt_sel.startswith('best') else 'best']
    
    # Sous-titres
    if dl_subs:
        cmd += ['--write-subs', '--write-auto-subs']
        if sub_lang:
            cmd += ['--sub-langs', sub_lang]
        if 'vtt' in sub_format:
            cmd += ['--sub-format', 'vtt']
        elif 'ttml' in sub_format:
            cmd += ['--sub-format', 'ttml']
        else:
            cmd += ['--sub-format', 'srt']
        if opts.get('embed_subs') and has_ffmpeg:
            cmd += ['--embed-subs']

    # Métadonnées / vignette (audio & vidéo)
    if opts.get('embed_metadata', True):
        cmd += ['--add-metadata']
    if opts.get('embed_thumbnail') and has_ffmpeg:
        cmd += ['--embed-thumbnail', '--convert-thumbnails', 'jpg']
    if opts.get('write_thumbnail'):
        cmd += ['--write-thumbnail']
    if opts.get('write_description'):
        cmd += ['--write-description']
    if opts.get('write_info_json'):
        cmd += ['--write-info-json']

    # SponsorBlock (YouTube) — retire les segments indésirables
    if opts.get('sponsorblock'):
        cats = opts.get('sponsorblock_cats') or 'sponsor,selfpromo,interaction,intro,outro'
        cats = str(cats).replace(' ', '')
        cmd += ['--sponsorblock-remove', cats]
    elif opts.get('sponsorblock_mark'):
        cats = opts.get('sponsorblock_cats') or 'sponsor,selfpromo,interaction'
        cmd += ['--sponsorblock-mark', str(cats).replace(' ', '')]

    # Chapters as split (option avancée)
    if opts.get('split_chapters') and has_ffmpeg:
        cmd += ['--split-chapters']
    
    # Limitations de vitesse
    if speed_limit and speed_limit.strip():
        cmd += ['--rate-limit', speed_limit.strip()]
    
    # ── Mode Turbo (connexions parallèles) ─────────────────────────
    # NB: on évite volontairement les valeurs extrêmes (32 fragments, chunks 4M)
    # qui déclenchent très vite un blocage "HTTP 429 - trop de requêtes" côté
    # YouTube. Ces réglages plus mesurés restent rapides tout en étant stables.
    turbo = opts.get('turbo', True)  # Turbo activé par défaut
    turbo_fragments = int(opts.get('turbo_fragments', 8))  # 8 connexions par défaut
    if turbo:
        n_frag = max(2, min(16, turbo_fragments))  # Minimum 2, maximum 16 connexions
        cmd += ['--concurrent-fragments', str(n_frag)]
        cmd += ['--http-chunk-size', '2M']   # Chunks raisonnables
        cmd += ['--buffer-size', '32K']
        cmd += ['--throttled-rate', '100K']  # Relance si le débit chute (anti-throttle YouTube)
    else:
        cmd += ['--concurrent-fragments', '4']

    cmd += ['--max-filesize', '50G']        # Support fichiers volumineux
    # Petite pause entre les requêtes réseau pour limiter le risque
    # de blocage "trop de requêtes" (HTTP 429) de la part de YouTube.
    cmd += ['--sleep-requests', '1']

    # ── Sections / timestamps ─────────────────────────────────────────────────
    start_time = opts.get('start_time', '').strip()
    end_time = opts.get('end_time', '').strip()
    if start_time or end_time:
        section = ''
        if start_time and end_time:
            section = f'*{start_time}-{end_time}'
        elif start_time:
            section = f'*{start_time}-inf'
        elif end_time:
            section = f'*0-{end_time}'
        if section:
            cmd += ['--download-sections', section, '--force-keyframes-at-cuts']

    # ── Profils de téléchargement ─────────────────────────────────────────────
    # Les profils sont gérés côté client, les opts sont déjà résolus ici.
    # On peut cependant ajouter une note dans le nom de fichier si souhaité.

    # Options de robustesse ULTRA
    cmd += [
        '--no-playlist',            # Par défaut: une seule vidéo
        '--no-warnings',            # Supprimer avertissements mineurs
        '--progress',               # Afficher progression
        '--newline',                # Une ligne par progression
        '--retries', '10',          # 10 retries au lieu de 5 pour ultra-fiabilité
        '--fragment-retries', '10', # 10 retries fragments
        '--retry-sleep', 'http:exp=2:60',  # Backoff exponentiel (2s → 60s) sur erreurs HTTP (429, etc.)
        '--socket-timeout', '120',  # Timeout de 2 minutes pour connexions lentes
        '--file-access-retries', '5', # 5 retries d'accès fichier
        '--extractor-retries', '5',  # 5 retries extracteur
    ]
    
    cmd.append(url)
    return cmd

def parse_progress_line(line):
    """Parse yt-dlp progress output line"""
    if '[download]' in line and '%' in line:
        m = re.search(r'(\d+\.?\d*)%\s+of\s+~?([\d.]+\w+)\s+at\s+([\d.]+\w+/s)(?:\s+ETA\s+(\S+))?', line)
        if m:
            return {
                'percent': float(m.group(1)),
                'total_str': m.group(2),
                'speed': m.group(3),
                'eta': m.group(4) or '—',
            }
    return None

def format_error(stderr_output, returncode):
    """Formater les erreurs yt-dlp de manière lisible"""
    if not stderr_output:
        return f'Erreur yt-dlp (code {returncode})'
    
    # Erreurs connues avec messages conviviaux
    error_map = [
        ('Sign in to confirm you\'re not a bot', '🤖 YouTube nécessite l\'authentification — essayez plus tard ou utilisez des cookies'),
        ('Video unavailable', '❌ Vidéo non disponible dans votre région'),
        ('Private video', '🔒 Vidéo privée — accès refusé'),
        ('This video is private', '🔒 Vidéo privée — accès refusé'),
        ('Sign in to confirm your age', '🔞 Contenu réservé aux adultes — connexion requise'),
        ('Copyright', '©️ Contenu protégé par droits d\'auteur'),
        ('removed', '🗑️ Vidéo supprimée par l\'auteur'),
        ('HTTP Error 403', '🚫 Accès refusé (403) — essayez avec des cookies'),
        ('HTTP Error 429', '⏱️ Trop de requêtes — attendez quelques minutes'),
        ('HTTP Error 404', '🔍 Vidéo introuvable (404)'),
        ('Unable to download', '📡 Impossible de télécharger — vérifiez votre connexion'),
        ('No space left', '💾 Espace disque insuffisant'),
        ('ffmpeg', '🔧 Erreur ffmpeg — vérifiez l\'installation'),
        ('Unsupported URL', '🔗 URL non supportée par yt-dlp'),
        ('Requested format is not available', '📹 Format demandé non disponible — essayez une qualité différente'),
        ('format is not available', '📹 Format non disponible — essayez une qualité différente'),
        ('No video formats found', '📹 Aucun format vidéo trouvé'),
        ('network', '📡 Erreur réseau — vérifiez votre connexion'),
        ('urlopen error', '📡 Erreur de connexion réseau'),
        ('Connection refused', '📡 Connexion refusée'),
        ('timed out', '⏱️ Délai d\'attente dépassé — connexion trop lente'),
    ]
    
    stderr_lower = stderr_output.lower()
    for keyword, friendly in error_map:
        if keyword.lower() in stderr_lower:
            return friendly
    
    # Extraire la dernière ligne ERROR si elle existe
    lines = [l.strip() for l in stderr_output.split('\n') if l.strip()]
    error_lines = [l for l in lines if 'ERROR' in l or 'error' in l.lower()]
    if error_lines:
        last_error = error_lines[-1]
        # Nettoyer
        last_error = re.sub(r'\[.*?\]\s*', '', last_error).strip()
        if len(last_error) > 5:
            return last_error[:200]
    
    return f'Erreur yt-dlp (code {returncode}) — {lines[-1][:150] if lines else "inconnue"}'

# ─── TÉLÉCHARGEMENT AVEC REPRISE AUTOMATIQUE ───────────────────
# Mots-clés d'erreurs considérées comme temporaires (réseau, quota, timeout…)
# et pour lesquelles on retente automatiquement au lieu d'annuler direct.
RECOVERABLE_ERROR_KEYWORDS = [
    'timed out', 'connection refused', 'network', 'unable to download',
    'http error 429', 'too many requests', 'connection reset',
    'fragment', 'socket timeout', 'temporary failure', 'http error 5',
    'econnreset', 'read timed out',
]

def _is_rate_limited(stderr_combined):
    low = stderr_combined.lower()
    return 'http error 429' in low or 'too many requests' in low

def _is_recoverable_error(stderr_combined):
    low = stderr_combined.lower()
    return any(k in low for k in RECOVERABLE_ERROR_KEYWORDS)

def _apply_progress_line(store, key, line, p):
    """Met à jour downloads_progress[key] à partir d'une ligne de progression yt-dlp."""
    if p:
        pct = p['percent']
        total = p['total_str']
        speed = p['speed']
        eta = p['eta']
        try:
            total_val = float(re.sub(r'[^\d.]', '', total))
            dl_val = total_val * pct / 100
            downloaded = f'{dl_val:.1f} MB'
        except Exception:
            downloaded = '—'
        store[key].update({
            'percent': pct, 'speed': speed,
            'total': total, 'downloaded': downloaded, 'eta': eta,
        })
        try:
            sp = float(re.sub(r'[^\d.]', '', speed)) if speed else 0
            if speed and 'MiB' in speed:
                sp *= 1024
            if sp > 0:
                samples = store[key].setdefault('speed_samples', [])
                samples.append(round(sp, 1))
                if len(samples) > 32:
                    samples.pop(0)
        except Exception:
            pass

    if '[download] Destination:' in line:
        fn = line.replace('[download] Destination:', '').strip()
        store[key]['filename'] = os.path.basename(fn)
    elif '[Merger]' in line or '[VideoConvertor]' in line or '[ffmpeg]' in line:
        store[key]['status'] = 'merging'
        store[key]['percent'] = 99
    elif '[ExtractAudio]' in line:
        store[key]['status'] = 'converting'
        store[key]['percent'] = 95

def _stream_ytdlp_process(cmd, proc_key, on_line=None):
    """
    Lance un process yt-dlp, suit sa progression et gère la pause/l'arrêt.
    on_line(line, parsed_progress) est appelé pour chaque ligne stdout — s'il
    n'est pas fourni, la progression est appliquée directement à
    downloads_progress[proc_key] (cas du téléchargement simple).
    Retourne un dict {'returncode', 'stderr_lines', 'paused', 'stopped'}.
    """
    stderr_lines = []
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    active_procs[proc_key] = proc

    def read_stderr():
        for line in proc.stderr:
            line = line.strip()
            if line:
                stderr_lines.append(line)

    stderr_thread = threading.Thread(target=read_stderr, daemon=True)
    stderr_thread.start()

    paused = False
    stopped = False
    for line in proc.stdout:
        cur_status = downloads_progress.get(proc_key, {}).get('status')
        if proc_key in paused_ids or cur_status == 'stopped':
            proc.terminate()
            stopped = cur_status == 'stopped'
            paused = not stopped
            break
        line = line.strip()
        if not line:
            continue
        p = parse_progress_line(line)
        if on_line:
            on_line(line, p)
        else:
            _apply_progress_line(downloads_progress, proc_key, line, p)

    proc.wait()
    stderr_thread.join(timeout=2)
    active_procs.pop(proc_key, None)
    return {'returncode': proc.returncode, 'stderr_lines': stderr_lines, 'paused': paused, 'stopped': stopped}

def run_with_auto_retry(build_cmd, proc_key, on_line=None, max_attempts=5, base_wait=5, max_wait=60,
                         min_progress_for_status=None):
    """
    Exécute build_cmd() (qui doit retourner la commande yt-dlp), et retente
    automatiquement en cas d'erreur récupérable (réseau, timeout, HTTP 429…),
    avec un backoff progressif — y compris si l'échec survient tout au début
    du téléchargement (c'est justement le cas typique du "trop de requêtes").
    Retourne un dict {'success': bool, 'paused': bool, 'stopped': bool,
    'error': str|None, 'stderr_lines': [...]}
    """
    all_stderr = []
    wait = base_wait
    attempt = 0
    while True:
        attempt += 1
        cmd = build_cmd()
        if attempt > 1 and '--continue' not in cmd:
            cmd.insert(1, '--continue')
        try:
            result = _stream_ytdlp_process(cmd, proc_key, on_line=on_line)
        except Exception as e:
            return {'success': False, 'paused': False, 'stopped': False,
                    'error': f'❌ {str(e)}', 'stderr_lines': all_stderr}

        all_stderr += result['stderr_lines']

        if result['paused']:
            return {'success': False, 'paused': True, 'stopped': False, 'error': None, 'stderr_lines': all_stderr}
        if result['stopped']:
            return {'success': False, 'paused': False, 'stopped': True, 'error': None, 'stderr_lines': all_stderr}
        if result['returncode'] == 0:
            return {'success': True, 'paused': False, 'stopped': False, 'error': None, 'stderr_lines': all_stderr}

        stderr_combined = '\n'.join(all_stderr)
        error_msg = format_error(stderr_combined, result['returncode'])
        recoverable = _is_recoverable_error(stderr_combined)
        rate_limited = _is_rate_limited(stderr_combined)

        if recoverable and attempt < max_attempts:
            if proc_key in downloads_progress:
                downloads_progress[proc_key]['status'] = 'retrying'
                remaining = max_attempts - attempt
                downloads_progress[proc_key]['error'] = f'{error_msg} — nouvelle tentative dans quelques secondes ({remaining} restante(s))…'
            sleep_time = max(wait, 20) if rate_limited else wait
            time.sleep(sleep_time)
            wait = min(wait * 2, max_wait)
            continue

        return {'success': False, 'paused': False, 'stopped': False, 'error': error_msg, 'stderr_lines': all_stderr}

# ─── ROUTES ──────────────────────────────────────────────────

@app.route('/')
def index():
    return send_from_directory('static', 'index.html')

@app.route('/favicon.ico')
def favicon():
    return Response(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="16" fill="#0a1020"/><path d="M20 18h24v8H28v6h12v8H28v6h16v8H20z" fill="#4f9eff"/></svg>',
        mimetype='image/svg+xml'
    )

@app.route('/static/manifest.json')
def pwa_manifest():
    return send_from_directory('static', 'manifest.json')

@app.route('/api/diagnostics')
def diagnostics():
    """Diagnostics complets du système"""
    deps = check_dependencies()
    dl_dir = get_download_dir()
    
    # Espace disque
    try:
        usage = shutil.disk_usage(str(dl_dir))
        disk = {
            'total_gb': round(usage.total / (1024**3), 1),
            'used_gb': round(usage.used / (1024**3), 1),
            'free_gb': round(usage.free / (1024**3), 1),
            'percent_used': round(usage.used / usage.total * 100, 1)
        }
    except:
        disk = {}
    
    # Compter les fichiers téléchargés
    file_count = 0
    total_size_mb = 0
    try:
        for f in dl_dir.rglob('*'):
            if f.is_file() and not f.name.startswith('.'):
                file_count += 1
                total_size_mb += f.stat().st_size / (1024*1024)
    except:
        pass
    
    return jsonify({
        'dependencies': deps,
        'disk': disk,
        'download_dir': str(dl_dir),
        'platform': platform.system(),
        'python_version': platform.python_version(),
        'file_count': file_count,
        'total_size_mb': round(total_size_mb, 1),
        'active_downloads': len([d for d in downloads_progress.values() if d.get('status') in ('downloading', 'starting', 'merging')]),
    })

@app.route('/api/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'GET':
        s = load_settings()
        d = Path(s.get('download_dir', str(DEFAULT_DOWNLOAD_DIR)))
        s['exists'] = d.exists()
        return jsonify(s)
    else:
        data = request.get_json()
        s = load_settings()
        
        # Mettre à jour uniquement les champs fournis
        allowed_keys = ['download_dir', 'concurrent_downloads', 'auto_update_ytdlp', 
                       'preferred_format', 'preferred_quality', 'theme', 'notifications', 'speed_limit']
        for key in allowed_keys:
            if key in data:
                s[key] = data[key]
        
        # Valider download_dir
        if 'download_dir' in data:
            new_dir = data['download_dir'].strip()
            if not new_dir:
                return jsonify({'error': 'Chemin vide'}), 400
            try:
                Path(new_dir).expanduser().mkdir(parents=True, exist_ok=True)
                s['download_dir'] = str(Path(new_dir).expanduser())
            except Exception as e:
                return jsonify({'error': f'Impossible de créer le dossier: {e}'}), 400
        
        save_settings(s)
        return jsonify({'success': True, **s})

@app.route('/api/update-ytdlp', methods=['POST'])
def update_ytdlp():
    """Mettre à jour yt-dlp"""
    try:
        result = subprocess.run(
            ['pip', 'install', '--upgrade', 'yt-dlp', '--break-system-packages'],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            # Essayer avec yt-dlp --update
            result2 = subprocess.run(['yt-dlp', '-U'], capture_output=True, text=True, timeout=60)
            if result2.returncode == 0:
                return jsonify({'success': True, 'message': result2.stdout.strip()})
            return jsonify({'error': result.stderr.strip()[:300]}), 400
        
        # Récupérer la nouvelle version
        ver = subprocess.run(['yt-dlp', '--version'], capture_output=True, text=True, timeout=5)
        return jsonify({'success': True, 'version': ver.stdout.strip()})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/upload-cookies', methods=['POST'])
def upload_cookies():
    """Uploader des cookies pour YouTube"""
    if 'file' not in request.files:
        return jsonify({'error': 'Aucun fichier fourni'}), 400

    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'Fichier vide'}), 400

    if not file.filename.endswith(('.txt', '.cookies')):
        return jsonify({'error': 'Format invalide — utilisez .txt ou .cookies'}), 400

    try:
        cookies_path = Path(__file__).parent / 'cookies.txt'
        file.save(str(cookies_path))
        file_size = cookies_path.stat().st_size
        return jsonify({
            'success': True,
            'message': f'Cookies uploadés ({file_size} bytes)',
            'size': file_size
        })
    except Exception as e:
        return jsonify({'error': f'Erreur upload: {str(e)}'}), 500

@app.route('/api/info', methods=['POST'])
def get_video_info():
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    if not url or not is_valid_url(url):
        return jsonify({'error': '🔗 URL invalide'}), 400

    # Vérifier le cache d'abord
    cached_info = get_cached_video_info(url)
    if cached_info:
        return jsonify(cached_info)

    ydl = get_ydl_path()
    cookies_file = Path(__file__).parent / 'cookies.txt'

    cmd = [
        ydl,
        '--dump-json',
        '--no-playlist',
        '--no-warnings',
        '--socket-timeout', '20',
        '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        '--extractor-args', 'youtube:skip_unavailable_videos=true',
        '--extractor-args', 'youtube:player_client=web'
    ]
    if cookies_file.exists() and cookies_file.stat().st_size > 100:
        cmd += ['--cookies', str(cookies_file)]
    cmd.append(url)
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
        
        if result.returncode != 0:
            err = result.stderr.strip()
            return jsonify({'error': format_error(err, result.returncode)}), 400
        
        if not result.stdout.strip():
            return jsonify({'error': '❌ Aucune information reçue — URL invalide ou contenu indisponible'}), 400
        
        info = json.loads(result.stdout)
        formats = info.get('formats', [])
        duration_secs = info.get('duration', 0) or 0
        
        if result.returncode != 0:
            err = result.stderr.strip()
            return jsonify({'error': format_error(err, result.returncode)}), 400
        
        if not result.stdout.strip():
            return jsonify({'error': '❌ Aucune information reçue — URL invalide ou contenu indisponible'}), 400
        
        info = json.loads(result.stdout)
        formats = info.get('formats', [])
        duration_secs = info.get('duration', 0) or 0
        
        # Qualités vidéo disponibles
        qualities = []
        seen_heights = set()
        for f in reversed(formats):
            h = f.get('height')
            if h and h not in seen_heights and f.get('vcodec', 'none') != 'none':
                seen_heights.add(h)
                label = f'{h}p'
                if f.get('fps') and f['fps'] > 30:
                    label += f'{int(f["fps"])}fps'
                if h >= 2160: label += ' (4K)'
                elif h == 1440: label += ' (2K)'
                elif h == 1080: label += ' (FHD)'
                elif h == 720: label += ' (HD)'
                qualities.append({'height': h, 'label': label})
        qualities.sort(key=lambda x: x['height'], reverse=True)

        # ── Vraies tailles par qualité ──────────────────────────────────────
        # On calcule la taille réelle en additionnant la meilleure piste vidéo
        # (à la hauteur demandée) + la meilleure piste audio disponible.
        # On utilise `filesize` (taille réelle) ou `filesize_approx` (estimée par
        # yt-dlp à partir du débit, bien plus précise que nos constantes hardcodées).
        def best_audio_size(fmts):
            """Taille de la meilleure piste audio en octets."""
            best = 0
            for f in fmts:
                if (f.get('acodec') or 'none') == 'none':
                    continue
                if (f.get('vcodec') or 'none') != 'none':
                    continue
                sz = f.get('filesize') or f.get('filesize_approx') or 0
                if sz > best:
                    best = sz
            return best

        audio_sz = best_audio_size(formats)
        
        # Si pas de taille audio exacte, estimer avec bitrate audio moyen
        if not audio_sz and duration_secs:
            # Estimation audio : 128 kbps AAC/MP3 moyen
            audio_sz = int((128 * 1000 * duration_secs) / 8)

        def fmt_bytes(b):
            if not b:
                return None
            if b >= 1_073_741_824:
                return f'{b/1_073_741_824:.2f} GB'
            if b >= 1_048_576:
                return f'{b/1_048_576:.1f} MB'
            if b >= 1024:
                return f'{b/1024:.0f} KB'
            return f'{b} B'

        # Enrichir chaque qualité avec la taille réelle
        for q in qualities:
            h = q['height']
            best_vid_sz = 0
            best_vid_tbr = 0  # bitrate vidéo
            for f in formats:
                fh = f.get('height') or 0
                if (f.get('vcodec') or 'none') == 'none':
                    continue
                if fh != h:
                    continue
                sz = f.get('filesize') or f.get('filesize_approx') or 0
                tbr = f.get('tbr') or f.get('vbr') or 0
                if sz > best_vid_sz:
                    best_vid_sz = sz
                    best_vid_tbr = tbr
            total = best_vid_sz + audio_sz if best_vid_sz else 0
            
            # Si pas de taille exacte, estimer précisément avec bitrate et durée
            if not total and duration_secs and best_vid_tbr:
                # Estimation : (bitrate en bits/s * durée en secondes) / 8 = octets
                estimated_bytes = (best_vid_tbr * 1000 * duration_secs) / 8
                # Ajouter audio si disponible
                if audio_sz:
                    estimated_bytes += audio_sz
                else:
                    # Estimation audio : bitrate moyen 128kbps
                    estimated_bytes += (128 * 1000 * duration_secs) / 8
                total = int(estimated_bytes)
            
            q['size_bytes'] = total if total else None
            q['size_str'] = fmt_bytes(total) if total else None

        # Taille audio (mp3/m4a best)
        audio_size_str = fmt_bytes(audio_sz) if audio_sz else None

        # === AMÉLIORATION ULTRA : Récupération RÉELLE de toutes les pistes audio ===
        orig_lang = (info.get('language') or 'en').strip().lower()
        orig_base = orig_lang.split('-')[0]

        audio_tracks = []
        seen_format_ids = set()

        for f in formats:
            vcodec = (f.get('vcodec') or 'none').lower()
            acodec = (f.get('acodec') or 'none').lower()
            if vcodec != 'none' or acodec == 'none':
                continue  # seulement les pistes audio pures

            fmt_id = str(f.get('format_id') or '').strip()
            if not fmt_id or fmt_id in seen_format_ids:
                continue
            seen_format_ids.add(fmt_id)

            # Extraction langue réelle
            lang = (f.get('language') or '').strip().lower()
            display_name = ''

            # audio_track (YouTube multi-lang très souvent ici)
            at = f.get('audio_track') or {}
            if isinstance(at, dict):
                if not lang:
                    lang = (at.get('lang') or at.get('language') or '').strip().lower()
                display_name = (at.get('display_name') or at.get('name') or '').strip()

            # Fallbacks
            if not lang:
                lang = (f.get('format_note') or '').strip().lower()
                # essayer d'extraire un code langue depuis la note
                m = re.search(r'\b([a-z]{2})(?:[-_][a-z]{2})?\b', lang)
                if m:
                    lang = m.group(1)

            lang = lang or 'und'
            base = lang.split('-')[0]

            # Nom lisible
            if not display_name:
                display_name = get_lang_name(lang)

            note = (f.get('format_note') or '').lower()
            display_lower = display_name.lower()
            is_original = (base == orig_base) or ('original' in note) or ('original' in display_lower)

            # Bitrate audio
            abr = f.get('abr') or f.get('tbr') or 0
            try:
                abr = int(float(abr))
            except:
                abr = 0

            ext = f.get('ext') or f.get('audio_ext') or 'm4a'

            flag = get_lang_flag(lang)

            label = display_name
            if is_original and '(Original)' not in label:
                label += ' (Original)'
            # Ajouter info qualité si plusieurs pistes même langue
            note = (f.get('format_note') or '').strip()
            if note and note.lower() not in ('audio only', 'medium', 'low'):
                label += f' [{note}]'

            track = {
                'format_id': fmt_id,
                'lang': lang,
                'code': lang,               # compat
                'label': label,
                'flag': flag or '🌐',
                'is_original': bool(is_original),
                'abr': abr,
                'ext': ext,
                'size_bytes': f.get('filesize') or f.get('filesize_approx'),
            }
            audio_tracks.append(track)

        # Trier : original en premier, puis par bitrate descendant
        audio_tracks.sort(key=lambda t: (not t['is_original'], -(t.get('abr') or 0)))

        # Fallback si rien trouvé
        if not audio_tracks:
            flag = get_lang_flag(orig_lang)
            audio_tracks = [{
                'format_id': '',
                'lang': orig_lang,
                'code': orig_lang,
                'label': f"{get_lang_name(orig_lang)} (Original)",
                'flag': flag or '🌐',
                'is_original': True,
                'abr': 0,
                'ext': 'm4a',
            }]

        # Garder compat ancien nom pour l'instant
        audio_langs = audio_tracks
        
        # Durée formatée
        if duration_secs:
            h = int(duration_secs // 3600)
            m = int((duration_secs % 3600) // 60)
            s = int(duration_secs % 60)
            dur_str = f'{h}h{m:02d}m{s:02d}s' if h > 0 else f'{m}m{s:02d}s'
        else:
            dur_str = '—'
        
        platform_info = detect_platform(url)
        
        response_data = {
            'id': info.get('id'),
            'title': info.get('title', 'Titre inconnu'),
            'channel': info.get('uploader') or info.get('channel', 'Inconnu'),
            'duration': dur_str,
            'duration_secs': duration_secs,
            'views': info.get('view_count', 0),
            'likes': info.get('like_count', 0),
            'description': (info.get('description') or '')[:500],
            'thumbnail': info.get('thumbnail', ''),
            'url': info.get('webpage_url', url),
            'qualities': qualities,  # chaque qualité a maintenant size_str et size_bytes
            'audio_langs': audio_langs,
            'audio_tracks': audio_tracks,     # v6.1 : vraies pistes audio complètes avec flags
            'audio_size_str': audio_size_str,  # taille audio seule
            'subtitles': list((info.get('subtitles') or {}).keys()),
            'auto_captions': list((info.get('automatic_captions') or {}).keys()),
            'subtitle_langs': build_subtitle_langs(info.get('subtitles'), info.get('automatic_captions')),
            'platform': platform_info,
            'upload_date': info.get('upload_date', ''),
            'categories': info.get('categories', []),
            'tags': (info.get('tags') or [])[:10],
        }
        
        # Mettre en cache pour accélérer les futures requêtes
        set_cached_video_info(url, response_data)
        
        return jsonify(response_data)
    except subprocess.TimeoutExpired:
        return jsonify({'error': '⏱️ Délai dépassé — vérifiez votre connexion internet'}), 504
    except json.JSONDecodeError:
        return jsonify({'error': '❌ Impossible de parser les informations vidéo'}), 500
    except Exception as e:
        return jsonify({'error': f'❌ {str(e)}'}), 500

@app.route('/api/download', methods=['POST'])
def start_download():
    global downloads_progress, downloads_history, active_procs, paused_ids
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    if not url or not is_valid_url(url):
        return jsonify({'error': 'URL invalide'}), 400
    
    download_dir = get_download_dir()
    download_id = f"dl_{int(time.time()*1000)}_{hashlib.md5(url.encode()).hexdigest()[:6]}"
    
    opts = {
        'type': data.get('type', 'video'),
        'quality': data.get('quality', 'best'),
        'format': data.get('format', 'mp4'),
        'audio_lang': data.get('audio_lang', ''),
        'audio_format_id': data.get('audio_format_id', ''),
        'dl_subs': data.get('dl_subs', False),
        'sub_lang': data.get('sub_lang', 'fr'),
        'sub_format': data.get('sub_format', 'srt'),
        'bitrate': data.get('bitrate', ''),
        'turbo': data.get('turbo', True),
        'turbo_fragments': int(data.get('turbo_fragments', 16)),
        'start_time': data.get('start_time', '') or data.get('startT',''),
        'end_time': data.get('end_time', '') or data.get('endT',''),
        'profile': data.get('profile', ''),
    }
    
    downloads_progress[download_id] = {
        'status': 'starting', 'percent': 0,
        'speed': '—', 'downloaded': '—',
        'total': '—', 'eta': '—',
        'filename': '', 'error': None,
        'title': data.get('title', 'Téléchargement...'),
        'type': 'single', 'paused': False,
        'url': url, 'started': time.time(),
        'platform': detect_platform(url),
        'format_type': data.get('type', 'video'),
        'stderr_log': [],
        'opts': opts,
        'download_dir': str(download_dir),
        'speed_samples': [],   # v6: for live charts
    }
    
    def run_download():
        downloads_progress[download_id]['status'] = 'downloading'
        result = run_with_auto_retry(
            build_cmd=lambda: build_ydl_cmd(url, opts, download_dir),
            proc_key=download_id,
            max_attempts=5, base_wait=5, max_wait=60,
        )
        downloads_progress[download_id]['stderr_log'] = result['stderr_lines'][-10:]

        if result['paused']:
            downloads_progress[download_id]['status'] = 'paused'
            return
        if result['stopped']:
            return

        if result['success']:
            downloads_progress[download_id]['status'] = 'done'
            downloads_progress[download_id]['percent'] = 100
            downloads_progress[download_id]['completed_at'] = time.time()
            downloads_history.insert(0, {
                'id': download_id, 'url': url,
                'title': downloads_progress[download_id].get('title', ''),
                'filename': downloads_progress[download_id].get('filename', ''),
                'quality': opts.get('quality'), 'format': opts.get('format'),
                'type': opts.get('type'),
                'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                'dir': str(download_dir),
                'platform': detect_platform(url),
            })
            if len(downloads_history) > 200:
                downloads_history.pop()
        else:
            downloads_progress[download_id]['status'] = 'failed'
            downloads_progress[download_id]['error'] = result['error']

    threading.Thread(target=run_download, daemon=True).start()
    return jsonify({'download_id': download_id})

@app.route('/api/download-direct', methods=['POST'])
def start_direct_download():
    """Téléchargement direct de fichiers avec aria2c/wget/curl pour performances maximales"""
    global downloads_progress, downloads_history, active_procs, paused_ids
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    if not url or not is_valid_url(url):
        return jsonify({'error': 'URL invalide'}), 400

    download_dir = get_download_dir()
    download_id = f"direct_{int(time.time()*1000)}_{hashlib.md5(url.encode()).hexdigest()[:6]}"

    downloads_progress[download_id] = {
        'status': 'starting', 'percent': 0,
        'speed': '—', 'downloaded': '—',
        'total': '—', 'eta': '—',
        'filename': '', 'error': None,
        'title': data.get('title', 'Téléchargement Direct...'),
        'type': 'direct', 'paused': False,
        'url': url, 'started': time.time(),
        'platform': detect_platform(url),
        'format_type': 'file',
        'stderr_log': [],
        'opts': {'turbo': True, 'turbo_fragments': 16},
        'download_dir': str(download_dir),
    }

    def run_direct_download():
        try:
            # Générer le nom de fichier à partir de l'URL
            filename = os.path.basename(url.split('?')[0])  # Enlever les paramètres
            if not filename:
                filename = f"download_{int(time.time())}"
            output_path = os.path.join(download_dir, filename)

            downloads_progress[download_id]['status'] = 'downloading'
            downloads_progress[download_id]['filename'] = filename

            # Lancer le téléchargement direct ultra-rapide
            proc = download_direct_file(url, output_path)
            active_procs[download_id] = proc

            # Surveiller la progression en temps réel
            start_time = time.time()
            last_size = 0
            last_update = 0

            while proc.poll() is None:
                if download_id in paused_ids:
                    proc.terminate()
                    downloads_progress[download_id]['status'] = 'paused'
                    active_procs.pop(download_id, None)
                    return

                current_time = time.time()
                try:
                    current_size = os.path.getsize(output_path)
                    if current_size != last_size or current_time - last_update > 2:
                        elapsed = current_time - start_time
                        speed = (current_size - last_size) / (current_time - last_update) if current_time - last_update > 0 else 0

                        downloads_progress[download_id].update({
                            'downloaded': f'{current_size / (1024*1024):.1f} MB',
                            'speed': f'{speed / (1024*1024):.1f} MB/s' if speed > 0 else '—',
                            'percent': 99 if current_size > 1024*1024 else 50,  # Estimation basée sur la taille
                        })
                        last_size = current_size
                        last_update = current_time
                except:
                    pass

                time.sleep(0.5)  # Mise à jour plus fréquente pour les directs

            active_procs.pop(download_id, None)

            if proc.returncode == 0:
                try:
                    final_size = os.path.getsize(output_path)
                    downloads_progress[download_id].update({
                        'status': 'done',
                        'percent': 100,
                        'downloaded': f'{final_size / (1024*1024):.1f} MB',
                        'completed_at': time.time()
                    })

                    downloads_history.insert(0, {
                        'id': download_id, 'url': url,
                        'title': downloads_progress[download_id].get('title', ''),
                        'filename': filename,
                        'quality': 'N/A', 'format': 'Direct',
                        'type': 'direct',
                        'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                        'dir': str(download_dir),
                        'platform': detect_platform(url),
                    })
                    if len(downloads_history) > 200:
                        downloads_history.pop()
                except Exception as e:
                        downloads_progress[download_id]['status'] = 'failed'  # Récupérable avec retry
                        downloads_progress[download_id]['error'] = f'Erreur vérification fichier: {str(e)}'
            else:
                downloads_progress[download_id]['status'] = 'failed'  # Récupérable avec retry
                downloads_progress[download_id]['error'] = 'Échec du téléchargement direct'

        except Exception as e:
            active_procs.pop(download_id, None)
            downloads_progress[download_id]['status'] = 'failed'  # Récupérable avec retry

    threading.Thread(target=run_direct_download, daemon=True).start()
    return jsonify({'download_id': download_id})

@app.route('/api/retry-download', methods=['POST'])
def retry_download():
    """Reprend un téléchargement échoué là où il s'est arrêté"""
    global downloads_progress, active_procs, paused_ids
    data = request.get_json()
    download_id = data.get('download_id', '')

    if not download_id or download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404

    download_info = downloads_progress[download_id]
    if download_info.get('status') not in RETRYABLE_STATUSES:
        return jsonify({'error': 'Ce téléchargement ne peut pas être repris'}), 400

    # Remettre en état de téléchargement
    download_info.update({
        'status': 'retrying',
        'error': None,
        'retry_count': download_info.get('retry_count', 0) + 1,
        'last_retry': time.time()
    })

    # Supprimer des listes de pause si présent
    paused_ids.discard(download_id)

    def run_retry():
        try:
            url = download_info['url']
            download_type = download_info.get('type', 'video')

            if download_type == 'direct':
                # Reprise d'un téléchargement direct
                download_dir = Path(download_info.get('download_dir', get_download_dir()))
                filename = download_info.get('filename', '')
                if not filename:
                    filename = os.path.basename(url.split('?')[0])
                    if not filename:
                        filename = f"download_{int(time.time())}"

                output_path = download_dir / filename

                # Vérifier si le fichier partiellement téléchargé existe
                resume_supported = output_path.exists() and output_path.stat().st_size > 0

                download_info.update({
                    'status': 'downloading',
                    'resume_supported': resume_supported,
                    'resumed_from': output_path.stat().st_size if resume_supported else 0
                })

                proc = download_direct_file(url, str(output_path))
                active_procs[download_id] = proc

                # Surveiller la progression
                start_time = time.time()
                last_size = output_path.stat().st_size if resume_supported else 0
                last_update = 0

                while proc.poll() is None:
                    if download_id in paused_ids:
                        proc.terminate()
                        download_info['status'] = 'paused'
                        active_procs.pop(download_id, None)
                        return

                    current_time = time.time()
                    try:
                        current_size = output_path.stat().st_size
                        if current_size != last_size or current_time - last_update > 2:
                            elapsed = current_time - start_time
                            speed = (current_size - last_size) / (current_time - last_update) if current_time - last_update > 0 else 0

                            download_info.update({
                                'downloaded': f'{current_size / (1024*1024):.1f} MB',
                                'speed': f'{speed / (1024*1024):.1f} MB/s' if speed > 0 else '—',
                                'percent': min(99, int((current_size / max(1, download_info.get('total_bytes', current_size * 2))) * 100))
                            })
                            last_size = current_size
                            last_update = current_time
                    except:
                        pass

                    time.sleep(0.5)

                active_procs.pop(download_id, None)

                if proc.returncode == 0:
                    try:
                        final_size = output_path.stat().st_size
                        download_info.update({
                            'status': 'done',
                            'percent': 100,
                            'downloaded': f'{final_size / (1024*1024):.1f} MB',
                            'completed_at': time.time()
                        })

                        # Ajouter à l'historique
                        downloads_history.insert(0, {
                            'id': download_id,
                            'url': url,
                            'title': download_info.get('title', ''),
                            'filename': filename,
                            'quality': 'N/A',
                            'format': 'Direct',
                            'type': 'direct',
                            'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                            'dir': str(download_dir),
                            'platform': detect_platform(url),
                        })
                        if len(downloads_history) > 200:
                            downloads_history.pop()
                    except Exception as e:
                        download_info['status'] = 'failed'
                        download_info['error'] = f'Erreur vérification fichier: {str(e)}'
                else:
                    download_info['status'] = 'failed'
                    download_info['error'] = 'Échec de la reprise du téléchargement direct'

            else:
                # Reprise d'un téléchargement vidéo/streaming
                opts = download_info.get('opts', {})
                opts['resume'] = True  # Forcer la reprise

                # Petite pause de sécurité : si l'échec précédent était un
                # blocage "trop de requêtes" (429), relancer instantanément
                # échouerait à nouveau presque à coup sûr.
                prev_error = (download_info.get('error') or '').lower()
                time.sleep(15 if ('429' in prev_error or 'trop de requ' in prev_error) else 2)

                download_info['status'] = 'downloading'

                proc = run_ydl_download(url, opts, download_id)
                active_procs[download_id] = proc

                # Surveiller la progression comme dans run_download
                monitor_download_progress(proc, download_id, url, opts)

        except Exception as e:
            active_procs.pop(download_id, None)
            download_info['status'] = 'failed'
            download_info['error'] = f'Erreur lors de la reprise: {str(e)}'

    threading.Thread(target=run_retry, daemon=True).start()
    return jsonify({'download_id': download_id, 'status': 'retrying'})

@app.route('/api/download-info/<download_id>', methods=['GET'])
def get_download_info(download_id):
    """Obtient les informations détaillées d'un téléchargement"""
    if download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404

    info = downloads_progress[download_id].copy()
    
    # Ajouter des informations supplémentaires pour l'interface
    info['can_retry'] = info.get('status') in RETRYABLE_STATUSES
    info['retry_count'] = info.get('retry_count', 0)
    info['last_retry'] = info.get('last_retry')
    info['resume_supported'] = info.get('resume_supported', False)
    info['resumed_from'] = info.get('resumed_from', 0)
    
    return jsonify(info)

@app.route('/api/preview/<download_id>', methods=['GET'])
def preview_download(download_id):
    """Stream le fichier d'un téléchargement terminé pour aperçu dans le navigateur.

    Contrairement à l'ancienne route /api/library/stream (supprimée), celle-ci
    ne prend pas de chemin arbitraire en paramètre : elle ne sert que le
    fichier associé à un download_id déjà connu du serveur, ce qui évite
    toute possibilité de lire un fichier hors du dossier de téléchargement.
    """
    info = downloads_progress.get(download_id) or next(
        (h for h in downloads_history if h.get('id') == download_id), None
    )
    if not info or not info.get('filename'):
        return jsonify({'error': 'Fichier introuvable pour cet identifiant'}), 404

    download_dir = Path(info.get('download_dir') or str(get_download_dir()))
    fp = (download_dir / info['filename']).resolve()
    try:
        fp.relative_to(download_dir.resolve())
    except ValueError:
        return jsonify({'error': 'Accès refusé'}), 403
    if not fp.exists() or not fp.is_file():
        return jsonify({'error': 'Fichier introuvable sur le disque'}), 404

    import mimetypes
    mime = mimetypes.guess_type(str(fp))[0] or 'application/octet-stream'
    file_size = fp.stat().st_size
    range_header = request.headers.get('Range', None)

    if range_header:
        m = re.search(r'bytes=(\d+)-(\d*)', range_header)
        start = int(m.group(1)) if m else 0
        end = int(m.group(2)) if m and m.group(2) else file_size - 1
        end = min(end, file_size - 1)
        length = max(0, end - start + 1)

        def _gen():
            with open(fp, 'rb') as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    yield chunk

        resp = Response(_gen(), 206, mimetype=mime)
        resp.headers['Content-Range'] = f'bytes {start}-{end}/{file_size}'
        resp.headers['Accept-Ranges'] = 'bytes'
        resp.headers['Content-Length'] = str(length)
        return resp

    def _gen_full():
        with open(fp, 'rb') as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                yield chunk

    resp = Response(_gen_full(), 200, mimetype=mime)
    resp.headers['Accept-Ranges'] = 'bytes'
    resp.headers['Content-Length'] = str(file_size)
    return resp

@app.route('/api/resume-all-restored', methods=['POST'])
def resume_all_restored():
    """Reprend automatiquement tous les téléchargements restaurés"""
    restored_count = 0
    
    for download_id, info in downloads_progress.items():
        if info.get('status') == 'restored':
            try:
                # Reprendre automatiquement selon le type
                if info.get('type') == 'direct':
                    # Reprise téléchargement direct
                    resume_download_direct(download_id, info)
                else:
                    # Reprise téléchargement vidéo/streaming
                    resume_download_video(download_id, info)
                
                restored_count += 1
                info['status'] = 'resuming'
                
            except Exception as e:
                print(f"❌ Erreur reprise automatique {download_id}: {e}")
                info['status'] = 'failed'
                info['error'] = f'Erreur reprise automatique: {str(e)}'
    
    return jsonify({
        'message': f'{restored_count} téléchargements repris automatiquement',
        'restored_count': restored_count
    })

def resume_download_direct(download_id, info):
    """Reprise automatique d'un téléchargement direct"""
    url = info['url']
    download_dir = Path(info.get('download_dir', get_download_dir()))
    filename = info.get('filename', '')
    
    if not filename:
        filename = os.path.basename(url.split('?')[0])
        if not filename:
            filename = f"download_{int(time.time())}"
    
    output_path = download_dir / filename
    
    # Vérifier si reprise possible
    resume_supported = output_path.exists() and output_path.stat().st_size > 0
    
    info.update({
        'status': 'downloading',
        'resume_supported': resume_supported,
        'resumed_from': output_path.stat().st_size if resume_supported else 0
    })
    
    def run_resume():
        try:
            proc = download_direct_file(url, str(output_path))
            active_procs[download_id] = proc
            
            # Surveiller la progression
            start_time = time.time()
            last_size = output_path.stat().st_size if resume_supported else 0
            last_update = 0
            
            while proc.poll() is None:
                if download_id in paused_ids:
                    proc.terminate()
                    info['status'] = 'paused'
                    active_procs.pop(download_id, None)
                    return
                
                current_time = time.time()
                try:
                    current_size = output_path.stat().st_size
                    if current_size != last_size or current_time - last_update > 2:
                        elapsed = current_time - start_time
                        speed = (current_size - last_size) / (current_time - last_update) if current_time - last_update > 0 else 0
                        
                        info.update({
                            'downloaded': f'{current_size / (1024*1024):.1f} MB',
                            'speed': f'{speed / (1024*1024):.1f} MB/s' if speed > 0 else '—',
                            'percent': min(99, int((current_size / max(1, info.get('total_bytes', current_size * 2))) * 100))
                        })
                        last_size = current_size
                        last_update = current_time
                except:
                    pass
                
                time.sleep(0.5)
            
            active_procs.pop(download_id, None)
            
            if proc.returncode == 0:
                try:
                    final_size = output_path.stat().st_size
                    info.update({
                        'status': 'done',
                        'percent': 100,
                        'downloaded': f'{final_size / (1024*1024):.1f} MB',
                        'completed_at': time.time()
                    })
                    
                    # Ajouter à l'historique
                    downloads_history.insert(0, {
                        'id': download_id,
                        'url': url,
                        'title': info.get('title', ''),
                        'filename': filename,
                        'quality': 'N/A',
                        'format': 'Direct',
                        'type': 'direct',
                        'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                        'dir': str(download_dir),
                        'platform': detect_platform(url),
                    })
                    if len(downloads_history) > 200:
                        downloads_history.pop()
                except Exception as e:
                    info['status'] = 'failed'
                    info['error'] = f'Erreur finalisation: {str(e)}'
            else:
                info['status'] = 'failed'
                info['error'] = 'Échec reprise téléchargement direct'
                
        except Exception as e:
            active_procs.pop(download_id, None)
            info['status'] = 'failed'
            info['error'] = f'Erreur reprise: {str(e)}'
    
    threading.Thread(target=run_resume, daemon=True).start()

def resume_download_video(download_id, info):
    """Reprise automatique d'un téléchargement vidéo/streaming"""
    url = info['url']
    opts = info.get('opts', {})
    opts['resume'] = True  # Forcer la reprise
    
    info['status'] = 'downloading'
    
    def run_resume():
        try:
            proc = run_ydl_download(url, opts, download_id)
            active_procs[download_id] = proc
            
            # Surveiller la progression
            monitor_download_progress(proc, download_id, url, opts)
            
        except Exception as e:
            active_procs.pop(download_id, None)
            info['status'] = 'failed'
            info['error'] = f'Erreur reprise vidéo: {str(e)}'
    
    threading.Thread(target=run_resume, daemon=True).start()

@app.route('/api/discover-files', methods=['POST'])
def discover_files():
    """Découvre les fichiers téléchargeables sur une page web"""
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    max_depth = min(int(data.get('max_depth', 2)), 3)  # Limiter à 3 max

    if not url or not is_valid_url(url):
        return jsonify({'error': 'URL invalide'}), 400

    try:
        files = discover_downloadable_files(url, max_depth)
        return jsonify({
            'url': url,
            'files_found': len(files),
            'files': files[:50]  # Limiter à 50 résultats
        })
    except Exception as e:
        return jsonify({'error': f'Erreur découverte: {str(e)}'}), 500

@app.route('/api/download-batch', methods=['POST'])
def start_batch_download():
    global downloads_progress, active_procs, paused_ids
    data = request.get_json()
    items = data.get('items', [])
    if not items:
        return jsonify({'error': 'Aucun élément à télécharger'}), 400
    
    global_opts = data.get('opts', {})
    download_dir = get_download_dir()
    batch_id = f"batch_{int(time.time()*1000)}"
    total = len(items)
    
    downloads_progress[batch_id] = {
        'status': 'starting', 'percent': 0, 'total': total,
        'current': 0, 'current_title': '', 'current_filename': '',
        'speed': '—', 'eta': '—', 'downloaded': '—', 'total_size': '—',
        'current_file_percent': 0, 'error': None, 'type': 'batch', 'paused': False,
        'completed': [], 'failed': [], 'started': time.time(),
    }
    
    def run_batch():
        i = 0
        while i < total:
            if batch_id in paused_ids:
                downloads_progress[batch_id]['status'] = 'paused'
                while batch_id in paused_ids:
                    time.sleep(0.5)
                downloads_progress[batch_id]['status'] = 'downloading'
            
            if downloads_progress[batch_id].get('status') == 'stopped':
                return
            
            item = items[i]
            url = clean_url(item.get('url', ''))
            item_opts = {**global_opts, **item.get('opts', {})}
            
            downloads_progress[batch_id].update({
                'status': 'downloading', 'current': i + 1,
                'percent': 0, 'current_file_percent': 0
            })
            
            title = item.get('title', url[:60])
            downloads_progress[batch_id]['current_title'] = title

            def _on_line(line, p, i=i):
                if p:
                    file_pct = p['percent']
                    overall = ((i + file_pct / 100) / total) * 100
                    downloads_progress[batch_id].update({
                        'percent': round(overall, 1),
                        'current_file_percent': file_pct,
                        'speed': p['speed'], 'eta': p['eta'],
                    })
                if '[download] Destination:' in line:
                    fn = line.replace('[download] Destination:', '').strip()
                    downloads_progress[batch_id]['current_filename'] = os.path.basename(fn)

            result = run_with_auto_retry(
                build_cmd=lambda: build_ydl_cmd(url, item_opts, download_dir),
                proc_key=batch_id, on_line=_on_line,
                max_attempts=4, base_wait=5, max_wait=45,
            )

            if result['paused'] or result['stopped']:
                # Ne pas avancer : on retentera le même élément une fois repris
                continue

            if result['success']:
                downloads_progress[batch_id]['completed'].append(title)
            else:
                downloads_progress[batch_id]['failed'].append({'title': title, 'error': result['error']})

            i += 1
            time.sleep(1.5)  # pause entre chaque élément pour éviter de saturer le serveur distant
        
        if downloads_progress[batch_id].get('status') not in ('stopped',):
            downloads_progress[batch_id]['status'] = 'done'
            downloads_progress[batch_id]['percent'] = 100
            downloads_progress[batch_id]['completed_at'] = time.time()
    
    threading.Thread(target=run_batch, daemon=True).start()
    return jsonify({'download_id': batch_id})

@app.route('/api/download-playlist', methods=['POST'])
def start_playlist_download():
    global downloads_progress, active_procs, paused_ids
    data = request.get_json()
    items = data.get('items', [])
    opts = data.get('opts', {})
    playlist_name = sanitize_folder_name(data.get('playlist_name', 'Playlist'))
    excluded_ids = set(data.get('excluded_ids', []))
    
    download_dir = get_download_dir()
    playlist_dir = download_dir / playlist_name
    playlist_dir.mkdir(parents=True, exist_ok=True)
    
    active_items = [it for it in items if it.get('id') not in excluded_ids]
    if not active_items:
        return jsonify({'error': 'Aucune vidéo à télécharger'}), 400
    
    dl_id = f"playlist_{int(time.time()*1000)}"
    downloads_progress[dl_id] = {
        'status': 'starting', 'percent': 0,
        'current': 0, 'total': len(active_items),
        'current_title': '', 'speed': '—', 'eta': '—',
        'current_file_percent': 0, 'downloaded': '—', 'total_size': '—',
        'playlist_name': playlist_name, 'playlist_dir': str(playlist_dir),
        'error': None, 'type': 'playlist', 'paused': False,
        'completed': [], 'failed': [], 'started': time.time(),
    }
    
    def run_playlist():
        total = len(active_items)
        i = 0
        while i < total:
            if dl_id in paused_ids:
                downloads_progress[dl_id]['status'] = 'paused'
                while dl_id in paused_ids:
                    time.sleep(0.5)
                downloads_progress[dl_id]['status'] = 'downloading'
            
            if downloads_progress[dl_id].get('status') == 'stopped':
                return
            
            item = active_items[i]
            url = clean_url(item.get('url', ''))
            title = item.get('title', url[:40])
            
            downloads_progress[dl_id].update({
                'status': 'downloading', 'current': i + 1,
                'current_title': title, 'current_file_percent': 0
            })
            
            tmpl = str(playlist_dir / f'{i+1:03d} - %(title)s.%(ext)s')

            def _on_line(line, p, i=i):
                if p:
                    file_pct = p['percent']
                    overall = ((i + file_pct / 100) / total) * 100
                    downloads_progress[dl_id].update({
                        'percent': round(overall, 1),
                        'current_file_percent': file_pct,
                        'speed': p['speed'], 'eta': p['eta'],
                    })

            result = run_with_auto_retry(
                build_cmd=lambda: build_ydl_cmd(url, opts, playlist_dir, filename_template=tmpl),
                proc_key=dl_id, on_line=_on_line,
                max_attempts=4, base_wait=5, max_wait=45,
            )

            if result['paused'] or result['stopped']:
                continue

            if result['success']:
                downloads_progress[dl_id]['completed'].append(title)
            else:
                downloads_progress[dl_id]['failed'].append({'title': title, 'error': result['error']})

            i += 1
            time.sleep(1.5)  # pause entre chaque vidéo pour éviter de saturer le serveur distant
        
        if downloads_progress[dl_id].get('status') not in ('stopped',):
            downloads_progress[dl_id]['status'] = 'done'
            downloads_progress[dl_id]['percent'] = 100
    
    threading.Thread(target=run_playlist, daemon=True).start()
    return jsonify({'download_id': dl_id, 'playlist_dir': str(playlist_dir)})

@app.route('/api/progress/<download_id>')
def get_progress(download_id):
    def generate():
        last_data = None
        timeout = 0
        while timeout < 7200:
            prog = downloads_progress.get(download_id, {})
            # Exclure les logs stderr de la réponse SSE pour la performance
            prog_clean = {k: v for k, v in prog.items() if k != 'stderr_log'}
            data = json.dumps(prog_clean)
            if data != last_data:
                yield f'data: {data}\n\n'
                last_data = data
            if prog.get('status') in TERMINAL_STATUSES:
                break
            time.sleep(1.5)  # Réduit le clignotement : mise à jour toutes les 1.5s au lieu de 0.3s
            timeout += 1.5
    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

@app.route('/api/pause/<download_id>', methods=['POST'])
def pause_download(download_id):
    global downloads_progress, paused_ids, active_procs
    if download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404
    paused_ids.add(download_id)
    proc = active_procs.get(download_id)
    if proc:
        try: proc.terminate()
        except: pass
    downloads_progress[download_id]['paused'] = True
    downloads_progress[download_id]['status'] = 'paused'
    return jsonify({'success': True, 'status': 'paused'})

@app.route('/api/resume/<download_id>', methods=['POST'])
def resume_download(download_id):
    global downloads_progress, downloads_history, active_procs, paused_ids
    if download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404

    info = downloads_progress[download_id]
    paused_ids.discard(download_id)
    info['paused'] = False
    info['status'] = 'resuming'

    dl_type = info.get('type', 'single')

    # ── Single download ──────────────────────────────────────────────────────
    if dl_type == 'single':
        url = info.get('url')
        opts = info.get('opts')
        download_dir = Path(info.get('download_dir', get_download_dir()))
        if not url or not opts:
            return jsonify({'error': 'Impossible de reprendre : paramètres manquants'}), 400

        def _resume_single():
            cmd = build_ydl_cmd(url, opts, download_dir)
            # Ajouter --continue pour reprendre si le fichier partiel existe
            if '--continue' not in cmd:
                cmd.insert(1, '--continue')
            stderr_lines = info.get('stderr_log', [])
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
                active_procs[download_id] = proc
                info['status'] = 'downloading'

                def _read_stderr():
                    for line in proc.stderr:
                        if line.strip(): stderr_lines.append(line.strip())
                threading.Thread(target=_read_stderr, daemon=True).start()

                for line in proc.stdout:
                    if download_id in paused_ids:
                        proc.terminate()
                        info['status'] = 'paused'
                        active_procs.pop(download_id, None)
                        return
                    line = line.strip()
                    if not line: continue
                    p = parse_progress_line(line)
                    if p:
                        pct = p['percent']
                        total = p['total_str']
                        speed = p['speed']
                        eta = p['eta']
                        try:
                            total_val = float(re.sub(r'[^\d.]', '', total))
                            dl_val = total_val * pct / 100
                            downloaded = f'{dl_val:.1f} MB'
                        except:
                            downloaded = '—'
                        info.update({'percent': pct, 'speed': speed, 'total': total, 'downloaded': downloaded, 'eta': eta})
                    if '[download] Destination:' in line:
                        fn = line.replace('[download] Destination:', '').strip()
                        info['filename'] = os.path.basename(fn)
                    elif '[Merger]' in line or '[VideoConvertor]' in line or '[ffmpeg]' in line:
                        info['status'] = 'merging'; info['percent'] = 99
                    elif '[ExtractAudio]' in line:
                        info['status'] = 'converting'; info['percent'] = 95

                proc.wait()
                active_procs.pop(download_id, None)
                info['stderr_log'] = stderr_lines[-10:]
                if proc.returncode == 0:
                    info['status'] = 'done'; info['percent'] = 100
                    info['completed_at'] = time.time()
                    downloads_history.insert(0, {
                        'id': download_id, 'url': url,
                        'title': info.get('title', ''),
                        'filename': info.get('filename', ''),
                        'quality': opts.get('quality'), 'format': opts.get('format'),
                        'type': opts.get('type'),
                        'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                        'dir': str(download_dir),
                        'platform': detect_platform(url),
                    })
                    if len(downloads_history) > 200: downloads_history.pop()
                else:
                    if info['status'] not in ('paused', 'stopped'):
                        info['status'] = 'error'
                        info['error'] = format_error('\n'.join(stderr_lines), proc.returncode)
            except Exception as e:
                active_procs.pop(download_id, None)
                info['status'] = 'error'
                info['error'] = f'❌ {str(e)}'

        threading.Thread(target=_resume_single, daemon=True).start()
        return jsonify({'success': True, 'status': 'resuming'})

    # ── Batch / Playlist : on signale juste la reprise, le thread attendait ──
    info['status'] = 'downloading'
    return jsonify({'success': True, 'status': 'resuming'})

@app.route('/api/stop/<download_id>', methods=['POST'])
def stop_download(download_id):
    global downloads_progress, active_procs, paused_ids
    if download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404
    paused_ids.discard(download_id)
    proc = active_procs.get(download_id)
    if proc:
        try: proc.terminate()
        except: pass
    active_procs.pop(download_id, None)
    downloads_progress[download_id]['status'] = 'stopped'
    downloads_progress[download_id]['paused'] = False
    return jsonify({'success': True, 'status': 'stopped'})

@app.route('/api/stop-all', methods=['POST'])
def stop_all():
    global downloads_progress, active_procs, paused_ids
    stopped = []
    for dl_id, proc in list(active_procs.items()):
        try: proc.terminate()
        except: pass
        if dl_id in downloads_progress:
            downloads_progress[dl_id].update({'status': 'stopped', 'paused': False})
        stopped.append(dl_id)
    active_procs.clear()
    paused_ids.clear()
    return jsonify({'success': True, 'stopped': stopped})

@app.route('/api/active-downloads')
def get_active_downloads():
    global downloads_progress
    # Purger d'éventuels ids dismissed encore en mémoire
    for dl_id in list(downloads_progress.keys()):
        if dl_id in dismissed_download_ids:
            downloads_progress.pop(dl_id, None)

    incomplete_items = scan_incomplete_downloads()
    result = []
    for dl_id, prog in downloads_progress.items():
        if dl_id in dismissed_download_ids:
            continue
        prog_clean = {k: v for k, v in prog.items() if k != 'stderr_log'}
        status = prog_clean.get('status')
        prog_clean['can_retry'] = bool(prog_clean.get('url') and prog_clean.get('opts') and status in RETRYABLE_STATUSES)
        result.append({'id': dl_id, **prog_clean})
    # Orphans incomplets (déjà filtrés via dismissed dans scan)
    for item in incomplete_items:
        if item.get('id') in dismissed_download_ids:
            continue
        result.append(item)
    result.sort(key=lambda x: x.get('started', 0), reverse=True)
    return jsonify(result[:80])

@app.route('/api/retry-incomplete', methods=['POST'])
def retry_incomplete_downloads():
    scan_incomplete_downloads()
    retry_ids = [
        dl_id for dl_id, info in downloads_progress.items()
        if info.get('status') in RETRYABLE_STATUSES and info.get('url') and info.get('opts')
    ]
    started = []
    skipped = []
    for dl_id in retry_ids:
        if dl_id in active_procs:
            skipped.append(dl_id)
            continue
        with app.test_request_context(json={'download_id': dl_id}):
            try:
                resp = retry_download()
                status_code = resp[1] if isinstance(resp, tuple) and len(resp) > 1 else 200
                if status_code and status_code >= 400:
                    skipped.append(dl_id)
                else:
                    started.append(dl_id)
            except Exception as e:
                downloads_progress[dl_id]['status'] = 'failed'
                downloads_progress[dl_id]['error'] = f'Erreur relance globale: {str(e)}'
                skipped.append(dl_id)
    return jsonify({'success': True, 'started': started, 'skipped': skipped, 'count': len(started)})


# ─────────────────────────────────────────────────────────────────────────────
# NOUVEAUTÉ : Suppression individuelle et nettoyage des téléchargements
# Permet de nettoyer l'onglet "En cours" des éléments arrêtés, incomplets, erreurs, etc.
# ─────────────────────────────────────────────────────────────────────────────

@app.route('/api/remove/<download_id>', methods=['POST', 'DELETE'])
def remove_download(download_id):
    """
    Supprime définitivement un téléchargement de la liste.
    Fonctionne aussi pour les items 'incomplete_*' issus du scan disque.
    Ne réapparaît plus au redémarrage.
    """
    body = request.get_json(silent=True) or {}
    delete_partials = body.get('delete_partials', True)

    info = downloads_progress.get(download_id)

    # Item orphan du scan disque (pas encore dans downloads_progress)
    if not info and str(download_id).startswith('incomplete_'):
        # Reconstruire info minimale depuis le scan
        for item in scan_incomplete_downloads():
            if item.get('id') == download_id:
                info = item
                break
        # Même sans match scan, blacklist l'id pour qu'il ne revienne jamais
        if not info:
            dismissed_download_ids.add(download_id)
            save_dismissed()
            save_download_state()
            return jsonify({'success': True, 'removed': download_id, 'note': 'dismissed_by_id'})

    if not info and download_id not in downloads_progress:
        # Déjà absent → marquer dismissed quand même (idempotent)
        dismissed_download_ids.add(download_id)
        save_dismissed()
        save_download_state()
        return jsonify({'success': True, 'removed': download_id, 'note': 'already_gone'})

    result = dismiss_download_permanently(download_id, info=info, delete_partials=delete_partials)
    return jsonify({'success': True, **result})


@app.route('/api/cleanup', methods=['POST'])
def cleanup_downloads():
    """Nettoie définitivement tous les téléchargements terminés, échoués, arrêtés, incomplets, restaurés."""
    body = request.get_json(silent=True) or {}
    delete_partials = body.get('delete_partials', True)
    removed = []
    cleanup_statuses = {'done', 'failed', 'error', 'stopped', 'incomplete', 'restored'}

    # 1) Items en mémoire
    for dl_id in list(downloads_progress.keys()):
        status = downloads_progress[dl_id].get('status')
        if status in cleanup_statuses:
            dismiss_download_permanently(dl_id, info=downloads_progress.get(dl_id), delete_partials=delete_partials)
            removed.append(dl_id)

    # 2) Orphans incomplets du scan disque
    for item in scan_incomplete_downloads():
        iid = item.get('id')
        if iid and iid not in removed:
            dismiss_download_permanently(iid, info=item, delete_partials=delete_partials)
            removed.append(iid)

    save_download_state()
    return jsonify({'success': True, 'removed': removed, 'count': len(removed)})


@app.route('/api/playlist/info', methods=['POST'])
def get_playlist_info():
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    if not url:
        return jsonify({'error': 'URL manquante'}), 400

    # ── Détecter si c'est une URL de chaîne (pas de playlist précise) ────────
    # Une URL de chaîne ressemble à : youtube.com/channel/xxx  ou  /c/xxx  ou  /@xxx
    # Une URL de playlist contient list=PLxxxx
    import urllib.parse as _up
    parsed = _up.urlparse(url)
    qs = _up.parse_qs(parsed.query)
    has_list = 'list' in qs

    is_channel = not has_list and any(seg in parsed.path for seg in ['/channel/', '/c/', '/@', '/user/'])
    is_channel = is_channel or (parsed.netloc in ('www.youtube.com','youtube.com','youtu.be')
                                and not has_list
                                and parsed.path.rstrip('/') in ('', '/', '/videos', '/playlists', '/shorts'))

    if is_channel:
        return jsonify({
            'error': '⚠️ Cette URL pointe vers une chaîne entière, pas une playlist précise.\n'
                     'Copiez l\'URL d\'une playlist spécifique (elle doit contenir "?list=PLxxx…").'
        }), 400

    ydl = get_ydl_path()
    cookies_file = Path(__file__).parent / 'cookies.txt'
    base_cmd = [ydl, '--flat-playlist', '--yes-playlist', '--no-warnings']
    if cookies_file.exists() and cookies_file.stat().st_size > 100:
        base_cmd += ['--cookies', str(cookies_file)]

    # Si l'URL contient un list= on force l'extraction uniquement de cette playlist
    if has_list:
        playlist_id = qs['list'][0]
        # Normaliser l'URL pour ne garder que la playlist
        url = f'https://www.youtube.com/playlist?list={playlist_id}'

    try:
        # Métadonnées + items en une seule passe (dump-single-json inclut entries)
        meta_result = subprocess.run(
            base_cmd + ['--dump-single-json', url],
            capture_output=True, text=True, timeout=90
        )

        playlist_title = 'Playlist'
        items = []

        if meta_result.returncode == 0 and meta_result.stdout.strip():
            try:
                meta = json.loads(meta_result.stdout)
                playlist_title = meta.get('title') or meta.get('playlist_title') or 'Playlist'
                entries = meta.get('entries') or []
                for item in entries:
                    if not item: continue
                    duration = item.get('duration', 0) or 0
                    dur_h = int(duration) // 3600
                    dur_m = (int(duration) % 3600) // 60
                    dur_s = int(duration) % 60
                    if dur_h > 0:
                        dur_str = f"{dur_h}h{dur_m:02d}m{dur_s:02d}s"
                    elif dur_m > 0:
                        dur_str = f"{dur_m}m{dur_s:02d}s"
                    elif duration:
                        dur_str = f"0m{dur_s:02d}s"
                    else:
                        dur_str = '—'
                    vid_id = item.get('id', '')
                    items.append({
                        'id': vid_id,
                        'title': item.get('title', 'Sans titre'),
                        'duration': dur_str,
                        'channel': item.get('uploader') or item.get('channel', ''),
                        'views': item.get('view_count', 0),
                        'thumbnail': f'https://img.youtube.com/vi/{vid_id}/mqdefault.jpg' if vid_id else '',
                        'url': item.get('url') or item.get('webpage_url') or f'https://www.youtube.com/watch?v={vid_id}'
                    })
            except Exception as e:
                pass  # Fallback ci-dessous

        # Fallback: --dump-json ligne par ligne si dump-single-json n'a pas donné d'entries
        if not items:
            result = subprocess.run(
                base_cmd + ['--dump-json', url],
                capture_output=True, text=True, timeout=90
            )
            if result.returncode != 0:
                err = result.stderr.strip()
                return jsonify({'error': format_error(err, result.returncode)}), 400
            for line in result.stdout.strip().split('\n'):
                if not line.strip(): continue
                try:
                    item = json.loads(line)
                    duration = item.get('duration', 0) or 0
                    dur_m = int(duration) // 60
                    dur_s = int(duration) % 60
                    dur_str = f"{dur_m}m{dur_s:02d}s" if duration else '—'
                    vid_id = item.get('id', '')
                    items.append({
                        'id': vid_id,
                        'title': item.get('title', 'Sans titre'),
                        'duration': dur_str,
                        'channel': item.get('uploader') or item.get('channel', ''),
                        'views': item.get('view_count', 0),
                        'thumbnail': f'https://img.youtube.com/vi/{vid_id}/mqdefault.jpg' if vid_id else '',
                        'url': item.get('url') or item.get('webpage_url') or f'https://www.youtube.com/watch?v={vid_id}'
                    })
                except:
                    continue

        if not items:
            return jsonify({'error': 'Aucune vidéo trouvée dans cette playlist.'}), 400

        return jsonify({
            'count': len(items),
            'items': items,
            'playlist_title': playlist_title,
            'playlist_url': url
        })
    except subprocess.TimeoutExpired:
        return jsonify({'error': '⏱️ Délai dépassé'}), 504
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/search', methods=['POST'])
def search_youtube():
    """
    Recherche YouTube avec pagination infinie.
    - `query`  : terme de recherche
    - `offset` : index de départ (0, 20, 40, …)
    - `batch`  : taille d'un lot (défaut 20, max 50)
    La première requête (offset=0) lance une recherche de 50 résultats mis en cache
    côté serveur. Les requêtes suivantes (offset>0) utilisent ce cache ou font une
    nouvelle requête ytsearch étendue.
    """
    data = request.get_json()
    query = data.get('query', '').strip()
    offset = max(0, int(data.get('offset', 0)))
    batch  = min(max(1, int(data.get('batch', 20))), 50)

    if not query:
        return jsonify({'error': 'Requête vide'}), 400

    # Cache clé = hash de la requête
    cache_key = hashlib.md5(query.encode()).hexdigest()

    # Combien de résultats faut-il en tout pour servir offset+batch ?
    needed = offset + batch
    # On demande toujours un peu plus pour permettre le "Afficher plus"
    fetch_count = max(needed + batch, 50)

    ydl = get_ydl_path()
    cookies_file = Path(__file__).parent / 'cookies.txt'

    # Vérifier si le cache contient déjà assez de résultats
    cached = _search_cache.get(cache_key)
    if cached and len(cached['items']) >= needed and cached['query'] == query:
        items = cached['items']
    else:
        # Lancer yt-dlp avec ytsearchN
        cmd = [ydl, f'ytsearch{fetch_count}:{query}',
               '--dump-json', '--flat-playlist', '--no-warnings', '--socket-timeout', '25']
        if cookies_file.exists() and cookies_file.stat().st_size > 100:
            cmd += ['--cookies', str(cookies_file)]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return jsonify({'error': '⏱️ Délai dépassé'}), 504
        except Exception as e:
            return jsonify({'error': str(e)}), 500

        items = []
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
                duration = item.get('duration', 0) or 0
                dur_h = int(duration) // 3600
                dur_m = (int(duration) % 3600) // 60
                dur_s = int(duration) % 60
                if dur_h > 0:
                    dur_str = f"{dur_h}h{dur_m:02d}m{dur_s:02d}s"
                elif dur_m > 0:
                    dur_str = f"{dur_m}m{dur_s:02d}s"
                elif duration:
                    dur_str = f"0m{dur_s:02d}s"
                else:
                    dur_str = '—'
                vid_id = item.get('id', '')
                upload_date = item.get('upload_date', '')
                date_fmt = ''
                if upload_date and len(upload_date) == 8:
                    try:
                        date_fmt = f"{upload_date[6:]}/{upload_date[4:6]}/{upload_date[:4]}"
                    except:
                        pass
                items.append({
                    'id': vid_id,
                    'title': item.get('title', ''),
                    'channel': item.get('uploader') or item.get('channel', ''),
                    'duration': dur_str,
                    'views': item.get('view_count', 0),
                    'thumbnail': f'https://img.youtube.com/vi/{vid_id}/mqdefault.jpg',
                    'url': f'https://www.youtube.com/watch?v={vid_id}',
                    'upload_date': date_fmt,
                    'description': (item.get('description') or '')[:120],
                })
            except:
                continue

        # Mettre en cache
        _search_cache[cache_key] = {'query': query, 'items': items, 'ts': time.time()}
        # Nettoyer les vieux caches (garder les 20 dernières requêtes)
        if len(_search_cache) > 20:
            oldest = sorted(_search_cache.items(), key=lambda x: x[1]['ts'])
            for k, _ in oldest[:-20]:
                del _search_cache[k]

    page_items = items[offset:offset + batch]
    has_more   = len(items) > offset + batch

    return jsonify({
        'results': page_items,
        'total_fetched': len(items),
        'offset': offset,
        'batch': batch,
        'has_more': has_more,
        'next_offset': offset + batch if has_more else None,
    })

@app.route('/api/history')
def get_history():
    return jsonify(downloads_history)

@app.route('/api/history/clear', methods=['POST'])
def clear_history():
    downloads_history.clear()
    return jsonify({'success': True})

@app.route('/api/history/export')
def export_history():
    """Export CSV de l'historique"""
    import csv
    import io
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(['Date', 'Titre', 'URL', 'Format', 'Qualité', 'Type', 'Fichier', 'Dossier'])
    for h in downloads_history:
        writer.writerow([
            h.get('timestamp', ''), h.get('title', ''), h.get('url', ''),
            h.get('format', ''), h.get('quality', ''), h.get('type', ''),
            h.get('filename', ''), h.get('dir', '')
        ])
    return Response(
        output.getvalue(),
        mimetype='text/csv',
        headers={'Content-Disposition': 'attachment; filename=yt-nexus-history.csv'}
    )

# ─── FILE D'ATTENTE ──────────────────────────────────────────────────────────
download_queue = []  # liste de dicts {url, opts, title, id}
queue_lock = threading.Lock()
queue_running = False
MAX_CONCURRENT = 2  # nb téléchargements simultanés depuis la file

def _queue_worker():
    """Worker qui dépile la file d'attente en respectant MAX_CONCURRENT"""
    global queue_running
    while True:
        with queue_lock:
            active_count = len([d for d in downloads_progress.values()
                                 if d.get('status') in ('downloading', 'starting', 'merging', 'converting')])
            if not download_queue or active_count >= MAX_CONCURRENT:
                if not download_queue:
                    queue_running = False
                    return
                time.sleep(1)
                continue
            item = download_queue.pop(0)

        # Lancer le téléchargement
        url = item['url']
        opts = item['opts']
        dl_id = item['id']
        download_dir = get_download_dir()
        downloads_progress[dl_id]['status'] = 'downloading'

        def _run(dl_id=dl_id, url=url, opts=opts, download_dir=download_dir):
            result = run_with_auto_retry(
                build_cmd=lambda: build_ydl_cmd(url, opts, download_dir),
                proc_key=dl_id, max_attempts=5, base_wait=5, max_wait=60,
            )
            if result['paused'] or result['stopped']:
                return
            if result['success']:
                downloads_progress[dl_id].update({'status': 'done', 'percent': 100, 'completed_at': time.time()})
                downloads_history.insert(0, {'id': dl_id, 'url': url,
                    'title': downloads_progress[dl_id].get('title', ''),
                    'filename': downloads_progress[dl_id].get('filename', ''),
                    'quality': opts.get('quality'), 'format': opts.get('format'),
                    'type': opts.get('type'), 'timestamp': time.strftime('%d/%m/%Y %H:%M'),
                    'dir': str(download_dir), 'platform': detect_platform(url)})
                if len(downloads_history) > 200: downloads_history.pop()
            else:
                downloads_progress[dl_id].update({'status': 'error', 'error': result['error']})
        threading.Thread(target=_run, daemon=True).start()
        time.sleep(0.5)

@app.route('/api/queue/add', methods=['POST'])
def queue_add():
    """Ajouter un téléchargement à la file d'attente"""
    global queue_running
    data = request.get_json()
    url = clean_url(data.get('url', ''))
    if not url or not is_valid_url(url):
        return jsonify({'error': 'URL invalide'}), 400
    opts = {
        'type': data.get('type', 'video'),
        'quality': data.get('quality', 'best'),
        'format': data.get('format', 'mp4'),
        'audio_lang': data.get('audio_lang', ''),
        'audio_format_id': data.get('audio_format_id', ''),
        'dl_subs': data.get('dl_subs', False),
        'sub_lang': data.get('sub_lang', 'fr'),
        'sub_format': data.get('sub_format', 'srt'),
        'bitrate': data.get('bitrate', ''),
        'turbo': data.get('turbo', False),
        'turbo_fragments': data.get('turbo_fragments', 4),
        'start_time': data.get('start_time', ''),
        'end_time': data.get('end_time', ''),
    }
    dl_id = f"q_{int(time.time()*1000)}_{hashlib.md5(url.encode()).hexdigest()[:6]}"
    downloads_progress[dl_id] = {
        'status': 'queued', 'percent': 0, 'speed': '—', 'downloaded': '—',
        'total': '—', 'eta': '—', 'filename': '', 'error': None,
        'title': data.get('title', 'En attente...'), 'type': 'single',
        'paused': False, 'url': url, 'started': time.time(),
        'platform': detect_platform(url), 'format_type': opts['type'],
        'stderr_log': [], 'opts': opts, 'download_dir': str(get_download_dir()),
    }
    with queue_lock:
        download_queue.append({'url': url, 'opts': opts, 'title': data.get('title', url), 'id': dl_id})
    if not queue_running:
        queue_running = True
        threading.Thread(target=_queue_worker, daemon=True).start()
    return jsonify({'download_id': dl_id, 'queue_position': len(download_queue)})

@app.route('/api/queue', methods=['GET'])
def get_queue():
    with queue_lock:
        return jsonify({'queue': download_queue, 'length': len(download_queue)})

@app.route('/api/queue/clear', methods=['POST'])
def clear_queue():
    with queue_lock:
        n = len(download_queue)
        download_queue.clear()
    return jsonify({'success': True, 'cleared': n})

@app.route('/api/queue/max-concurrent', methods=['POST'])
def set_max_concurrent():
    global MAX_CONCURRENT
    data = request.get_json()
    val = int(data.get('value', 2))
    MAX_CONCURRENT = max(1, min(5, val))
    return jsonify({'success': True, 'max_concurrent': MAX_CONCURRENT})

# ─── REPRISE .PART INTELLIGENTE ───────────────────────────────────────────────
@app.route('/api/part-info/<download_id>', methods=['GET'])
def get_part_info(download_id):
    """Détecter le fichier .part existant et son avancement"""
    if download_id not in downloads_progress:
        return jsonify({'error': 'Téléchargement introuvable'}), 404
    info = downloads_progress[download_id]
    dl_dir = Path(info.get('download_dir', str(get_download_dir())))
    parts = list(dl_dir.glob('*.part')) + list(dl_dir.glob('*.ytdl'))
    part_files = []
    for p in parts:
        try:
            sz = p.stat().st_size
            part_files.append({'name': p.name, 'path': str(p), 'size_mb': round(sz / (1024*1024), 2)})
        except: pass
    # Essayer d'estimer le % déjà téléchargé
    pct_estimate = None
    if part_files and info.get('opts'):
        total_hint = None
        # Pas de taille totale connue sans refetch, on retourne juste les infos brutes
        pass
    return jsonify({'part_files': part_files, 'can_resume': len(part_files) > 0})

# ─── PROFILS DE TÉLÉCHARGEMENT ───────────────────────────────────────────────
PROFILES_FILE = Path.home() / '.yt-nexus-profiles.json'

def load_profiles():
    try:
        if PROFILES_FILE.exists():
            with open(PROFILES_FILE) as f:
                return json.load(f)
    except: pass
    # Profils par défaut
    return [
        {'id': 'hd_mp4',   'name': '🎬 Vidéo HD (1080p MP4)', 'opts': {'type': 'video', 'quality': '1080', 'format': 'mp4', 'turbo': True, 'turbo_fragments': 6}},
        {'id': 'mp3_best', 'name': '🎵 Audio MP3 meilleure qualité', 'opts': {'type': 'audio', 'format': 'mp3', 'bitrate': '320 kbps', 'turbo': False}},
        {'id': '4k_mkv',   'name': '🏆 Vidéo 4K (MKV)', 'opts': {'type': 'video', 'quality': '2160', 'format': 'mkv', 'turbo': True, 'turbo_fragments': 8}},
        {'id': 'sub_fr',   'name': '🇫🇷 Vidéo + Sous-titres FR', 'opts': {'type': 'video', 'quality': '1080', 'format': 'mp4', 'dl_subs': True, 'sub_lang': 'fr', 'sub_format': 'srt'}},
        {'id': 'audio_m4a','name': '🎶 Audio M4A (meilleure qualité)', 'opts': {'type': 'audio', 'format': 'm4a', 'bitrate': '', 'turbo': False}},
    ]

def save_profiles(profiles):
    try:
        with open(PROFILES_FILE, 'w') as f:
            json.dump(profiles, f, indent=2)
        return True
    except: return False

@app.route('/api/profiles', methods=['GET'])
def get_profiles():
    return jsonify(load_profiles())

@app.route('/api/profiles', methods=['POST'])
def create_profile():
    data = request.get_json()
    name = data.get('name', '').strip()
    opts = data.get('opts', {})
    if not name:
        return jsonify({'error': 'Nom du profil requis'}), 400
    profiles = load_profiles()
    profile_id = f"p_{int(time.time()*1000)}"
    profiles.append({'id': profile_id, 'name': name, 'opts': opts})
    save_profiles(profiles)
    return jsonify({'success': True, 'id': profile_id})

@app.route('/api/profiles/<profile_id>', methods=['PUT'])
def update_profile(profile_id):
    data = request.get_json()
    profiles = load_profiles()
    for p in profiles:
        if p['id'] == profile_id:
            if 'name' in data: p['name'] = data['name']
            if 'opts' in data: p['opts'] = data['opts']
            save_profiles(profiles)
            return jsonify({'success': True})
    return jsonify({'error': 'Profil introuvable'}), 404

@app.route('/api/profiles/<profile_id>', methods=['DELETE'])
def delete_profile(profile_id):
    profiles = load_profiles()
    new_profiles = [p for p in profiles if p['id'] != profile_id]
    if len(new_profiles) == len(profiles):
        return jsonify({'error': 'Profil introuvable'}), 404
    save_profiles(new_profiles)
    return jsonify({'success': True})

# ═══════════════════════════════════════════════════════════════════════════
#  YT-NEXUS AETHER v7 — Premium APIs
# ═══════════════════════════════════════════════════════════════════════════

WATCHLATER_FILE = Path.home() / '.yt-nexus-watchlater.json'
SCHEDULE_FILE = Path.home() / '.yt-nexus-schedule.json'
_schedule_lock = threading.Lock()
_scheduled_jobs = []  # loaded into memory
_schedule_thread_started = False


def _load_json_file(path, default=None):
    if default is None:
        default = []
    try:
        if path.exists():
            with open(path) as f:
                return json.load(f)
    except Exception:
        pass
    return default


def _save_json_file(path, data):
    try:
        with open(path, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return True
    except Exception:
        return False


@app.route('/api/v7/version')
def v7_version():
    return jsonify({
        'version': APP_VERSION,
        'name': 'YT-NEXUS AETHER',
        'features': [
            'sponsorblock', 'watchlater', 'schedule',
            'profiles', 'queue', 'disk', 'clipboard_watch', 'notifications',
        ],
    })


@app.route('/api/v7/disk')
def v7_disk():
    """Espace disque du dossier de téléchargement."""
    d = get_download_dir()
    try:
        usage = shutil.disk_usage(str(d))
        total = usage.total
        used = usage.used
        free = usage.free
        # Size of download folder itself
        folder_bytes = 0
        try:
            for f in d.rglob('*'):
                if f.is_file():
                    try:
                        folder_bytes += f.stat().st_size
                    except OSError:
                        pass
        except OSError:
            pass
        return jsonify({
            'path': str(d),
            'total': total,
            'used': used,
            'free': free,
            'total_h': format_bytes(total),
            'used_h': format_bytes(used),
            'free_h': format_bytes(free),
            'folder_bytes': folder_bytes,
            'folder_h': format_bytes(folder_bytes),
            'percent_used': round(100 * used / total, 1) if total else 0,
            'folder_percent': round(100 * folder_bytes / total, 2) if total else 0,
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500




@app.route('/api/v7/watchlater', methods=['GET'])
def v7_watchlater_list():
    return jsonify({'items': _load_json_file(WATCHLATER_FILE, [])})


@app.route('/api/v7/watchlater', methods=['POST'])
def v7_watchlater_add():
    data = request.get_json() or {}
    url = clean_url(data.get('url', ''))
    if not url or not is_valid_url(url):
        return jsonify({'error': 'URL invalide'}), 400
    items = _load_json_file(WATCHLATER_FILE, [])
    if any(i.get('url') == url for i in items):
        return jsonify({'success': True, 'already': True, 'items': items})
    item = {
        'id': f"wl_{int(time.time()*1000)}",
        'url': url,
        'title': data.get('title') or url,
        'thumbnail': data.get('thumbnail') or '',
        'platform': detect_platform(url),
        'added': time.time(),
        'added_h': time.strftime('%d/%m/%Y %H:%M'),
        'note': data.get('note') or '',
    }
    items.insert(0, item)
    items = items[:200]
    _save_json_file(WATCHLATER_FILE, items)
    return jsonify({'success': True, 'item': item, 'items': items})


@app.route('/api/v7/watchlater/<item_id>', methods=['DELETE'])
def v7_watchlater_delete(item_id):
    items = _load_json_file(WATCHLATER_FILE, [])
    new_items = [i for i in items if i.get('id') != item_id]
    _save_json_file(WATCHLATER_FILE, new_items)
    return jsonify({'success': True, 'items': new_items})


@app.route('/api/v7/watchlater/clear', methods=['POST'])
def v7_watchlater_clear():
    _save_json_file(WATCHLATER_FILE, [])
    return jsonify({'success': True})


@app.route('/api/v7/schedule', methods=['GET'])
def v7_schedule_list():
    with _schedule_lock:
        jobs = _load_json_file(SCHEDULE_FILE, [])
    return jsonify({'jobs': jobs})


@app.route('/api/v7/schedule', methods=['POST'])
def v7_schedule_add():
    """Planifier un téléchargement (ISO datetime ou minutes from now)."""
    data = request.get_json() or {}
    url = clean_url(data.get('url', ''))
    if not url:
        return jsonify({'error': 'URL manquante'}), 400
    opts = data.get('opts') or {'type': 'video', 'quality': '1080', 'format': 'mp4', 'turbo': True}
    run_at = data.get('run_at')  # unix ts or ISO
    delay_min = data.get('delay_min')
    now = time.time()
    if run_at:
        try:
            if isinstance(run_at, (int, float)):
                when = float(run_at)
            else:
                # ISO-ish
                from datetime import datetime
                when = datetime.fromisoformat(str(run_at).replace('Z', '')).timestamp()
        except Exception:
            return jsonify({'error': 'run_at invalide'}), 400
    elif delay_min is not None:
        when = now + max(0.5, float(delay_min)) * 60
    else:
        when = now + 5 * 60

    job = {
        'id': f"sch_{int(now*1000)}",
        'url': url,
        'title': data.get('title') or url[:80],
        'opts': opts,
        'run_at': when,
        'run_at_h': time.strftime('%d/%m/%Y %H:%M', time.localtime(when)),
        'status': 'scheduled',
        'created': now,
    }
    with _schedule_lock:
        jobs = _load_json_file(SCHEDULE_FILE, [])
        jobs.append(job)
        _save_json_file(SCHEDULE_FILE, jobs)
    _ensure_schedule_worker()
    return jsonify({'success': True, 'job': job})


@app.route('/api/v7/schedule/<job_id>', methods=['DELETE'])
def v7_schedule_delete(job_id):
    with _schedule_lock:
        jobs = _load_json_file(SCHEDULE_FILE, [])
        jobs = [j for j in jobs if j.get('id') != job_id]
        _save_json_file(SCHEDULE_FILE, jobs)
    return jsonify({'success': True})


def _ensure_schedule_worker():
    global _schedule_thread_started
    if _schedule_thread_started:
        return
    _schedule_thread_started = True

    def _worker():
        global queue_running
        while True:
            try:
                now = time.time()
                with _schedule_lock:
                    jobs = _load_json_file(SCHEDULE_FILE, [])
                    due = [j for j in jobs if j.get('status') == 'scheduled' and float(j.get('run_at', 0)) <= now]
                    if due:
                        for j in jobs:
                            if j.get('id') in {d['id'] for d in due}:
                                j['status'] = 'queued'
                        _save_json_file(SCHEDULE_FILE, jobs)
                for j in due:
                    url = j.get('url')
                    opts = j.get('opts') or {}
                    title = j.get('title') or url
                    dl_id = f"sch_dl_{int(time.time()*1000)}_{j['id'][-6:]}"
                    downloads_progress[dl_id] = {
                        'status': 'queued', 'percent': 0, 'speed': '—',
                        'downloaded': '—', 'total': '—', 'eta': '—',
                        'filename': '', 'error': None, 'title': title,
                        'type': 'single', 'paused': False, 'url': url,
                        'started': time.time(), 'platform': detect_platform(url),
                        'format_type': opts.get('type', 'video'), 'stderr_log': [],
                        'opts': opts, 'download_dir': str(get_download_dir()),
                        'scheduled_from': j.get('id'),
                    }
                    with queue_lock:
                        download_queue.append({'url': url, 'opts': opts, 'title': title, 'id': dl_id})
                    if not queue_running:
                        queue_running = True
                        threading.Thread(target=_queue_worker, daemon=True).start()
                    with _schedule_lock:
                        jobs2 = _load_json_file(SCHEDULE_FILE, [])
                        for x in jobs2:
                            if x.get('id') == j.get('id'):
                                x['status'] = 'started'
                                x['download_id'] = dl_id
                        _save_json_file(SCHEDULE_FILE, jobs2)
            except Exception:
                pass
            time.sleep(15)

    threading.Thread(target=_worker, daemon=True).start()


@app.route('/api/v7/stats')
def v7_stats():
    """Stats globales premium pour le dashboard."""
    hist = downloads_history or []
    active = [d for d in downloads_progress.values()
              if d.get('status') in ACTIVE_STATUSES]
    done = [d for d in downloads_progress.values() if d.get('status') == 'done']
    failed = [d for d in downloads_progress.values()
              if d.get('status') in ('failed', 'error')]
    platforms = {}
    for d in list(downloads_progress.values()) + hist:
        p = d.get('platform')
        name = p.get('name') if isinstance(p, dict) else (p or 'unknown')
        platforms[name] = platforms.get(name, 0) + 1
    wl = _load_json_file(WATCHLATER_FILE, [])
    sch = _load_json_file(SCHEDULE_FILE, [])
    with queue_lock:
        qlen = len(download_queue)
    return jsonify({
        'version': APP_VERSION,
        'active': len(active),
        'done_session': len(done),
        'failed_session': len(failed),
        'history': len(hist),
        'queue': qlen,
        'watchlater': len(wl),
        'scheduled': len([j for j in sch if j.get('status') == 'scheduled']),
        'platforms': platforms,
        'download_dir': str(get_download_dir()),
    })


if __name__ == '__main__':
    dl_dir = get_download_dir()
    deps = check_dependencies()
    
    # Charger l'état des téléchargements depuis la session précédente
    load_download_state()
    _ensure_schedule_worker()
    
    print(f"\n{'='*65}")
    print(f"  🚀 YT-NEXUS AETHER v{APP_VERSION} ULTRA — Backend démarré!")
    print(f"{'='*65}")
    print(f"  📁 Téléchargements → {dl_dir}")
    print(f"  🌐 Interface       → http://localhost:5050")
    print(f"  🔧 yt-dlp          → {'✅ ' + deps['yt_dlp']['version'] if deps['yt_dlp']['ok'] else '❌ Non installé'}")
    print(f"  🎬 ffmpeg          → {'✅ ' + deps['ffmpeg']['version'] if deps['ffmpeg']['ok'] else '❌ Non installé (qualité réduite)'}")
    print(f"{'='*65}\n")
    
    if not deps['yt_dlp']['ok']:
        print("⚠️  ATTENTION: yt-dlp non trouvé! Installez avec: pip install yt-dlp")
    if not deps['ffmpeg']['ok']:
        print("⚠️  ATTENTION: ffmpeg non trouvé! Les téléchargements HD peuvent échouer.")
        print("   Ubuntu/Debian: sudo apt install ffmpeg")
        print("   Windows: https://ffmpeg.org/download.html")
    
    # Démarrer la sauvegarde automatique périodique (toutes les 30 secondes)
    def auto_save_state():
        while True:
            time.sleep(30)
            save_download_state()
    
    save_thread = threading.Thread(target=auto_save_state, daemon=True)
    save_thread.start()
    
    # Gestionnaire d'arrêt propre
    def cleanup_handler(signum, frame):
        print("\n🛑 Arrêt de l'application...")
        save_download_state()
        print("✅ État sauvegardé")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, cleanup_handler)
    signal.signal(signal.SIGTERM, cleanup_handler)
    
    port = int(os.getenv('PORT', 5050))
    app.run(host='0.0.0.0', port=port, debug=False, threaded=True)
