import tempfile
from pathlib import Path

from nexus.gouts import GestionnaireGouts, mots_cles
from nexus.web import creer_app


def test_mots_cles_extraction():
    titre = "Les 10 secrets du WebRTC et de Python en 2026 !"
    mots = mots_cles(titre)
    assert "secrets" in mots
    assert "webrtc" in mots
    assert "python" in mots
    # Stopwords vérifiés
    assert "les" not in mots
    assert "du" not in mots
    assert "et" not in mots
    assert "de" not in mots
    assert "en" not in mots


def test_gestionnaire_gouts_cycle():
    with tempfile.TemporaryDirectory() as tmp:
        fpath = Path(tmp) / "gouts.json"
        gs = GestionnaireGouts(fpath)

        # 1. Signaux
        gs.signal("telechargement", id_="vid1", url="https://youtu.be/vid1", titre="Cours Python Avancé", chaine="DevAcademy")
        gs.signal("apercu", id_="vid2", url="https://youtu.be/vid2", titre="Python & FastApi", chaine="DevAcademy")
        gs.ajouter_recherche("tutoriel python")

        prof = gs.profil()
        assert "devacademy" in prof.chaines
        assert prof.affinite_chaine("DevAcademy") > 0
        assert prof.affinite_titre("Nouveau tutoriel Python") > 0

        interets = prof.interets()
        assert any("python" in x for x in interets)

        # 2. Pas intéressé et blocage
        gs.pas_interesse(id_="vid99", titre="Spam Vidéo", chaine="SpamChannel")
        assert gs.est_bloquee(id_="vid99")
        gs.bloquer_chaine("AutreSpam")
        assert gs.est_bloquee(chaine="AutreSpam")

        # 3. État
        etat = gs.etat()
        assert "fil" in etat
        assert "tendances" in etat
        assert "interets" in etat
        assert "recherches" in etat


def test_api_routes_gouts():
    app = creer_app()
    app.config["TESTING"] = True
    client = app.test_client()

    # Route /api/gouts/fil
    res = client.get("/api/gouts/fil")
    assert res.status_code == 200
    data = res.get_json()
    assert "fil" in data
    assert "interets" in data
    assert "recherches" in data

    # Route /api/gouts/signal
    res = client.post("/api/gouts/signal", json={
        "id": "abc12345678",
        "url": "https://youtu.be/abc12345678",
        "titre": "Super Vidéo Test",
        "chaine": "ChaineTest",
        "type": "apercu",
    })
    assert res.status_code == 200
    assert res.get_json().get("ok") is True

    # Route /api/recherche/suggestions
    res = client.get("/api/recherche/suggestions?q=pyth")
    assert res.status_code == 200
    sugg_data = res.get_json()
    assert "suggestions" in sugg_data
    assert isinstance(sugg_data["suggestions"], list)


def test_securite_referrer_policy():
    app = creer_app()
    app.config["TESTING"] = True
    client = app.test_client()
    rep = client.get("/")
    assert rep.status_code == 200
    assert rep.headers.get("Referrer-Policy") == "no-referrer-when-downgrade"
    assert rep.headers.get("X-Content-Type-Options") == "nosniff"
