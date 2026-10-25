"""API HTTP + flux d'événements (SSE) + interface."""
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import threading
from importlib import metadata
from pathlib import Path

from flask import Blueprint, Flask, Response, abort, jsonify, request, send_file, stream_with_context

from . import VERSION, analyse, config, formats, gouts, langues, miniatures, taches

api = Blueprint("api", __name__, url_prefix="/api")
STATIQUE = config.RACINE / "static"


def _erreur(message, code=400):
    return jsonify({"erreur": message}), code


def _corps():
    return request.get_json(silent=True) or {}


def _version(paquet):
    try:
        return metadata.version(paquet)
    except metadata.PackageNotFoundError:
        return None


# ── état / réglages ─────────────────────────────────────────────────
@api.get("/etat")
def etat():
    r = config.lire_reglages()
    dossier = config.dossier_telechargement(r)
    disque = shutil.disk_usage(dossier)
    terminees = [t for t in taches.gestionnaire.liste() if t["statut"] == "termine"]
    return jsonify({
        "version": VERSION, "ytdlp": _version("yt-dlp"), "ejs": _version("yt-dlp-ejs"),
        "ffmpeg": bool(shutil.which("ffmpeg")), "deno": bool(shutil.which("deno") or shutil.which("node")),
        "local": not config.SUR_SERVEUR, "dossier": str(dossier),
        "disque": {"libre": disque.free, "total": disque.total},
        "cookies_fichier": config.FICHIER_COOKIES.exists(),
        "stats": {"fichiers": len(terminees), "octets": sum(t["taille_fichier"] or 0 for t in terminees)},
        "reglages": r,
    })


@api.post("/reglages")
def reglages():
    modifs = _corps()
    if "dossier" in modifs:
        try:
            Path(modifs["dossier"]).expanduser().mkdir(parents=True, exist_ok=True)
        except OSError as e:
            return _erreur(f"Dossier inutilisable : {e.strerror}")
    return jsonify(config.ecrire_reglages(modifs))


@api.post("/cookies")
def envoyer_cookies():
    f = request.files.get("fichier")
    if not f:
        return _erreur("Aucun fichier reçu.")
    contenu = f.read(2_000_000).decode("utf-8", "replace")
    if "youtube.com" not in contenu or "\t" not in contenu:
        return _erreur("Ce n'est pas un fichier cookies.txt (format Netscape) contenant YouTube.")
    config.FICHIER_COOKIES.write_text(contenu)
    os.chmod(config.FICHIER_COOKIES, 0o600)
    return jsonify({"ok": True})


@api.delete("/cookies")
def supprimer_cookies():
    config.FICHIER_COOKIES.unlink(missing_ok=True)
    return jsonify({"ok": True})


_maj = {"en_cours": False, "sortie": ""}


@api.post("/maj-ytdlp")
def maj_ytdlp():
    if _maj["en_cours"]:
        return _erreur("Mise à jour déjà en cours.")

    def travail():
        _maj.update(en_cours=True, sortie="")
        dans_venv = sys.prefix != sys.base_prefix
        cmd = [sys.executable, "-m", "pip", "install", "-U", "--quiet", "yt-dlp[default]"]
        if not dans_venv:
            cmd += ["--user", "--break-system-packages"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        _maj.update(en_cours=False, code=r.returncode, sortie=(r.stdout + r.stderr)[-1500:],
                    version=subprocess.run(config.commande_ytdlp() + ["--version"], capture_output=True,
                                           text=True).stdout.strip())

    threading.Thread(target=travail, daemon=True).start()
    return jsonify({"ok": True})


@api.get("/maj-ytdlp")
def etat_maj():
    return jsonify(_maj)


# ── analyse / recherche ─────────────────────────────────────────────
@api.post("/analyse")
def analyser():
    url = (_corps().get("url") or "").strip()
    if not url:
        return _erreur("Colle un lien.")
    try:
        res = analyse.analyser(url)
        if res.get("type") == "video":
            gouts.gestionnaire.signal(
                "analyse", url=url, id_=res.get("id"),
                titre=res.get("titre"), chaine=res.get("chaine")
            )
        return jsonify(res)
    except analyse.ErreurAnalyse as e:
        return _erreur(str(e), 422)


@api.post("/recherche")
def rechercher():
    q = (_corps().get("q") or "").strip()
    if not q:
        return _erreur("Recherche vide.")
    try:
        gouts.gestionnaire.ajouter_recherche(q)
        filtres = {k: v for k, v in (_corps().get("filtres") or {}).items() if v}
        return jsonify({"resultats": analyse.rechercher(q, filtres)})
    except analyse.ErreurAnalyse as e:
        return _erreur(str(e), 422)


@api.get("/recherche/suggestions")
def suggestions_recherche():
    q = request.args.get("q", "").strip()
    return jsonify({"suggestions": gouts.gestionnaire.suggestions(q)})


@api.get("/gouts/fil")
def gouts_fil():
    if not gouts.gestionnaire.fil:
        return jsonify(gouts.gestionnaire.rafraichir(force=False))
    if gouts.gestionnaire.fil_perime():
        threading.Thread(target=gouts.gestionnaire.rafraichir, daemon=True).start()
    return jsonify(gouts.gestionnaire.etat())


@api.post("/gouts/rafraichir")
def gouts_rafraichir():
    return jsonify(gouts.gestionnaire.rafraichir(force=True))


@api.post("/gouts/signal")
def gouts_signal():
    d = _corps()
    type_ = d.get("type") or "clic"
    gouts.gestionnaire.signal(
        type_,
        url=d.get("url"),
        id_=d.get("id"),
        titre=d.get("titre"),
        chaine=d.get("chaine"),
        chaine_id=d.get("cid"),
    )
    return jsonify({"ok": True})


@api.post("/gouts/pas-interesse")
def gouts_pas_interesse():
    d = _corps()
    gouts.gestionnaire.pas_interesse(id_=d.get("id"), titre=d.get("titre"), chaine=d.get("chaine"))
    return jsonify({"ok": True})


@api.post("/gouts/bloquer-chaine")
def gouts_bloquer_chaine():
    d = _corps()
    gouts.gestionnaire.bloquer_chaine(d.get("chaine"))
    return jsonify({"ok": True})


@api.post("/gouts/oublier-recherche")
def gouts_oublier_recherche():
    d = _corps()
    gouts.gestionnaire.oublier_recherche(d.get("q") or d.get("requete"))
    return jsonify({"ok": True})


# ── téléchargements ─────────────────────────────────────────────────
OPTIONS_PERMISES = {
    "type", "qualite", "conteneur", "compatible", "sans_trace", "vertical", "decoupe",
    "format_audio", "qualite_audio", "langue_audio", "garder_vo",
    "sous_titres", "sous_titres_auto", "sous_titres_fichier", "sponsorblock", "debut", "fin",
    "chapitres_separes", "programme",
}


@api.get("/telechargements")
def lister():
    return jsonify({"taches": taches.gestionnaire.liste(), "rev": taches.gestionnaire.rev})


@api.post("/telechargements")
def ajouter():
    d = _corps()
    elements = [e for e in d.get("elements") or [] if isinstance(e, dict) and e.get("url")]
    if not elements:
        return _erreur("Rien à télécharger.")
    for e in elements:
        gouts.gestionnaire.signal(
            "telechargement",
            url=e.get("url"),
            titre=e.get("titre"),
            chaine=e.get("chaine"),
        )
    options = {k: v for k, v in (d.get("options") or {}).items() if k in OPTIONS_PERMISES}
    return jsonify({"taches": taches.gestionnaire.ajouter(elements, options)})


@api.post("/telechargements/<id_>/<action>")
def agir(id_, action):
    g = taches.gestionnaire
    actions = {"pause": g.pause, "reprendre": g.reprendre, "annuler": g.annuler, "relancer": g.relancer}
    if action not in actions:
        abort(404)
    try:
        actions[action](id_)
    except KeyError:
        return _erreur("Téléchargement introuvable.", 404)
    return jsonify({"ok": True})


@api.delete("/telechargements/<id_>")
def supprimer(id_):
    try:
        taches.gestionnaire.supprimer(id_, fichier=request.args.get("fichier") == "1")
    except KeyError:
        return _erreur("Téléchargement introuvable.", 404)
    return jsonify({"ok": True})


@api.post("/telechargements/tout/<action>")
def agir_tout(action):
    if action not in ("pause_tout", "reprendre_tout", "relancer_erreurs", "vider_termines", "vider_echecs"):
        abort(404)
    taches.gestionnaire.action_globale(action)
    return jsonify({"ok": True})


@api.get("/evenements")
def evenements():
    depuis = int(request.args.get("rev", 0))

    def flux():
        rev = depuis
        yield "retry: 2000\n\n"
        while True:
            nouveau, modif, suppr = taches.gestionnaire.changements(rev)
            if nouveau == rev:
                yield ": ping\n\n"
                continue
            rev = nouveau
            yield f"data: {json.dumps({'rev': rev, 'taches': modif, 'supprimees': suppr}, ensure_ascii=False)}\n\n"

    return Response(stream_with_context(flux()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _extraire_pistes_audio(chemin: Path) -> list:
    if not shutil.which("ffprobe"):
        return []
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-select_streams", "a", str(chemin)],
            capture_output=True, text=True, timeout=8,
        )
        data = json.loads(r.stdout or "{}")
    except Exception:
        return []

    pistes = []
    streams = data.get("streams") or []
    bruit = ("soundhandler", "videohandler", "isomedia", "iso media", "gpac", "core media", "apple", "ffmpeg")
    for idx, s in enumerate(streams):
        stags = {k.lower(): v for k, v in (s.get("tags") or {}).items() if isinstance(v, str)}
        hn = (stags.get("title") or stags.get("handler_name") or "").strip()
        if any(b in hn.lower() for b in bruit):
            hn = ""
        lang = (stags.get("language") or "").lower()
        code = miniatures._ISO3.get(lang, lang if lang and lang != "und" else "")
        drap = langues.drapeau(code) if code else ""
        nom_l = langues.nom(code) if code else ""

        if hn:
            if "(VO)" in hn and code:
                libelle = f"{drap} {hn}".strip()
            elif drap and not hn.startswith(drap):
                libelle = f"{drap} {hn}".strip()
            else:
                libelle = hn
        elif code:
            libelle = f"{drap} {nom_l}".strip()
        else:
            libelle = f"Piste audio {idx + 1}"

        codec = (s.get("codec_name") or "").upper()
        pistes.append({
            "idx": idx,
            "titre": libelle.strip(),
            "lang": code or lang,
            "codec": codec,
            "par_defaut": (s.get("disposition") or {}).get("default") == 1,
        })
    return pistes


def _remuxer_piste_audio(fichier: Path, piste_idx: int) -> Path:
    if piste_idx <= 0 or not shutil.which("ffmpeg"):
        return fichier
    try:
        st = fichier.stat()
    except OSError:
        return fichier

    cle = hashlib.sha1(f"{fichier.resolve()}:{int(st.st_mtime)}:{st.st_size}:{piste_idx}".encode()).hexdigest()[:16]
    ext = fichier.suffix.lower() if fichier.suffix.lower() in {".mp4", ".mkv", ".webm"} else ".mp4"
    cible = config.CACHE_PISTES / f"remux_{cle}{ext}"
    if cible.is_file() and cible.stat().st_size > 0:
        return cible

    tmp = cible.with_suffix(f".{os.getpid()}.tmp")
    cmd = [
        "ffmpeg", "-y", "-v", "error", "-i", str(fichier),
        "-map", "0:v:0?", "-map", f"0:a:{piste_idx}",
        "-c", "copy",
    ]
    if ext in {".mp4", ".m4v", ".mov"}:
        cmd.extend(["-movflags", "+faststart"])
    cmd.append(str(tmp))

    try:
        r = subprocess.run(cmd, capture_output=True, timeout=45)
        if r.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
            tmp.replace(cible)
            return cible
    except Exception:
        pass
    finally:
        tmp.unlink(missing_ok=True)
    return fichier


def _fichier_de(id_):
    t = taches.gestionnaire.taches.get(id_)
    if not t or not t.fichier or not Path(t.fichier).exists():
        abort(404)
    return Path(t.fichier)


@api.get("/fichier/<id_>")
def fichier(id_):
    """Lecture (avec Range) ou enregistrement dans le navigateur."""
    f = _fichier_de(id_)
    piste_str = request.args.get("piste_audio")
    if piste_str is not None:
        try:
            f = _remuxer_piste_audio(f, int(piste_str))
        except (ValueError, TypeError):
            pass
    return send_file(f, as_attachment=request.args.get("enregistrer") == "1", download_name=f.name,
                     conditional=True)


@api.post("/ouvrir/<id_>")
def ouvrir(id_):
    if config.SUR_SERVEUR:
        return _erreur("Disponible uniquement en local.")
    f = _fichier_de(id_)
    cible = f.parent if _corps().get("dossier") else f
    if _corps().get("dossier") and shutil.which("dbus-send"):
        # Ouvre le dossier en sélectionnant le fichier (Nautilus, Dolphin, Nemo…)
        r = subprocess.run(["dbus-send", "--session", "--dest=org.freedesktop.FileManager1",
                            "--type=method_call", "/org/freedesktop/FileManager1",
                            "org.freedesktop.FileManager1.ShowItems",
                            f"array:string:file://{f}", "string:"], capture_output=True)
        if r.returncode == 0:
            return jsonify({"ok": True})
    subprocess.Popen(["xdg-open", str(cible)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return jsonify({"ok": True})


@api.post("/ouvrir-dossier")
def ouvrir_dossier():
    if config.SUR_SERVEUR:
        return _erreur("Disponible uniquement en local.")
    subprocess.Popen(["xdg-open", str(config.dossier_telechargement())], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return jsonify({"ok": True})


# ── aperçus rapides (lot) ───────────────────────────────────────────
@api.post("/apercus")
def apercus():
    """Titre + miniature de plusieurs liens via oEmbed (rapide, sans analyse complète)."""
    import urllib.parse
    import urllib.request
    from concurrent.futures import ThreadPoolExecutor

    urls = [u for u in (_corps().get("urls") or [])[:200] if isinstance(u, str)]

    def un(url):
        try:
            q = urllib.parse.urlencode({"url": url, "format": "json"})
            with urllib.request.urlopen(f"https://www.youtube.com/oembed?{q}", timeout=8) as r:
                d = json.load(r)
            return {"url": url, "titre": d.get("title"), "chaine": d.get("author_name"),
                    "miniature": d.get("thumbnail_url"), "ok": True}
        except Exception:
            return {"url": url, "ok": False}

    with ThreadPoolExecutor(8) as ex:
        return jsonify({"apercus": list(ex.map(un, urls))})


# ── fichiers du dossier de téléchargement ───────────────────────────
EXT_VIDEO = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"}
EXT_AUDIO = {".mp3", ".m4a", ".opus", ".flac", ".wav", ".ogg", ".aac"}


def _chemin_sur(rel):
    racine = config.dossier_telechargement().resolve()
    f = (racine / (rel or "")).resolve()
    if f != racine and racine not in f.parents:
        abort(403)
    return racine, f


@api.get("/fichiers")
def fichiers():
    from urllib.parse import quote
    racine = config.dossier_telechargement().resolve()
    par_chemin = {}
    for t in taches.gestionnaire.liste():
        if t.get("fichier"):
            par_chemin[str(Path(t["fichier"]).resolve())] = t
    res = []
    for f in racine.rglob("*"):
        ext = f.suffix.lower()
        if not f.is_file() or (ext not in EXT_VIDEO and ext not in EXT_AUDIO) or ".part" in f.name:
            continue
        st = f.stat()
        t = par_chemin.get(str(f))
        rel = f.relative_to(racine)
        meta = miniatures.infos_fichier(f)
        avoir_vignette = bool(
            (t and t.get("miniature"))
            or meta.get("pochette")
            or meta.get("yt_id")
            or ext in EXT_VIDEO
        )
        res.append({
            "chemin": str(rel), "nom": f.stem, "ext": ext[1:], "taille": st.st_size, "date": st.st_mtime,
            "type": "video" if ext in EXT_VIDEO else "audio",
            "dossier": str(rel.parent) if str(rel.parent) != "." else "",
            "tache": t["id"] if t else None,
            "miniature": f"/api/miniature?chemin={quote(str(rel))}&m={int(st.st_mtime)}" if avoir_vignette else None,
            "pistes": (t.get("pistes") if t else None) or meta.get("pistes"),
            "duree": (t.get("duree") if t else None) or meta.get("duree"),
            "titre": (t.get("titre") if t else None) or meta.get("titre") or f.stem,
            "publiable": meta.get("publiable"),
            "vcodec": meta.get("vcodec"),
        })
    res.sort(key=lambda x: x["date"], reverse=True)
    return jsonify({"fichiers": res, "dossier": str(racine)})


@api.get("/miniature")
def miniature():
    """Sert une miniature depuis le disque (ou l'extrait du média / la met en cache)."""
    chemin = request.args.get("chemin")
    url = request.args.get("url")
    img = None
    if chemin:
        _, f = _chemin_sur(chemin)
        if not f.is_file():
            abort(404)
        url_tache = next(
            (t.get("miniature") for t in taches.gestionnaire.liste()
             if t.get("fichier") and Path(t["fichier"]).resolve() == f),
            None,
        )
        img = miniatures.vignette_fichier(f, url_tache)
    elif url:
        img = miniatures.locale(url) or miniatures.telecharger(url)
        if not img:
            for t in taches.gestionnaire.liste():
                if t.get("miniature") == url and t.get("fichier") and Path(t["fichier"]).is_file():
                    img = miniatures.vignette_fichier(Path(t["fichier"]), url)
                    if img:
                        break
    if not img or not img.is_file():
        abort(404)
    debut = img.read_bytes()[:16]
    return send_file(img, mimetype=miniatures.mimetype(debut), max_age=86400 * 30, conditional=True)


@api.get("/fichiers/lire")
def lire_fichier():
    _, f = _chemin_sur(request.args.get("chemin"))
    if not f.is_file():
        abort(404)
    piste_str = request.args.get("piste_audio")
    if piste_str is not None:
        try:
            f = _remuxer_piste_audio(f, int(piste_str))
        except (ValueError, TypeError):
            pass
    return send_file(f, as_attachment=request.args.get("enregistrer") == "1", download_name=f.name, conditional=True)


@api.get("/fichiers/pistes-audio")
def pistes_audio():
    chemin = request.args.get("chemin")
    id_ = request.args.get("id")
    cible = None
    if chemin:
        try:
            _, cible = _chemin_sur(chemin)
        except (ValueError, OSError):
            return jsonify({"pistes": []})
    elif id_:
        try:
            cible = _fichier_de(id_)
        except (ValueError, OSError, KeyError):
            return jsonify({"pistes": []})
    if not cible or not cible.is_file():
        return jsonify({"pistes": []})
    return jsonify({"pistes": _extraire_pistes_audio(cible)})


@api.get("/fichiers/sous-titres")
def liste_sous_titres():
    chemin = request.args.get("chemin")
    id_ = request.args.get("id")
    cible = None
    racine = config.dossier_telechargement().resolve()
    if chemin:
        try:
            _, cible = _chemin_sur(chemin)
        except (ValueError, OSError):
            return jsonify({"sous_titres": []})
    elif id_:
        try:
            cible = _fichier_de(id_)
        except (ValueError, OSError, KeyError):
            return jsonify({"sous_titres": []})
    if not cible or not cible.is_file():
        return jsonify({"sous_titres": []})

    base_nom = cible.stem
    subs = []
    for f in cible.parent.glob(f"{base_nom}*"):
        ext = f.suffix.lower()
        if ext in {".vtt", ".srt"} and f.is_file():
            suffixe = f.stem[len(base_nom):].strip("._- ")
            lang = suffixe or "Défaut"
            rel = f.relative_to(racine) if racine in f.parents or f == racine else f.name
            subs.append({
                "lang": lang,
                "nom": f.name,
                "chemin": str(rel),
                "format": ext[1:],
            })
    return jsonify({"sous_titres": subs})


@api.get("/fichiers/sous-titres/vtt")
def servir_sous_titre_vtt():
    import re
    _, f = _chemin_sur(request.args.get("chemin"))
    if not f.is_file():
        abort(404)
    contenu = f.read_text(encoding="utf-8", errors="replace")
    if f.suffix.lower() == ".srt":
        vtt = "WEBVTT\n\n" + re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", contenu)
    else:
        vtt = contenu
    return Response(vtt, mimetype="text/vtt; charset=utf-8")


@api.delete("/fichiers")
def supprimer_fichier():
    racine, f = _chemin_sur(request.args.get("chemin"))
    if not f.is_file() or f == racine:
        return _erreur("Fichier introuvable.", 404)
    f.unlink()
    return jsonify({"ok": True})


@api.post("/fichiers/convertir-tiktok")
def convertir_fichier_tiktok():
    """Convertit en 1 clic une vidéo locale vers MP4 H.264 + AAC propre (ou 9:16) pour TikTok/Shorts."""
    if not shutil.which("ffmpeg"):
        return _erreur("ffmpeg n'est pas installé.")
    d = _corps()
    racine, f = _chemin_sur(d.get("chemin"))
    if not f.is_file() or f == racine or f.suffix.lower() not in EXT_VIDEO:
        return _erreur("Vidéo introuvable.", 404)
    vertical = d.get("vertical") or ""
    remplacer = bool(d.get("remplacer", True))
    meta = miniatures.infos_fichier(f)
    vcodec = meta.get("vcodec") or ""
    acodec = meta.get("acodec") or ""

    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(f), "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
    if vertical == "flou":
        cmd += shlex.split(formats.BASE_VIDEO_PUBLIABLE) + ["-filter_complex", formats.FILTRE_VERTICAL_FLOU]
    elif vertical == "recadre":
        cmd += shlex.split(formats.BASE_VIDEO_PUBLIABLE) + ["-vf", formats.FILTRE_VERTICAL_RECADRE]
    elif vcodec in ("h264", "avc1", "avc"):
        cmd += ["-c:v", "copy"]
    else:
        cmd += shlex.split(formats.BASE_VIDEO_PUBLIABLE) + ["-vf", formats.FILTRE_ECHELLE_PUBLIABLE]

    if acodec in ("aac", "mp4a") and not vertical:
        cmd += ["-c:a", "copy"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]

    cmd += ["-map_metadata", "-1", "-map_chapters", "-1", "-movflags", "+faststart"]
    suffixe = " (9-16)" if vertical else ""
    cible = f.with_name(f"{f.stem}{suffixe}.mp4") if (remplacer and not vertical) else f.with_name(f"{f.stem}{suffixe or ' (TikTok)'}.mp4")
    tmp = f.with_name(f".{f.stem}.tiktok.{os.getpid()}.mp4")
    cmd.append(str(tmp))

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        if r.returncode != 0 or not tmp.is_file() or tmp.stat().st_size == 0:
            err = (r.stderr or "").strip().splitlines()
            return _erreur(err[-1][:200] if err else "Échec de la conversion ffmpeg.", 500)
        tmp.replace(cible)
        if remplacer and not vertical and cible != f and f.exists():
            f.unlink(missing_ok=True)
            for t in taches.gestionnaire.taches.values():
                if t.fichier and Path(t.fichier).resolve() == f:
                    taches.gestionnaire.maj(t, True, fichier=str(cible), taille_fichier=cible.stat().st_size)
        return jsonify({"ok": True, "chemin": str(cible.relative_to(racine))})
    except subprocess.TimeoutExpired:
        return _erreur("Conversion trop longue (délai dépassé).", 504)
    finally:
        tmp.unlink(missing_ok=True)


@api.post("/fichiers/ouvrir")
def ouvrir_fichier():
    if config.SUR_SERVEUR:
        return _erreur("Disponible uniquement en local.")
    _, f = _chemin_sur(_corps().get("chemin"))
    if not f.exists():
        return _erreur("Fichier introuvable.", 404)
    if _corps().get("dossier") and shutil.which("dbus-send"):
        r = subprocess.run(["dbus-send", "--session", "--dest=org.freedesktop.FileManager1",
                            "--type=method_call", "/org/freedesktop/FileManager1",
                            "org.freedesktop.FileManager1.ShowItems", f"array:string:file://{f}", "string:"],
                           capture_output=True)
        if r.returncode == 0:
            return jsonify({"ok": True})
    cible = f.parent if _corps().get("dossier") else f
    subprocess.Popen(["xdg-open", str(cible)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return jsonify({"ok": True})


# ── diagnostics ─────────────────────────────────────────────────────
def _version_outil(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return (r.stdout or r.stderr).strip().splitlines()[0][:80]
    except (OSError, subprocess.SubprocessError, IndexError):
        return None


@api.get("/diagnostics")
def diagnostics():
    import platform
    return jsonify({
        "python": platform.python_version(), "systeme": f"{platform.system()} {platform.release()}",
        "ffmpeg": _version_outil(["ffmpeg", "-version"]),
        "deno": _version_outil(["deno", "--version"]) or _version_outil(["node", "--version"]),
        "flask": _version("flask"),
        "erreurs": [{"titre": t["titre"], "erreur": t["erreur"], "fin": t.get("fin") or t.get("cree"), "url": t["url"]}
                    for t in sorted(taches.gestionnaire.liste(), key=lambda t: t.get("cree") or 0, reverse=True)
                    if t["statut"] == "erreur"][:8],
    })


@api.post("/test-youtube")
def test_youtube():
    import time as _t
    debut = _t.time()
    try:
        info = analyse.info_complete("https://www.youtube.com/watch?v=jNQXAC9IVRw", frais=True)
    except analyse.ErreurAnalyse as e:
        return jsonify({"ok": False, "message": str(e), "duree": round(_t.time() - debut, 1)})
    return jsonify({"ok": True, "duree": round(_t.time() - debut, 1), "formats": len(info.get("formats") or []),
                    "titre": info.get("title")})


def creer_app():
    app = Flask(__name__, static_folder=str(STATIQUE), static_url_path="/static")
    app.json.ensure_ascii = False
    app.register_blueprint(api)
    taches.demarrer()
    if not app.config.get("TESTING") and not gouts.gestionnaire.fil:
        threading.Thread(target=gouts.gestionnaire.rafraichir, kwargs={"force": False}, daemon=True).start()

    @app.get("/")
    def accueil():
        return send_file(STATIQUE / "index.html")

    @app.get("/favicon.ico")
    def favicon():
        return send_file(STATIQUE / "icone.svg", mimetype="image/svg+xml")

    @app.after_request
    def securite(rep):
        rep.headers.setdefault("X-Content-Type-Options", "nosniff")
        rep.headers.setdefault("Referrer-Policy", "no-referrer-when-downgrade")
        return rep

    @app.before_request
    def meme_origine():
        # Le serveur tourne en local : on refuse les requêtes d'autres sites
        # (sinon n'importe quelle page web pourrait lancer des téléchargements).
        if request.method in ("POST", "DELETE", "PUT"):
            origine = request.headers.get("Origin")
            if origine and origine.split("://", 1)[-1] != request.host:
                abort(403)

    return app
