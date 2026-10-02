"""Messages d'erreur yt-dlp lisibles, et détection des erreurs passagères."""
import re

CONNUES = [
    (("sign in to confirm you", "not a bot"), "YouTube demande de prouver que tu n'es pas un robot. "
     "Active les cookies de ton navigateur dans Réglages → Compte YouTube.", False),
    (("sign in to confirm your age", "age-restricted", "inappropriate for some users"),
     "Vidéo réservée aux adultes : active les cookies de ton navigateur (Réglages).", False),
    (("private video", "this video is private"), "Vidéo privée : accès refusé.", False),
    (("members-only", "join this channel"), "Vidéo réservée aux membres de la chaîne (cookies nécessaires).", False),
    (("not available in your country", "geo restrict", "blocked it in your country"),
     "Vidéo bloquée dans ton pays.", False),
    (("video unavailable", "video is unavailable", "is no longer available", "has been removed",
      "account associated with this video has been terminated", "incomplete youtube id"),
     "Vidéo indisponible ou supprimée.", False),
    (("premieres in", "this live event will begin"), "La vidéo n'est pas encore sortie (première à venir).", False),
    (("unsupported url",), "Ce lien n'est pas pris en charge.", False),
    (("requested format is not available",), "Format demandé indisponible : choisis une autre qualité.", False),
    (("no space left",), "Disque plein : libère de la place ou change de dossier.", False),
    (("permission denied",), "Impossible d'écrire dans le dossier de téléchargement.", False),
    (("http error 429", "too many requests"), "YouTube limite les requêtes (429). Nouvelle tentative…", True),
    (("http error 403",), "Accès refusé par YouTube (403). Nouvelle tentative…", True),
    (("timed out", "timeout", "connection reset", "connection refused", "temporary failure",
      "network is unreachable", "name resolution", "remote end closed", "incompleteread",
      "http error 5", "unable to download video data", "got error", "fragment"),
     "Problème réseau. Nouvelle tentative…", True),
]


def analyser(texte, code=None):
    """(message lisible, passagère?)"""
    bas = (texte or "").lower()
    for cles, message, passagere in CONNUES:
        if any(c in bas for c in cles):
            return message, passagere
    lignes = [l.strip() for l in (texte or "").splitlines() if "ERROR" in l]
    if lignes:
        msg = re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*)?([\w-]+:\s*)?", "", lignes[-1]).strip()
        return msg[:240], False
    derniere = [l for l in (texte or "").splitlines() if l.strip()]
    return (derniere[-1][:240] if derniere else f"Erreur inconnue (code {code})"), False
