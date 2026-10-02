#!/usr/bin/env python3
"""YT-NEXUS — téléchargeur YouTube avec pistes audio traduites.

Lancement local :  python app.py   (ou ./yt-nexus)
Variables : HOST (défaut 127.0.0.1), PORT (défaut 5050).
"""
import os

from nexus.web import creer_app

app = creer_app()

if __name__ == "__main__":
    hote = os.getenv("HOST", "127.0.0.1")
    port = int(os.getenv("PORT", "5050"))
    print(f"YT-NEXUS → http://{'localhost' if hote == '127.0.0.1' else hote}:{port}")
    app.run(host=hote, port=port, threaded=True, debug=False, use_reloader=False)
