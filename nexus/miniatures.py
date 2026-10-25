"""Miniatures et métadonnées hors ligne : cache sur disque + extraction des fichiers locaux."""
import hashlib
import json
import re
import shutil
import subprocess
import threading
import urllib.request

from . import config, langues

EXT_VIDEO = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"}
EXT_AUDIO = {".mp3", ".m4a", ".opus", ".flac", ".wav", ".ogg", ".aac"}

_INDEX = config.CACHE_MINIATURES / "index.json"
_verrou = threading.Lock()
_en_cours = set()
_index = None

# ISO 639-2 (3 lettres, utilisé par ffprobe) → ISO 639-1 (2 lettres, utilisé par langues.py)
_ISO3 = {
    "fra": "fr", "fre": "fr", "eng": "en", "spa": "es", "deu": "de", "ger": "de",
    "ita": "it", "por": "pt", "nld": "nl", "dut": "nl", "pol": "pl", "rus": "ru",
    "ukr": "uk", "ara": "ar", "tur": "tr", "fas": "fa", "per": "fa", "heb": "he",
    "hin": "hi", "ben": "bn", "pan": "pa", "mar": "mr", "tam": "ta", "tel": "te",
    "mal": "ml", "urd": "ur", "ind": "id", "msa": "ms", "may": "ms", "vie": "vi",
    "tha": "th", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh", "swe": "sv",
    "nor": "no", "dan": "da", "fin": "fi", "ces": "cs", "cze": "cs", "slk": "sk",
    "slo": "sk", "ron": "ro", "rum": "ro", "hun": "hu", "ell": "el", "gre": "el",
    "bul": "bg", "srp": "sr", "hrv": "hr", "swa": "sw", "wol": "wo", "ful": "ff",
    "hau": "ha", "yor": "yo", "amh": "am",
}


def _cle(texte):
    return hashlib.sha1(texte.encode("utf-8")).hexdigest()[:20]


def chemin_url(url):
    if not url or not url.startswith("http"):
        return None
    return config.CACHE_MINIATURES / f"u_{_cle(url)}.img"


def locale(url):
    f = chemin_url(url)
    return f if f and f.is_file() and f.stat().st_size > 0 else None


def _ecrire_atomique(cible, octets):
    if not octets:
        return None
    tmp = cible.with_suffix(".tmp")
    try:
        tmp.write_bytes(octets)
        tmp.replace(cible)
        return cible
    except OSError:
        tmp.unlink(missing_ok=True)
        return None


def telecharger(url):
    """Télécharge et garde une miniature distante sur le disque."""
    cible = chemin_url(url)
    if not cible:
        return None
    if cible.is_file() and cible.stat().st_size > 0:
        return cible
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=12) as r:
            if r.status == 200:
                return _ecrire_atomique(cible, r.read(8_000_000))
    except Exception:
        pass
    return None


def garder(url):
    """Lance la mise en cache d'une URL en tâche de fond."""
    cible = chemin_url(url)
    if not cible or (cible.is_file() and cible.stat().st_size > 0):
        return
    with _verrou:
        if url in _en_cours:
            return
        _en_cours.add(url)

    def _travail():
        try:
            telecharger(url)
        finally:
            with _verrou:
                _en_cours.discard(url)

    threading.Thread(target=_travail, daemon=True).start()


def garder_toutes(urls):
    for u in urls:
        if u and u.startswith("http"):
            garder(u)


def mimetype(octets):
    if octets.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if octets.startswith(b"RIFF") and octets[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


# ── inspection des fichiers locaux (ffprobe + extraction de vignette) ─
def _charger_index():
    global _index
    if _index is not None:
        return _index
    try:
        _index = json.loads(_INDEX.read_text())
    except (OSError, ValueError):
        _index = {}
    return _index


def _sauver_index():
    if _index is None:
        return
    tmp = _INDEX.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(_index, ensure_ascii=False))
        tmp.replace(_INDEX)
    except OSError:
        pass


def _id_youtube(texte):
    if not texte:
        return None
    m = re.search(r"(?:v=|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})", texte)
    if m:
        return m.group(1)
    m = re.search(r"\[([A-Za-z0-9_-]{11})\]\.[a-z0-9]+$", texte, re.I)
    return m.group(1) if m else None


def _extraire_meta(chemin):
    """Lit durée, titre, chaîne, pistes audio, codecs et présence de pochette via ffprobe."""
    meta = {
        "duree": None, "titre": None, "pistes": None,
        "yt_id": _id_youtube(chemin.name), "pochette": False,
        "vcodec": None, "acodec": None, "nb_audios": 0, "publiable": None,
    }
    if not shutil.which("ffprobe"):
        return meta
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(chemin)],
            capture_output=True, text=True, timeout=6,
        )
        d = json.loads(r.stdout or "{}")
    except Exception:
        return meta

    fmt = d.get("format") or {}
    tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items() if isinstance(v, str)}
    if fmt.get("duration"):
        try:
            meta["duree"] = round(float(fmt["duration"]))
        except ValueError:
            pass
    if tags.get("title"):
        meta["titre"] = tags["title"].strip()
    for champ in ("purl", "comment", "synopsis", "description"):
        if not meta["yt_id"] and tags.get(champ):
            meta["yt_id"] = _id_youtube(tags[champ])

    streams = d.get("streams") or []
    meta["pochette"] = any((s.get("disposition") or {}).get("attached_pic") == 1 for s in streams)

    videos = [s for s in streams if s.get("codec_type") == "video" and (s.get("disposition") or {}).get("attached_pic") != 1]
    audios = [s for s in streams if s.get("codec_type") == "audio"]
    subs = [s for s in streams if s.get("codec_type") in ("subtitle", "data")]
    if videos:
        meta["vcodec"] = (videos[0].get("codec_name") or "").lower()
    if audios:
        meta["acodec"] = (audios[0].get("codec_name") or "").lower()
    meta["nb_audios"] = len(audios)
    if chemin.suffix.lower() in EXT_VIDEO and videos:
        meta["publiable"] = bool(
            chemin.suffix.lower() == ".mp4"
            and meta["vcodec"] in ("h264", "avc1", "avc")
            and (not audios or meta["acodec"] in ("aac", "mp4a"))
            and len(audios) <= 1
            and not meta["pochette"]
            and not subs
        )
    libelles = []
    bruit = ("soundhandler", "videohandler", "isomedia", "iso media", "gpac", "core media", "apple", "ffmpeg")
    for s in audios:
        stags = {k.lower(): v for k, v in (s.get("tags") or {}).items() if isinstance(v, str)}
        hn = (stags.get("title") or stags.get("handler_name") or "").strip()
        if any(b in hn.lower() for b in bruit):
            hn = ""
        lang = (stags.get("language") or "").lower()
        code = _ISO3.get(lang, lang if lang and lang != "und" else "")
        if hn:
            drap = langues.drapeau(code) if code else ""
            if "(VO)" in hn and code:
                libelles.append(f"{drap} VO".strip())
            elif drap and not hn.startswith(drap):
                libelles.append(f"{drap} {hn}")
            else:
                libelles.append(hn)
        elif code:
            libelles.append(f"{langues.drapeau(code)} {langues.nom(code)}")
    if libelles:
        meta["pistes"] = " + ".join(dict.fromkeys(libelles))
    elif len(audios) == 1:
        meta["pistes"] = "Piste unique"
    return meta


def infos_fichier(chemin):
    """Métadonnées mises en cache par (chemin, mtime, taille)."""
    st = chemin.stat()
    signature = f"{int(st.st_mtime)}:{st.st_size}"
    cle = str(chemin)
    with _verrou:
        idx = _charger_index()
        ent = idx.get(cle)
        if ent and ent.get("sig") == signature:
            return ent
    meta = _extraire_meta(chemin)
    meta["sig"] = signature
    with _verrou:
        idx = _charger_index()
        idx[cle] = meta
        _sauver_index()
    return meta


def vignette_fichier(chemin, url_secours=None):
    """Retourne le fichier image en cache pour un média local (l'extrait ou le télécharge au besoin)."""
    if url_secours:
        loc = locale(url_secours)
        if loc:
            return loc
    try:
        st = chemin.stat()
    except OSError:
        return None
    cible = config.CACHE_MINIATURES / f"f_{_cle(f'{chemin}:{int(st.st_mtime)}:{st.st_size}')}.img"
    if cible.is_file() and cible.stat().st_size > 0:
        return cible

    meta = infos_fichier(chemin)
    # 1. Pochette embarquée dans le conteneur (MP4, MKV, MP3, M4A, FLAC…)
    if meta.get("pochette") and shutil.which("ffmpeg"):
        try:
            r = subprocess.run(
                ["ffmpeg", "-v", "error", "-i", str(chemin), "-map", "0:v", "-map", "-0:V", "-frames:v", "1", "-c", "copy", "-f", "image2pipe", "-"],
                capture_output=True, timeout=8,
            )
            if r.returncode == 0 and r.stdout:
                return _ecrire_atomique(cible, r.stdout)
        except Exception:
            pass

    # 2. URL de secours (tâche connue ou miniature YouTube déduite des tags / du nom)
    yt_id = meta.get("yt_id")
    for u in filter(None, [url_secours, f"https://i.ytimg.com/vi/{yt_id}/hqdefault.jpg" if yt_id else None]):
        f = telecharger(u)
        if f:
            return f

    # 3. Vidéo sans pochette (ex. montage personnel) : capture d'une image de la vidéo
    if chemin.suffix.lower() in EXT_VIDEO and shutil.which("ffmpeg"):
        duree = meta.get("duree") or 0
        pos = min(5, max(0, duree * 0.1)) if duree > 1 else 0
        try:
            r = subprocess.run(
                ["ffmpeg", "-v", "error", "-ss", f"{pos:.1f}", "-i", str(chemin), "-frames:v", "1", "-vf", "scale='min(640,iw)':-2", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "4", "-"],
                capture_output=True, timeout=10,
            )
            if r.returncode == 0 and r.stdout:
                return _ecrire_atomique(cible, r.stdout)
        except Exception:
            pass
    return None
