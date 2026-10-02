"""API HTTP + flux d'événements (SSE) + interface."""
import json
import os
import shutil
import subprocess
import sys
import threading
from importlib import metadata
from pathlib import Path

from flask import Blueprint, Flask, Response, abort, jsonify, request, send_file, stream_with_context

from . import VERSION, analyse, config, taches

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
        return jsonify(analyse.analyser(url))
    except analyse.ErreurAnalyse as e:
        return _erreur(str(e), 422)


@api.post("/recherche")
def rechercher():
    q = (_corps().get("q") or "").strip()
    if not q:
        return _erreur("Recherche vide.")
    try:
        return jsonify({"resultats": analyse.rechercher(q)})
    except analyse.ErreurAnalyse as e:
        return _erreur(str(e), 422)


# ── téléchargements ─────────────────────────────────────────────────
OPTIONS_PERMISES = {
    "type", "qualite", "conteneur", "format_audio", "qualite_audio", "langue_audio", "garder_vo",
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


def _fichier_de(id_):
    t = taches.gestionnaire.taches.get(id_)
    if not t or not t.fichier or not Path(t.fichier).exists():
        abort(404)
    return Path(t.fichier)


@api.get("/fichier/<id_>")
def fichier(id_):
    """Lecture (avec Range) ou enregistrement dans le navigateur."""
    f = _fichier_de(id_)
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


def creer_app():
    app = Flask(__name__, static_folder=str(STATIQUE), static_url_path="/static")
    app.json.ensure_ascii = False
    app.register_blueprint(api)
    taches.demarrer()

    @app.get("/")
    def accueil():
        return send_file(STATIQUE / "index.html")

    @app.get("/favicon.ico")
    def favicon():
        return send_file(STATIQUE / "icone.svg", mimetype="image/svg+xml")

    @app.after_request
    def securite(rep):
        rep.headers.setdefault("X-Content-Type-Options", "nosniff")
        rep.headers.setdefault("Referrer-Policy", "no-referrer")
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
