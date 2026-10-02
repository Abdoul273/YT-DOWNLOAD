"""File de téléchargements : parallélisme, pause/reprise, relances, persistance.

Chaque téléchargement :
  1. récupère les infos (cache de l'analyse si récent) via l'API yt-dlp ;
  2. choisit les pistes (formats.plan_audio) et calcule la taille totale ;
  3. lance yt-dlp en sous-processus avec --load-info-json (aucune requête
     d'analyse en double), progression en JSON, groupe de processus à part
     pour pouvoir mettre en pause/annuler proprement (ffmpeg compris).
"""
import json
import os
import re
import shlex
import signal
import shutil
import subprocess
import threading
import time
import uuid
from pathlib import Path

import yt_dlp

from . import analyse, config, erreurs, formats, langues

EN_COURS = {"analyse", "telechargement", "traitement", "attente_relance"}
ACTIFS = EN_COURS | {"en_attente", "programme"}
FINIS = {"termine", "erreur", "annule"}

PHASES_PP = {
    "Merger": "Fusion des pistes", "FFmpegMerger": "Fusion des pistes",
    "FFmpegExtractAudio": "Conversion audio", "ExtractAudio": "Conversion audio",
    "EmbedSubtitle": "Intégration des sous-titres", "FFmpegEmbedSubtitle": "Intégration des sous-titres",
    "EmbedThumbnail": "Ajout de la miniature", "FFmpegMetadata": "Métadonnées",
    "Metadata": "Métadonnées", "SponsorBlock": "Suppression des sponsors",
    "ModifyChapters": "Découpage des segments", "FFmpegSplitChapters": "Découpage en chapitres",
    "SplitChapters": "Découpage en chapitres", "MoveFiles": "Finalisation",
    "FFmpegVideoRemuxer": "Conversion du conteneur", "FFmpegSubtitlesConvertor": "Conversion des sous-titres",
    "FFmpegThumbnailsConvertor": "Conversion de la miniature", "ThumbnailsConvertor": "Conversion de la miniature",
}

CHAMPS_SAUVES = (
    "id", "url", "titre", "miniature", "chaine", "duree", "groupe", "options", "statut",
    "progression", "telecharge", "total", "message", "erreur", "fichier", "taille_fichier",
    "pistes", "cree", "fin", "programme", "tentatives", "phase",
)


def _maintenant():
    return time.time()


class Tache:
    def __init__(self, url, options, titre=None, miniature=None, chaine=None, duree=None, groupe=None):
        self.id = uuid.uuid4().hex[:12]
        self.url = url
        self.options = options
        self.titre = titre or url
        self.miniature = miniature
        self.chaine = chaine
        self.duree = duree
        self.groupe = groupe
        self.statut = "programme" if options.get("programme") else "en_attente"
        self.programme = options.get("programme")
        self.progression = 0.0
        self.vitesse = 0
        self.eta = None
        self.telecharge = 0
        self.total = 0
        self.phase = ""
        self.message = ""
        self.erreur = ""
        self.fichier = None
        self.taille_fichier = 0
        self.pistes = ""
        self.cree = _maintenant()
        self.fin = None
        self.tentatives = 0
        self.rev = 0
        # interne
        self.proc = None
        self.arret = None           # "pause" | "annule" | None
        self.reveil = threading.Event()
        self.parties = []           # [(format_id, taille, libellé)]
        self.base_sortie = None     # chemin sans extension, pour le ménage

    def vue(self):
        d = {k: getattr(self, k) for k in CHAMPS_SAUVES}
        d.update(vitesse=self.vitesse, eta=self.eta, rev=self.rev)
        return d

    @classmethod
    def depuis(cls, d):
        t = cls(d["url"], d.get("options") or {})
        for k in CHAMPS_SAUVES:
            if k in d:
                setattr(t, k, d[k])
        return t


class Gestionnaire:
    def __init__(self):
        self.taches = {}
        self.supprimees = {}        # id → rev de suppression (pour le flux d'événements)
        self.rev = 0
        self.verrou = threading.RLock()
        self.cond = threading.Condition(self.verrou)
        self._derniere_sauvegarde = 0
        self._charger()
        threading.Thread(target=self._repartiteur, daemon=True, name="repartiteur").start()

    # ── état et événements ────────────────────────────────────────────
    def _touche(self, t, sauver=False):
        with self.cond:
            self.rev += 1
            t.rev = self.rev
            self.cond.notify_all()
        if sauver or _maintenant() - self._derniere_sauvegarde > 5:
            self._sauver()

    def maj(self, t, sauver=False, **champs):
        for k, v in champs.items():
            setattr(t, k, v)
        self._touche(t, sauver)

    def liste(self):
        with self.verrou:
            return [t.vue() for t in self.taches.values()]

    def changements(self, depuis, delai=15):
        """Attend un changement après la révision `depuis` (flux SSE)."""
        with self.cond:
            if self.rev <= depuis:
                self.cond.wait(delai)
            modif = [t.vue() for t in self.taches.values() if t.rev > depuis]
            suppr = [i for i, r in self.supprimees.items() if r > depuis]
            return self.rev, modif, suppr

    def _sauver(self):
        with self.verrou:
            self._derniere_sauvegarde = _maintenant()
            donnees = [{k: getattr(t, k) for k in CHAMPS_SAUVES} for t in self.taches.values()]
        tmp = config.FICHIER_TACHES.with_suffix(".tmp")
        try:
            tmp.write_text(json.dumps(donnees, ensure_ascii=False))
            tmp.replace(config.FICHIER_TACHES)
        except OSError:
            pass

    def _charger(self):
        try:
            donnees = json.loads(config.FICHIER_TACHES.read_text())
        except (OSError, ValueError):
            return
        for d in donnees:
            t = Tache.depuis(d)
            if t.statut in EN_COURS:
                # Interrompu par un arrêt de l'app : on reprend automatiquement.
                t.statut, t.phase = "en_attente", ""
                t.message = "Reprise après redémarrage"
            if t.statut == "termine" and t.fichier and not Path(t.fichier).exists():
                t.message = "Fichier déplacé ou supprimé"
            self.taches[t.id] = t

    # ── actions ───────────────────────────────────────────────────────
    def ajouter(self, elements, options):
        nouvelles = []
        with self.verrou:
            for e in elements:
                if not e.get("url"):
                    continue
                t = Tache(e["url"], dict(options), e.get("titre"), e.get("miniature"),
                          e.get("chaine"), e.get("duree"), e.get("groupe"))
                self.taches[t.id] = t
                nouvelles.append(t)
                self._touche(t)
        self._sauver()
        return [t.vue() for t in nouvelles]

    def _get(self, id_):
        t = self.taches.get(id_)
        if not t:
            raise KeyError(id_)
        return t

    def pause(self, id_):
        t = self._get(id_)
        if t.statut in EN_COURS:
            t.arret = "pause"
            t.reveil.set()
            self._tuer(t)
        elif t.statut in ("en_attente", "programme"):
            self.maj(t, True, statut="pause", phase="")

    def reprendre(self, id_):
        t = self._get(id_)
        if t.statut in ("pause", "erreur", "annule"):
            if t.statut != "pause":
                t.tentatives = 0
                t.progression = 0
            self.maj(t, True, statut="en_attente", erreur="", message="", phase="")

    def relancer(self, id_):
        t = self._get(id_)
        if t.statut in EN_COURS:
            return
        if t.statut == "termine" and t.fichier and Path(t.fichier).exists():
            return
        t.tentatives = 0
        self.maj(t, True, statut="en_attente", erreur="", message="", phase="", progression=0,
                 fichier=None, telecharge=0)

    def annuler(self, id_):
        t = self._get(id_)
        if t.statut in EN_COURS:
            t.arret = "annule"
            t.reveil.set()
            self._tuer(t)
        elif t.statut in ("en_attente", "programme", "pause"):
            self._menage(t)
            self.maj(t, True, statut="annule", phase="", vitesse=0, eta=None)

    def supprimer(self, id_, fichier=False):
        t = self._get(id_)
        if t.statut in EN_COURS:
            t.arret = "annule"
            t.reveil.set()
            self._tuer(t)
        elif t.statut != "termine":
            self._menage(t)
        if fichier and t.fichier:
            try:
                Path(t.fichier).unlink()
            except OSError:
                pass
        with self.cond:
            self.taches.pop(id_, None)
            self.rev += 1
            self.supprimees[id_] = self.rev
            self.cond.notify_all()
        self._sauver()

    def action_globale(self, action):
        with self.verrou:
            taches = list(self.taches.values())
        for t in taches:
            try:
                if action == "pause_tout" and t.statut in ACTIFS:
                    self.pause(t.id)
                elif action == "reprendre_tout" and t.statut == "pause":
                    self.reprendre(t.id)
                elif action == "relancer_erreurs" and t.statut == "erreur":
                    self.relancer(t.id)
                elif action == "vider_termines" and t.statut == "termine":
                    self.supprimer(t.id)
                elif action == "vider_echecs" and t.statut in ("erreur", "annule"):
                    self.supprimer(t.id)
            except KeyError:
                pass

    def _tuer(self, t):
        p = t.proc
        if p and p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass

    def _menage(self, t):
        """Supprime les fichiers partiels d'un téléchargement abandonné."""
        if not t.base_sortie:
            return
        base = Path(t.base_sortie)
        if not base.parent.exists():
            return
        prefixe = base.name
        for f in base.parent.iterdir():
            n = f.name
            if not n.startswith(prefixe):
                continue
            reste = n[len(prefixe):]
            if re.match(r"^\.(f[\w-]+\.\w+|temp\.\w+|part|ytdl)", reste) or n.endswith((".part", ".ytdl")) \
                    or "-Frag" in n or reste.endswith((".vtt", ".srt", ".webp", ".jpg", ".png")):
                try:
                    f.unlink()
                except OSError:
                    pass

    # ── exécution ─────────────────────────────────────────────────────
    def _repartiteur(self):
        while True:
            time.sleep(0.4)
            try:
                max_ = config.lire_reglages()["simultanes"]
                with self.verrou:
                    actives = sum(1 for t in self.taches.values() if t.statut in EN_COURS)
                    maintenant = _maintenant()
                    for t in self.taches.values():
                        if t.statut == "programme" and (t.programme or 0) <= maintenant:
                            self.maj(t, statut="en_attente")
                    for t in self.taches.values():
                        if actives >= max_:
                            break
                        if t.statut == "en_attente":
                            t.statut, t.arret = "analyse", None
                            t.reveil.clear()
                            self._touche(t)
                            actives += 1
                            threading.Thread(target=self._executer, args=(t,), daemon=True).start()
            except Exception:  # le répartiteur ne doit jamais mourir
                time.sleep(2)

    def _executer(self, t):
        try:
            self._executer_avec_relances(t)
        except Exception as e:  # filet de sécurité
            self.maj(t, True, statut="erreur", erreur=f"Erreur interne : {e}", vitesse=0, eta=None)

    def _executer_avec_relances(self, t):
        reglages = config.lire_reglages()
        while True:
            ok, message, passagere = False, "", False
            if not t.arret:
                t.tentatives += 1
                ok, message, passagere = self._une_tentative(t, reglages)
            if t.arret == "pause":
                return self.maj(t, True, statut="pause", phase="", vitesse=0, eta=None)
            if t.arret == "annule":
                self._menage(t)
                return self.maj(t, True, statut="annule", phase="", vitesse=0, eta=None)
            if ok:
                return self._terminer(t, reglages)
            if passagere and t.tentatives <= reglages["relances"]:
                attente = min(60, 5 * 2 ** (t.tentatives - 1))
                self.maj(t, statut="attente_relance", vitesse=0, eta=None,
                         phase=f"Nouvelle tentative dans {attente} s ({t.tentatives}/{reglages['relances']})",
                         message=message)
                analyse.oublier(t.url)   # liens peut-être expirés (403)
                t.reveil.wait(attente)
                continue
            return self.maj(t, True, statut="erreur", erreur=message, phase="", vitesse=0, eta=None)

    def _terminer(self, t, reglages):
        taille = 0
        if t.fichier and Path(t.fichier).exists():
            taille = Path(t.fichier).stat().st_size
        self.maj(t, True, statut="termine", progression=100, phase="", vitesse=0, eta=None,
                 taille_fichier=taille, fin=_maintenant(), erreur="")
        try:
            (config.CACHE_INFOS / f"{t.id}.json").unlink()
        except OSError:
            pass
        if reglages["notifications"] and shutil.which("notify-send") and not config.SUR_SERVEUR:
            subprocess.Popen(["notify-send", "-a", "YT-NEXUS", "-i", "folder-download",
                              "Téléchargement terminé", t.titre],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _une_tentative(self, t, reglages):
        """(réussi, message d'erreur, erreur passagère ?)"""
        o = t.options
        self.maj(t, statut="analyse", phase="Analyse de la vidéo", erreur="")
        try:
            info = analyse.info_complete(t.url)
        except analyse.ErreurAnalyse as e:
            return False, str(e), e.passagere
        if t.arret:
            return False, "", False
        if info.get("live_status") == "is_live":
            return False, "Les directs en cours ne sont pas pris en charge : attends la fin du live.", False

        # Pistes audio
        langue = o.get("langue_audio") or reglages["langue_audio"]
        garder_vo = o.get("garder_vo", reglages["garder_vo"]) and o.get("type") != "audio"
        piste, originale, deux = formats.plan_audio(info, langue, garder_vo)
        sel = formats.selecteur(o, piste, originale, deux)
        tri = formats.tri(o)

        # Résolution exacte des formats (tailles, ordre des parties)
        dossier = config.dossier_telechargement(reglages)
        if t.groupe and reglages["sous_dossier_playlist"]:
            dossier = dossier / re.sub(r'[\\/:*?"<>|]+', "_", t.groupe).strip()[:120]
        dossier.mkdir(parents=True, exist_ok=True)
        modele = reglages["modele_nom"]
        try:
            with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "format": sel, "format_sort": tri,
                                   "allow_multiple_audio_streams": True,
                                   "paths": {"home": str(dossier)}, "outtmpl": modele,
                                   "merge_output_format": o.get("conteneur") or "mp4"}) as ydl:
                choisi = ydl.process_ie_result(json.loads(json.dumps(info)), download=False)
                t.base_sortie = str(Path(ydl.prepare_filename(choisi)).with_suffix(""))
        except yt_dlp.utils.DownloadError as e:
            message, passagere = erreurs.analyser(str(e))
            return False, message, passagere
        parties = choisi.get("requested_formats") or [choisi]
        t.parties = []
        for f in parties:
            if formats._est_video(f):
                lib = f"Vidéo {f.get('height') or ''}p".replace(" p", "")
            else:
                code = f.get("language")
                lib = f"Audio {langues.drapeau(code)} {langues.nom(code)}" if code else "Audio"
            t.parties.append((f.get("format_id"), f.get("filesize") or f.get("filesize_approx") or 0, lib))

        # Description des pistes et messages
        msg = ""
        if piste:
            desc = f"{langues.drapeau(piste)} {langues.nom(piste)}"
            if deux:
                desc += f" + {langues.drapeau(originale)} VO"
        else:
            desc = f"{langues.drapeau(originale)} {langues.nom(originale)}" if originale else "Piste unique"
            if langue != "original" and not langues.meme_langue(originale, langue):
                msg = f"Pas de doublage {langues.nom(langue).lower()} sur YouTube pour cette vidéo"
        secours = (not piste and langue != "original" and not langues.meme_langue(originale, langue)
                   and o.get("type") != "audio" and reglages["sous_titres_secours"])
        if secours:
            msg += " → sous-titres intégrés"
        total = sum(p[1] for p in t.parties)
        self.maj(t, titre=info.get("title") or t.titre, miniature=t.miniature or analyse._miniature(info),
                 chaine=info.get("channel") or info.get("uploader") or t.chaine,
                 duree=info.get("duration") or t.duree, pistes=desc, total=total,
                 message=msg if t.tentatives == 1 or msg else t.message)

        chemin_info = config.CACHE_INFOS / f"{t.id}.json"
        chemin_info.write_text(json.dumps(info))
        cmd = self._commande(t, reglages, sel, tri, dossier, modele, chemin_info,
                             piste or originale, originale if deux else None, secours, langue)
        return self._lancer(t, cmd)

    def _commande(self, t, r, sel, tri, dossier, modele, chemin_info, piste, vo, secours, langue):
        o = t.options
        audio = o.get("type") == "audio"
        cmd = config.commande_ytdlp() + [
            "--load-info-json", str(chemin_info), "--ignore-config", "--no-simulate",
            "-f", sel, "-S", ",".join(tri),
            "-P", str(dossier), "-o", modele,
            "--quiet", "--progress", "--newline", "--no-warnings", "--no-mtime", "--no-playlist",
            "--progress-template", "download:NEXUS %(progress)j\t%(info.format_id)s",
            "--progress-template", "postprocess:NEXUSPP %(progress.postprocessor)s\t%(progress.status)s",
            "--print", "after_move:NEXUSFICHIER %(filepath)s",
            "-N", str(r["fragments"]), "--http-chunk-size", "10M",
            "--retries", "10", "--fragment-retries", "10",
            "--retry-sleep", "http:exp=1:30", "--retry-sleep", "fragment:exp=1:30",
            "--socket-timeout", "30",
        ] + config.args_auth(r)
        if r["limite_vitesse"]:
            cmd += ["-r", r["limite_vitesse"]]
        if r["metadonnees"]:
            cmd += ["--embed-metadata", "--embed-chapters"]
        if r["miniature"] and o.get("conteneur") != "webm":
            cmd += ["--embed-thumbnail"]

        if audio:
            fa = o.get("format_audio") or r["format_audio"]
            cmd += ["-x"]
            if fa != "original":
                cmd += ["--audio-format", fa, "--audio-quality", str(o.get("qualite_audio") or r["qualite_audio"])]
        else:
            conteneur = o.get("conteneur") or r["conteneur"]
            cmd += ["--audio-multistreams", "--merge-output-format", conteneur]
            if piste and conteneur != "webm":
                # Pistes nommées ; seule la 1re (langue voulue) est « par défaut ».
                def nommer(i, nom):  # title (mkv) + handler_name (mp4)
                    n = shlex.quote(nom)
                    return f" -metadata:s:a:{i} title={n} -metadata:s:a:{i} handler_name={n}"
                pp = nommer(0, langues.nom(piste)).strip()
                if vo:
                    pp += nommer(1, langues.nom(vo) + " (VO)")
                    pp += " -disposition:a 0 -disposition:a:0 default"
                cmd += ["--postprocessor-args", f"Merger:{pp}"]
            sous_titres = list(o.get("sous_titres") or [])
            if secours:
                b = langues.base(langue)
                sous_titres += [b, f"{b}-.*"]
            if sous_titres:
                cmd += ["--write-subs", "--sub-langs", ",".join(dict.fromkeys(sous_titres)),
                        "--sleep-subtitles", "1"]
                if secours or o.get("sous_titres_auto"):
                    cmd += ["--write-auto-subs"]
                if o.get("sous_titres_fichier"):
                    cmd += ["--convert-subs", "srt"]
                else:
                    cmd += ["--embed-subs"]
            if o.get("chapitres_separes"):
                cmd += ["--split-chapters", "-o", "chapter:%(title)s/%(section_number)02d - %(section_title)s.%(ext)s"]

        if o.get("sponsorblock", r["sponsorblock"]):
            cmd += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
        debut, fin = (o.get("debut") or "").strip(), (o.get("fin") or "").strip()
        if debut or fin:
            cmd += ["--download-sections", f"*{debut or '0'}-{fin or 'inf'}", "--force-keyframes-at-cuts"]
        return cmd

    def _lancer(self, t, cmd):
        erreurs_lignes = []
        t.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  bufsize=1, start_new_session=True, errors="replace")

        def lire_err():
            for ligne in t.proc.stderr:
                if ligne.startswith("NEXUSPP "):
                    self._ligne_pp(t, ligne)
                elif ligne.strip():
                    erreurs_lignes.append(ligne.rstrip())
                    del erreurs_lignes[:-60]

        lecteur = threading.Thread(target=lire_err, daemon=True)
        lecteur.start()
        self.maj(t, statut="telechargement", phase="Connexion…")
        derniere_maj = 0
        for ligne in t.proc.stdout:
            if ligne.startswith("NEXUS "):
                if self._ligne_progression(t, ligne) and _maintenant() - derniere_maj > 0.25:
                    derniere_maj = _maintenant()
                    self._touche(t)
            elif ligne.startswith("NEXUSPP "):
                self._ligne_pp(t, ligne)
            elif ligne.startswith("NEXUSFICHIER "):
                t.fichier = ligne[len("NEXUSFICHIER "):].strip()
        code = t.proc.wait()
        lecteur.join(timeout=3)
        t.proc = None
        if t.arret:
            return False, "", False
        if code == 0 and t.fichier and Path(t.fichier).exists():
            return True, "", False
        texte = "\n".join(erreurs_lignes)
        if code == 0 and not t.fichier:
            texte = texte or "Aucun fichier produit."
        message, passagere = erreurs.analyser(texte, code)
        return False, message, passagere

    def _ligne_progression(self, t, ligne):
        try:
            brut, _, format_id = ligne[len("NEXUS "):].rstrip("\n").rpartition("\t")
            p = json.loads(brut)
        except ValueError:
            return False
        idx = next((i for i, part in enumerate(t.parties) if part[0] == format_id.strip()), 0)
        n = max(1, len(t.parties))
        total_part = p.get("total_bytes") or p.get("total_bytes_estimate") or 0
        fait = p.get("downloaded_bytes") or 0
        if p.get("status") == "finished":
            fait = total_part = total_part or fait
        tailles = [part[1] for part in t.parties]
        if idx < len(tailles) and total_part:
            tailles[idx] = total_part
        if t.parties and all(tailles):
            total = sum(tailles)
            avant = sum(tailles[:idx])
            prog = (avant + fait) / total * 100
            t.total, t.telecharge = total, avant + fait
        else:
            frac = fait / total_part if total_part else 0
            prog = (idx + frac) / n * 100
            t.telecharge = fait
        t.progression = round(max(t.progression if t.statut == "telechargement" else 0, min(prog, 99.5)), 1)
        t.vitesse = p.get("speed") or 0
        eta = p.get("eta")
        if t.vitesse and t.total:
            eta = max(0, (t.total - t.telecharge) / t.vitesse)
        t.eta = int(eta) if eta is not None else None
        lib = t.parties[idx][2] if idx < len(t.parties) else "Téléchargement"
        t.phase = f"{lib} ({idx + 1}/{n})" if n > 1 else lib
        t.statut = "telechargement"
        return True

    def _ligne_pp(self, t, ligne):
        nom, _, etat = ligne[len("NEXUSPP "):].strip().partition("\t")
        if etat == "started" and nom not in ("MoveFiles",):
            self.maj(t, statut="traitement", phase=PHASES_PP.get(nom, nom) + "…", vitesse=0, eta=None,
                     progression=max(t.progression, 99.5))


gestionnaire = None


def demarrer():
    global gestionnaire
    if gestionnaire is None:
        gestionnaire = Gestionnaire()
    return gestionnaire
