"""Choix des pistes audio et sélection des formats (sans réseau)."""
from nexus import formats


def _audio(fid, lang, note, taille=1000):
    return {"format_id": fid, "language": lang, "format_note": note, "acodec": "mp4a", "vcodec": "none",
            "ext": "m4a", "filesize": taille}


INFO_DOUBLEE = {"language": "en-US", "formats": [
    {"format_id": "137", "vcodec": "avc1", "acodec": "none", "height": 1080, "width": 1920, "filesize": 5000},
    _audio("140-0", "en-US", "English (US) original (default), medium"),
    _audio("140-1", "fr", "French, medium"),
    _audio("233-2", "es", "Español - dubbed-auto"),
]}
INFO_SIMPLE = {"language": "en", "formats": [
    {"format_id": "22", "vcodec": "avc1", "acodec": "none", "height": 720, "width": 1280, "filesize": 3000},
    _audio("140", "en", "medium"),
]}


def test_pistes_et_genres():
    p = {x["code"]: x["genre"] for x in formats.pistes_audio(INFO_DOUBLEE)}
    assert p == {"en-US": "originale", "fr": "doublage", "es": "doublage IA"}
    assert formats.pistes_audio(INFO_DOUBLEE)[0]["originale"]


def test_plan_francais_avec_vo():
    assert formats.plan_audio(INFO_DOUBLEE, "fr", True) == ("fr", "en-US", True)
    assert formats.plan_audio(INFO_DOUBLEE, "fr-FR", False) == ("fr", "en-US", False)


def test_plan_sans_doublage_et_vo_demandee():
    assert formats.plan_audio(INFO_SIMPLE, "fr", True) == (None, "en", False)
    assert formats.plan_audio(INFO_DOUBLEE, "original", True) == (None, "en-US", False)
    assert formats.plan_audio(INFO_DOUBLEE, "en", True) == (None, "en-US", False)


def test_selecteur():
    s = formats.selecteur({"type": "video", "qualite": "1080"}, "fr", "en-US", True)
    assert s.startswith("bv*[height<=1080]+ba[language=fr]+ba[language=en-US]/")
    assert formats.selecteur({"type": "audio"}, "fr", "en-US", False) == "ba[language=fr]/ba/b"
    assert formats.selecteur({"type": "video"}, None, None, False).startswith("bv*+ba/")


def test_qualites_tailles():
    q, ta = formats.qualites(INFO_DOUBLEE, "fr")
    assert q[0]["hauteur"] == 1080 and q[0]["taille"] == 6000 and ta == 1000
