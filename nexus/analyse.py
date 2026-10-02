"""Récupération des infos (vidéo, playlist, chaîne, recherche) via l'API yt-dlp."""
import copy
import re
import threading
import time
from urllib.parse import parse_qs, urlparse

import yt_dlp

from . import config, erreurs, formats, langues

DUREE_CACHE = 30 * 60          # les liens YouTube expirent après ~6 h
TAILLE_CACHE = 24
_cache = {}                    # url ou id → (temps, info brute)
_verrou = threading.Lock()


class ErreurAnalyse(Exception):
    def __init__(self, message, passagere=False):
        super().__init__(message)
        self.passagere = passagere


class _Journal:
    """Garde les erreurs yt-dlp pour produire un message lisible."""

    def __init__(self):
        self.lignes = []

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        pass

    def error(self, msg):
        self.lignes.append(msg)


def options_base(**extra):
    r = config.lire_reglages()
    return {
        "quiet": True, "no_warnings": True, "skip_download": True,
        "socket_timeout": 20, "extractor_retries": 3,
        **config.options_auth(r), **extra,
    }


def _extraire(url, **opts):
    journal = _Journal()
    try:
        with yt_dlp.YoutubeDL(options_base(logger=journal, **opts)) as ydl:
            return ydl.sanitize_info(ydl.extract_info(url, download=False))
    except yt_dlp.utils.DownloadError as e:
        message, passagere = erreurs.analyser("\n".join(journal.lignes) or str(e))
        raise ErreurAnalyse(message, passagere) from None


def info_complete(url, frais=False):
    """Infos complètes d'une vidéo (avec formats), mises en cache."""
    with _verrou:
        ent = _cache.get(url)
        if ent and not frais and time.time() - ent[0] < DUREE_CACHE:
            return copy.deepcopy(ent[1])
    info = _extraire(url, noplaylist=True)
    with _verrou:
        _cache[url] = _cache[info.get("webpage_url") or url] = (time.time(), info)
        while len(_cache) > TAILLE_CACHE * 2:
            del _cache[min(_cache, key=lambda k: _cache[k][0])]
    return copy.deepcopy(info)


def oublier(url):
    with _verrou:
        _cache.pop(url, None)


def _miniature(e):
    if e.get("thumbnail"):
        return e["thumbnail"]
    thumbs = [t for t in e.get("thumbnails") or [] if t.get("url")]
    if thumbs:
        moyennes = [t for t in thumbs if 300 <= (t.get("width") or 0) <= 720]
        return (moyennes or thumbs)[-1]["url"]
    if e.get("ie_key") == "Youtube" or "youtube" in (e.get("url") or ""):
        return f"https://i.ytimg.com/vi/{e.get('id')}/mqdefault.jpg"
    return None


def _entree(e):
    url = e.get("url") or e.get("webpage_url")
    if url and not url.startswith("http") and e.get("ie_key") == "Youtube":
        url = f"https://www.youtube.com/watch?v={e['id']}"
    return {
        "id": e.get("id"), "titre": e.get("title") or "Sans titre", "url": url,
        "duree": e.get("duration"), "miniature": _miniature(e),
        "chaine": e.get("channel") or e.get("uploader"), "vues": e.get("view_count"),
        "direct": e.get("live_status") == "is_live",
    }


def normaliser_url(url):
    url = (url or "").strip()
    if url and not re.match(r"^[a-z]+://", url, re.I):
        url = "https://" + url
    p = urlparse(url)
    hote = p.netloc.lower().removeprefix("www.").removeprefix("m.")
    # Chaîne YouTube sans onglet → onglet Vidéos
    if hote == "youtube.com" and re.fullmatch(r"/(@[^/]+|channel/[^/]+|c/[^/]+|user/[^/]+)/?", p.path):
        url = url.split("?")[0].rstrip("/") + "/videos"
    return url


def playlist_associee(url):
    """Lien de la playlist si une vidéo est ouverte depuis une playlist."""
    p = urlparse(url)
    q = parse_qs(p.query)
    if "v" in q and "list" in q and not q["list"][0].startswith(("RD", "UL")):
        return f"https://www.youtube.com/playlist?list={q['list'][0]}"
    return None


def resume_video(info):
    pistes = formats.pistes_audio(info)
    originale = formats.langue_originale(info, pistes)
    r = config.lire_reglages()
    voulue = formats.trouver_piste(pistes, r["langue_audio"])
    qual, taille_audio = formats.qualites(info, voulue or originale)
    return {
        "type": "video",
        "id": info.get("id"), "url": info.get("webpage_url") or info.get("original_url"),
        "titre": info.get("title"), "chaine": info.get("channel") or info.get("uploader"),
        "chaine_url": info.get("channel_url") or info.get("uploader_url"),
        "duree": info.get("duration"), "vues": info.get("view_count"),
        "likes": info.get("like_count"), "date": info.get("upload_date"),
        "miniature": _miniature(info), "plateforme": info.get("extractor_key"),
        "direct": info.get("live_status") == "is_live",
        "chapitres": len(info.get("chapters") or []),
        "pistes": pistes, "originale": originale,
        "originale_nom": langues.nom(originale) if originale else None,
        "piste_voulue": voulue,
        "qualites": qual, "taille_audio": taille_audio,
        "sous_titres": formats.sous_titres_dispo(info),
        "playlist": playlist_associee(info.get("original_url") or ""),
    }


def analyser(url):
    url = normaliser_url(url)
    if not url.startswith("http"):
        raise ErreurAnalyse("Lien invalide.")
    if playlist_associee(url) or "/watch" in url or "/shorts/" in url or "youtu.be/" in url:
        brut = info_complete(url)
    else:
        brut = _extraire(url, extract_flat="in_playlist")
        if brut.get("_type") not in ("playlist", "multi_video") and brut.get("formats"):
            with _verrou:
                _cache[url] = (time.time(), brut)
    if brut.get("_type") in ("playlist", "multi_video") or brut.get("entries") is not None:
        entrees = [_entree(e) for e in brut.get("entries") or [] if e and e.get("id")]
        # Chaîne : les entrées peuvent être des onglets (Vidéos, Shorts…)
        if entrees and all("/playlist" in (e["url"] or "") or e["url"].rstrip("/").endswith(("/videos", "/shorts", "/streams")) for e in entrees):
            return analyser(entrees[0]["url"])
        return {
            "type": "playlist", "id": brut.get("id"), "url": url,
            "titre": brut.get("title") or "Playlist", "chaine": brut.get("channel") or brut.get("uploader"),
            "miniature": _miniature(brut) or (entrees[0]["miniature"] if entrees else None),
            "nombre": len(entrees), "entrees": entrees,
        }
    return resume_video(brut)


def rechercher(requete, nombre=24):
    brut = _extraire(f"ytsearch{nombre}:{requete}", extract_flat="in_playlist")
    return [_entree(e) for e in brut.get("entries") or [] if e and e.get("id")]
