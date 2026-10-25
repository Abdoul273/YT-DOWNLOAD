"""Goûts de l'utilisateur et fil « Pour vous » (recommandations personnalisées).

Inspiré et synchronisé avec le moteur de l'application mobile :
Chaque geste laisse un signal pondéré (recherche, aperçu, analyse, téléchargement,
lecture, « pas intéressé ») qui s'efface avec le temps (demi-vie de 21 jours).
On en déduit un profil (chaînes, mots-clés, thématiques aimées), puis on va chercher
des candidats multi-sources — mix YouTube des vidéos favorites, nouveautés des chaînes,
recherches sur les centres d'intérêt, tendances — classés et diversifiés.
"""
import json
import math
import random
import re
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from . import analyse, config

_POIDS = {
    "clic": 1.0,            # résultat de recherche ouvert
    "apercu": 2.0,          # vidéo regardée en aperçu / streaming
    "analyse": 1.5,         # lien collé / analysé
    "telechargement": 4.0,  # vidéo téléchargée
    "lecture": 3.0,         # vidéo regardée dans le lecteur
    "pas_interesse": -6.0,  # signal négatif explicite
}
_DEMI_VIE_JOURS = 21.0
_DUREE_FIL = 3600           # 1 heure de validité pour le fil en cache

_VIDES = {
    # Français
    "les", "des", "une", "pour", "avec", "dans", "sur", "par", "est", "pas", "que", "qui", "son", "ses", "aux",
    "mon", "mes", "ton", "tes", "nous", "vous", "ils", "elle", "elles", "mais", "tout", "tous", "plus", "moins",
    "comment", "pourquoi", "quand", "quoi", "cette", "ces", "cet", "sans", "sont", "fait", "faire", "être", "avoir",
    "très", "bien", "trop", "leur", "leurs", "notre", "votre", "entre", "depuis", "vers", "chez", "officiel",
    "officielle", "vidéo", "video", "partie", "episode", "épisode", "full", "version", "français", "francais", "vf",
    "vostfr", "complet", "complète", "nouveau", "nouvelle",
    # Anglais
    "the", "and", "for", "with", "you", "your", "this", "that", "from", "are", "was", "what", "how", "why", "who",
    "official", "music", "lyrics", "lyric", "audio", "feat", "ft", "part", "new", "live", "hd", "4k", "1080p",
    "shorts", "short", "vs",
}


def id_video(url):
    if not url:
        return None
    try:
        p = urllib.parse.urlparse(url)
        if "youtu.be" in p.netloc:
            parts = [seg for seg in p.path.split("/") if seg]
            return parts[0] if parts else None
        qs = urllib.parse.parse_qs(p.query)
        if "v" in qs:
            return qs["v"][0]
        parts = [seg for seg in p.path.split("/") if seg]
        if "shorts" in parts:
            idx = parts.index("shorts")
            if idx + 1 < len(parts):
                return parts[idx + 1]
    except Exception:
        pass
    return None


def mots_cles(texte):
    if not texte:
        return []
    nettoye = re.sub(r"[^\w\s]+", " ", texte.lower(), flags=re.UNICODE)
    res = []
    vus = set()
    for m in nettoye.split():
        if len(m) >= 3 and m not in _VIDES and not m.isdigit() and m not in vus:
            vus.add(m)
            res.append(m)
    return res


class Profil:
    def __init__(self):
        self.chaines = {}       # chaine_lower -> score
        self.ids_chaines = {}   # chaine_lower -> channel_id
        self.noms_chaines = {}  # chaine_lower -> nom affiché
        self.mots = {}          # mot -> score
        self.requetes = {}      # requete_lower -> score
        self.graines = []       # list de (signal_dict, poids)

    @property
    def vide(self):
        return not self.chaines and not self.mots and not self.requetes

    def affinite_chaine(self, chaine):
        if not chaine:
            return 0.0
        return self.chaines.get(chaine.lower(), 0.0)

    def affinite_titre(self, titre):
        if not self.mots or not titre:
            return 0.0
        max_val = max(self.mots.values()) if self.mots else 0.0
        if max_val <= 0:
            return 0.0
        s = sum((self.mots.get(m, 0.0) / max_val) for m in mots_cles(titre))
        return min(2.5, max(0.0, s)) / 2.5

    def interets(self, n=6):
        res = []
        requetes_triees = sorted(
            [e for e in self.requetes.items() if e[1] > 0],
            key=lambda x: x[1], reverse=True
        )
        for req, _ in requetes_triees:
            if len(res) >= n // 2:
                break
            res.append(req)

        mots_tries = sorted(
            [e for e in self.mots.items() if e[1] > 0],
            key=lambda x: x[1], reverse=True
        )
        for m, _ in mots_tries:
            if len(res) >= n:
                break
            if not any(m in r for r in res):
                res.append(m)
        return res


class GestionnaireGouts:
    def __init__(self, fichier: Path | None = None):
        self._verrou = threading.Lock()
        self._verrou_rafraichir = threading.Lock()
        self._fichier = Path(fichier) if fichier else (config.DONNEES / "gouts.json")
        self._signaux = []
        self.recherches = []           # list de {'q': str, 't': int}
        self._videos_bloquees = set()
        self._chaines_bloquees = set()
        self._impressions = {}         # id -> count
        self.fil = []
        self.tendances = []
        self._maj_fil = 0
        self._maj_tendances = 0
        self.chargement = False
        self.erreur = None
        self._timer_sauvegarde = None
        self._profil_cache = None
        self._profil_t = 0
        self._suggestions_cache = {}
        self.charger()

    @staticmethod
    def _maintenant():
        return int(time.time())

    def charger(self):
        with self._verrou:
            if not self._fichier.is_file():
                return
            try:
                d = json.loads(self._fichier.read_text(encoding="utf-8"))
                self._signaux = d.get("signaux") or []
                self.recherches = d.get("recherches") or []
                self._videos_bloquees = set(d.get("videos_bloquees") or [])
                self._chaines_bloquees = set(d.get("chaines_bloquees") or [])
                self._impressions = d.get("impressions") or {}
                self.fil = d.get("fil") or []
                self.tendances = d.get("tendances") or []
                self._maj_fil = d.get("maj_fil") or 0
                self._maj_tendances = d.get("maj_tendances") or 0
            except Exception:
                pass

    def _sauver(self):
        self._profil_cache = None
        if self._timer_sauvegarde:
            self._timer_sauvegarde.cancel()

        def _ecrire():
            with self._verrou:
                donnees = {
                    "signaux": self._signaux,
                    "recherches": self.recherches,
                    "videos_bloquees": list(self._videos_bloquees),
                    "chaines_bloquees": list(self._chaines_bloquees),
                    "impressions": self._impressions,
                    "fil": self.fil,
                    "tendances": self.tendances,
                    "maj_fil": self._maj_fil,
                    "maj_tendances": self._maj_tendances,
                }
            tmp = self._fichier.with_suffix(".tmp")
            try:
                tmp.write_text(json.dumps(donnees, ensure_ascii=False), encoding="utf-8")
                tmp.replace(self._fichier)
            except OSError:
                tmp.unlink(missing_ok=True)

        self._timer_sauvegarde = threading.Timer(2.0, _ecrire)
        self._timer_sauvegarde.daemon = True
        self._timer_sauvegarde.start()

    # ── signaux ─────────────────────────────────────────────────────────
    def signal(self, type_, url=None, id_=None, titre=None, chaine=None, chaine_id=None):
        id_ = id_ or id_video(url)
        if not id_ and not chaine:
            return
        m = self._maintenant()
        with self._verrou:
            # Même geste répété sur la même vidéo dans l'heure : ignoré
            if any(s.get("type") == type_ and s.get("id") == id_ and m - s.get("t", 0) < 3600 for s in self._signaux):
                return
            self._signaux.append({
                "type": type_, "id": id_, "titre": titre, "chaine": chaine,
                "cid": chaine_id, "t": m
            })
            if len(self._signaux) > 600:
                self._signaux = self._signaux[-600:]
        self._sauver()

    def ajouter_recherche(self, q):
        q = (q or "").strip()
        if not q:
            return
        m = self._maintenant()
        with self._verrou:
            self.recherches = [r for r in self.recherches if r.get("q", "").lower() != q.lower()]
            self.recherches.insert(0, {"q": q, "t": m})
            if len(self.recherches) > 60:
                self.recherches = self.recherches[:60]
        self._sauver()

    def oublier_recherche(self, q):
        with self._verrou:
            self.recherches = [r for r in self.recherches if r.get("q") != q]
        self._sauver()

    def pas_interesse(self, id_=None, titre=None, chaine=None):
        if id_:
            with self._verrou:
                self._videos_bloquees.add(id_)
                self.fil = [x for x in self.fil if x.get("id") != id_]
                self.tendances = [x for x in self.tendances if x.get("id") != id_]
        self.signal("pas_interesse", id_=id_, titre=titre, chaine=chaine)
        self._sauver()

    def bloquer_chaine(self, chaine):
        if not chaine:
            return
        c = chaine.lower()
        with self._verrou:
            self._chaines_bloquees.add(c)
            self.fil = [x for x in self.fil if (x.get("chaine") or "").lower() != c]
            self.tendances = [x for x in self.tendances if (x.get("chaine") or "").lower() != c]
        self._sauver()

    def est_bloquee(self, id_=None, chaine=None):
        with self._verrou:
            if id_ and id_ in self._videos_bloquees:
                return True
            if chaine and chaine.lower() in self._chaines_bloquees:
                return True
            return False

    def effacer(self):
        with self._verrou:
            self._signaux.clear()
            self.recherches.clear()
            self._videos_bloquees.clear()
            self._chaines_bloquees.clear()
            self._impressions.clear()
            self.fil = []
            self._maj_fil = 0
        self._sauver()

    # ── calcul du profil ───────────────────────────────────────────────
    def profil(self):
        m = self._maintenant()
        if self._profil_cache and m - self._profil_t < 600:
            return self._profil_cache
        p = self._calculer_profil()
        self._profil_cache = p
        self._profil_t = m
        return p

    def _calculer_profil(self):
        p = Profil()
        maintenant = self._maintenant()

        def usure(t):
            return 0.5 ** ((maintenant - t) / 86400 / _DEMI_VIE_JOURS)

        par_video = {}
        with self._verrou:
            signaux = list(self._signaux)
            recherches = list(self.recherches)
            bloquees = set(self._videos_bloquees)
            chaines_bloquees = set(self._chaines_bloquees)

        for s in signaux:
            w = (_POIDS.get(s.get("type"), 1.0)) * usure(s.get("t", maintenant))
            c = (s.get("chaine") or "").lower()
            if c:
                # "pas intéressé" pèse surtout sur la vidéo, un peu sur la chaîne
                p.chaines[c] = p.chaines.get(c, 0.0) + (w / 3.0 if w < 0 else w)
                p.noms_chaines[c] = s.get("chaine")
                if s.get("cid"):
                    p.ids_chaines[c] = s.get("cid")
            if s.get("titre"):
                for m in mots_cles(s["titre"]):
                    p.mots[m] = p.mots.get(m, 0.0) + w / 2.0
            if s.get("id") and w > 0:
                id_ = s["id"]
                prec_s, prec_w = par_video.get(id_, (s, 0.0))
                par_video[id_] = (s, prec_w + w)

        for r in recherches:
            q = r.get("q", "")
            t = r.get("t", maintenant)
            w = 2.0 * usure(t)
            ql = q.lower()
            p.requetes[ql] = p.requetes.get(ql, 0.0) + w
            for m in mots_cles(q):
                p.mots[m] = p.mots.get(m, 0.0) + w

        for c in chaines_bloquees:
            p.chaines[c] = -100.0

        p.graines = sorted(
            [item for item in par_video.values() if item[0].get("id") not in bloquees],
            key=lambda x: x[1], reverse=True
        )
        return p

    # ── fil « Pour vous » ───────────────────────────────────────────────
    def fil_perime(self):
        return (self._maintenant() - self._maj_fil) > _DUREE_FIL

    def rafraichir(self, force=False):
        if not force and not self.fil_perime() and self.fil:
            return self.etat()
        with self._verrou_rafraichir:
            if not force and not self.fil_perime() and self.fil:
                return self.etat()
            self.chargement = True
            self.erreur = None
            try:
                p = self.profil()
                rnd = random.Random()
                candidats = []
                requetes_paralleles = []

                # 1. Mix YouTube des vidéos aimées (tirage pondéré)
                graines_retenues = self._tirage(p.graines, 3, rnd)
                for g_sig, _ in graines_retenues:
                    gid = g_sig.get("id")
                    if gid:
                        mix_url = f"https://www.youtube.com/watch?v={gid}&list=RD{gid}"
                        requetes_paralleles.append(("mix", mix_url, None, 20))

                # 2. Nouveautés des chaînes préférées
                chaines_top = sorted(
                    [e for e in p.chaines.items() if e[1] > 1.5],
                    key=lambda x: x[1], reverse=True
                )[:3]
                for c_key, _ in chaines_top:
                    nom_c = p.noms_chaines.get(c_key, c_key)
                    cid = p.ids_chaines.get(c_key)
                    url = f"https://www.youtube.com/channel/{cid}/videos" if cid else f"ytsearch10:{nom_c}"
                    requetes_paralleles.append(("chaine", url, None, 10))

                # 3. Centres d'intérêt (recherches et mots forts)
                interets = p.interets(6)
                rnd.shuffle(interets)
                for q in interets[:3]:
                    requetes_paralleles.append(("interet", q, {"date": "mois"}, 12))

                # 4. Tendances + exécution parallèle de toutes les requêtes
                besoin_tendances = force or not self.tendances or (self._maintenant() - self._maj_tendances > 3 * 3600)

                def _exec_req(item):
                    src, q_ou_url, flt, nb = item
                    try:
                        return src, analyse.rechercher(q_ou_url, filtres=flt, nombre=nb)
                    except Exception:
                        return src, []

                with ThreadPoolExecutor(max_workers=6) as pool:
                    fut_tendances = pool.submit(self._chercher_tendances) if besoin_tendances else None
                    futs = [pool.submit(_exec_req, item) for item in requetes_paralleles]
                    for fut in as_completed(futs):
                        src, vids = fut.result()
                        for r_idx, v in enumerate(vids):
                            candidats.append((v, src, r_idx))
                    if fut_tendances is not None:
                        tendances_vids = fut_tendances.result()
                        if tendances_vids:
                            with self._verrou:
                                self.tendances = tendances_vids
                                self._maj_tendances = self._maintenant()
                    else:
                        tendances_vids = self.tendances

                for r_idx, v in enumerate(tendances_vids):
                    candidats.append((v, "tendance", r_idx))

                classe = self._classer(candidats, p, rnd)
                with self._verrou:
                    if classe:
                        self.fil = classe
                        self._maj_fil = self._maintenant()
                        for e in self.fil[:15]:
                            eid = e.get("id")
                            if eid:
                                self._impressions[eid] = self._impressions.get(eid, 0) + 1
                        if len(self._impressions) > 1500:
                            cles_a_suppr = list(self._impressions.keys())[:len(self._impressions) - 1500]
                            for k in cles_a_suppr:
                                self._impressions.pop(k, None)
                self._sauver()
            except Exception as e:
                self.erreur = str(e)
            finally:
                self.chargement = False
        return self.etat()

    def _tirage(self, graines, n, rnd):
        pool = list(graines[:25])
        res = []
        while len(res) < n and pool:
            total = sum(g[1] for g in pool)
            if total <= 0:
                break
            x = rnd.random() * total
            i = 0
            while i < len(pool) - 1 and (x - pool[i][1]) > 0:
                x -= pool[i][1]
                i += 1
            res.append(pool.pop(i))
        return res

    def _classer(self, candidats, p, rnd):
        poids_source = {"mix": 3.0, "chaine": 2.6, "interet": 2.2, "tendance": 1.2}
        deja_vus = {s.get("id") for s in self._signaux if s.get("id")}
        bloquees = set(self._videos_bloquees)
        chaines_bloquees = set(self._chaines_bloquees)
        maintenant = self._maintenant()
        scores = {}
        froid = p.vide

        for v, src, rang in candidats:
            vid = v.get("id")
            if not vid or vid in bloquees or (v.get("chaine") or "").lower() in chaines_bloquees:
                continue
            if vid in deja_vus:
                continue

            s = (poids_source.get(src, 1.0)) * (2.0 if froid and src == "tendance" else 1.0) / (1.0 + rang * 0.06)
            s += 1.4 * min(1.0, max(-3.0, p.affinite_chaine(v.get("chaine")) / 10.0))
            s += 1.2 * p.affinite_titre(v.get("titre") or "")

            date_val = v.get("date")
            if date_val:
                jours = (maintenant - date_val) / 86400
                s += 0.6 if jours < 3 else 0.35 if jours < 14 else 0.1 if jours < 60 else 0.0

            vues_val = v.get("vues")
            if vues_val and vues_val > 0:
                s += 0.25 * math.log10(vues_val + 1) / 8.0

            duree_val = v.get("duree")
            if duree_val and duree_val < 60:
                s -= 0.3  # Shorts légèrement moins prioritaires

            s -= 0.45 * (self._impressions.get(vid, 0))
            s += rnd.random() * 0.7  # exploration

            prec = scores.get(vid)
            if prec is None:
                scores[vid] = (v, s)
            else:
                scores[vid] = (prec[0], max(prec[1], s) + 0.5)

        restants = list(scores.values())
        par_chaine = {}
        res = []
        while restants and len(res) < 60:
            meilleur_idx = 0
            meilleur_score = -float("inf")
            for i, (v, s) in enumerate(restants):
                ch_key = (v.get("chaine") or "").lower()
                n = par_chaine.get(ch_key, 0)
                ajuste = s - n * 0.9
                if ajuste > meilleur_score:
                    meilleur_score = ajuste
                    meilleur_idx = i

            choisi, _ = restants.pop(meilleur_idx)
            ch_key = (choisi.get("chaine") or "").lower()
            par_chaine[ch_key] = par_chaine.get(ch_key, 0) + 1
            res.append(choisi)
        return res

    def _chercher_tendances(self):
        sujets = [
            "clip officiel", "actualité", "football", "humour", "jeux vidéo",
            "bande annonce", "science espace", "documentaire", "technologie",
        ]
        random.shuffle(sujets)
        filtre = {"date": "semaine", "tri": "vues"}

        def _rech_sujet(s):
            try:
                return analyse.rechercher(s, filtres=filtre, nombre=12)
            except Exception:
                return []

        with ThreadPoolExecutor(max_workers=3) as pool:
            listes = [lst for lst in pool.map(_rech_sujet, sujets[:3]) if lst]
        res = []
        for i in range(12):
            for lst in listes:
                if i < len(lst):
                    res.append(lst[i])
        # Déduplication
        vus = set()
        uniques = []
        for v in res:
            vid = v.get("id")
            if vid and vid not in vus:
                vus.add(vid)
                uniques.append(v)
        return uniques

    def etat(self):
        p = self.profil()
        with self._verrou:
            return {
                "fil": list(self.fil),
                "tendances": list(self.tendances),
                "interets": p.interets(8),
                "recherches": [r.get("q") for r in self.recherches[:10] if r.get("q")],
                "maj_fil": self._maj_fil,
                "chargement": self.chargement,
                "erreur": self.erreur,
            }

    # ── suggestions de saisie YouTube ───────────────────────────────────
    def suggestions(self, q):
        q = (q or "").strip()
        if not q:
            return []
        cle = q.lower()
        if cle in self._suggestions_cache:
            return self._suggestions_cache[cle]

        url = f"https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=fr&gl=FR&q={urllib.parse.quote(q)}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=3.5) as r:
                data = json.loads(r.read().decode("utf-8"))
            suggs = [str(x) for x in (data[1] if len(data) > 1 and isinstance(data[1], list) else [])]
            self._suggestions_cache[cle] = suggs
            if len(self._suggestions_cache) > 400:
                self._suggestions_cache.pop(next(iter(self._suggestions_cache)))
            return suggs
        except Exception:
            return []


gestionnaire = GestionnaireGouts()
