"""Analyse des formats YouTube et construction de la sélection yt-dlp.

YouTube propose plusieurs pistes audio par vidéo (doublages humains ou IA).
yt-dlp prend par défaut la piste « originale » ; ici on choisit la piste
dans la langue voulue, en premier (lue par défaut), et on garde la VO en
deuxième piste si demandé.
"""
from . import langues

HAUTEURS = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]
LIBELLES = {4320: "8K", 2160: "4K", 1440: "2K", 1080: "FHD", 720: "HD"}


def _est_audio(f):
    return f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")


def _est_video(f):
    return f.get("vcodec") not in (None, "none")


def _taille(f):
    return f.get("filesize") or f.get("filesize_approx") or 0


def pistes_audio(info):
    """Pistes audio distinctes : [{code, nom, drapeau, genre, originale}]."""
    pistes = {}
    for f in info.get("formats") or []:
        if not _est_audio(f) or not f.get("language"):
            continue
        code = f["language"]
        note = (f.get("format_note") or "").lower()
        p = pistes.setdefault(code, {"code": code, "originale": False, "ia": False, "doublee": False})
        if "original" in note or (f.get("language_preference") or -1) >= 10:
            p["originale"] = True
        if "dubbed-auto" in note:
            p["ia"] = True
        elif "dubbed" in note:
            p["doublee"] = True
    if len(pistes) == 1:
        next(iter(pistes.values()))["originale"] = True
    resultat = []
    for p in pistes.values():
        genre = "originale" if p["originale"] else "doublage IA" if p["ia"] else "doublage"
        resultat.append({
            "code": p["code"], "nom": langues.nom(p["code"]), "drapeau": langues.drapeau(p["code"]),
            "genre": genre, "originale": p["originale"],
        })
    resultat.sort(key=lambda p: (not p["originale"], not langues.meme_langue(p["code"], "fr"), p["nom"]))
    return resultat


def langue_originale(info, pistes=None):
    for p in pistes if pistes is not None else pistes_audio(info):
        if p["originale"]:
            return p["code"]
    return info.get("language")


def trouver_piste(pistes, voulue):
    """Code de la piste correspondant à la langue voulue (fr → fr, fr-FR, fr-CA…)."""
    if not voulue or voulue == "original":
        return None
    exacte = [p["code"] for p in pistes if p["code"].lower() == voulue.lower()]
    if exacte:
        return exacte[0]
    proches = [p["code"] for p in pistes if langues.meme_langue(p["code"], voulue)]
    return proches[0] if proches else None


def qualites(info, piste=None):
    """Résolutions disponibles avec taille estimée (vidéo + audio choisi)."""
    formats = info.get("formats") or []
    audio = [f for f in formats if _est_audio(f)
             and (not piste or f.get("language") == piste)]
    taille_audio = max((_taille(f) for f in audio if f.get("ext") == "m4a"), default=0) \
        or max((_taille(f) for f in audio), default=0)
    par_hauteur = {}
    for f in formats:
        if not _est_video(f) or not f.get("height"):
            continue
        h = min(f["height"], f.get("width") or f["height"])  # vidéos verticales
        h = next((x for x in HAUTEURS if h >= x * 0.9), h)
        q = par_hauteur.setdefault(h, {"hauteur": h, "fps": 0, "hdr": False, "taille": 0})
        q["fps"] = max(q["fps"], int(f.get("fps") or 0))
        q["hdr"] = q["hdr"] or (f.get("dynamic_range") or "SDR") != "SDR"
        q["taille"] = max(q["taille"], _taille(f))
    res = []
    for h in sorted(par_hauteur, reverse=True):
        q = par_hauteur[h]
        q["libelle"] = f"{h}p" + (f"{q['fps']}" if q["fps"] > 30 else "")
        q["badge"] = LIBELLES.get(h, "")
        q["taille"] = q["taille"] + taille_audio if q["taille"] else 0
        res.append(q)
    return res, taille_audio


def plan_audio(info, langue, garder_vo):
    """Décide des pistes audio à télécharger.

    Renvoie (piste_voulue_trouvée|None, originale|None, garder_la_vo).
    """
    pistes = pistes_audio(info)
    originale = langue_originale(info, pistes)
    trouvee = trouver_piste(pistes, langue)
    if langue == "original" or (trouvee and originale and trouvee == originale):
        return None, originale, False
    return trouvee, originale, bool(trouvee and originale and garder_vo)


def selecteur(opts, piste, originale, deux_pistes):
    """Chaîne de sélection de formats yt-dlp, avec replis sûrs."""
    audio_voulu = f"ba[language={piste}]" if piste else (
        f"ba[language={originale}]" if originale else "ba")
    if opts.get("type") == "audio":
        return f"{audio_voulu}/ba/b"
    h = str(opts.get("qualite") or "best")
    video = f"bv*[height<={h}]" if h.isdigit() else "bv*"
    choix = []
    if deux_pistes:
        choix.append(f"{video}+{audio_voulu}+ba[language={originale}]")
    choix += [f"{video}+{audio_voulu}", f"{video}+ba", "b" if not h.isdigit() else f"b[height<={h}]/b"]
    return "/".join(choix)


def tri(opts):
    """Préférences de tri : formats compatibles avec le conteneur choisi."""
    conteneur = opts.get("conteneur") or "mp4"
    if opts.get("type") == "audio":
        return ["ext:m4a" if opts.get("format_audio") in ("m4a", "mp3") else "acodec:opus"]
    if conteneur == "mp4":
        return ["res", "fps", "ext:mp4:m4a"]
    if conteneur == "webm":
        return ["res", "fps", "ext:webm:webm"]
    return ["res", "fps"]


def sous_titres_dispo(info):
    manuels = sorted((info.get("subtitles") or {}).keys() - {"live_chat"})
    auto = info.get("automatic_captions") or {}
    return {
        "manuels": [{"code": c, "nom": langues.nom(c), "drapeau": langues.drapeau(c)} for c in manuels],
        "auto": bool(auto),
        "auto_fr": any(langues.meme_langue(c, "fr") for c in auto),
    }
