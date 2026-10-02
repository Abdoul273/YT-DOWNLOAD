"""Noms français et drapeaux des langues proposées par YouTube."""

NOMS = {
    "fr": "Français", "en": "Anglais", "es": "Espagnol", "de": "Allemand", "it": "Italien",
    "pt": "Portugais", "nl": "Néerlandais", "pl": "Polonais", "ru": "Russe", "uk": "Ukrainien",
    "ar": "Arabe", "tr": "Turc", "fa": "Persan", "he": "Hébreu", "hi": "Hindi", "bn": "Bengali",
    "pa": "Pendjabi", "mr": "Marathi", "ta": "Tamoul", "te": "Télougou", "ml": "Malayalam",
    "ur": "Ourdou", "id": "Indonésien", "ms": "Malais", "vi": "Vietnamien", "th": "Thaï",
    "ja": "Japonais", "ko": "Coréen", "zh": "Chinois", "zh-hans": "Chinois simplifié",
    "zh-hant": "Chinois traditionnel", "sv": "Suédois", "no": "Norvégien", "da": "Danois",
    "fi": "Finnois", "cs": "Tchèque", "sk": "Slovaque", "ro": "Roumain", "hu": "Hongrois",
    "el": "Grec", "bg": "Bulgare", "sr": "Serbe", "hr": "Croate", "sw": "Swahili",
    "wo": "Wolof", "ff": "Peul", "ha": "Haoussa", "yo": "Yoruba", "am": "Amharique",
    "fil": "Filipino", "ca": "Catalan",
}

DRAPEAUX = {
    "fr": "🇫🇷", "en": "🇬🇧", "en-us": "🇺🇸", "es": "🇪🇸", "es-419": "🇲🇽", "de": "🇩🇪", "it": "🇮🇹",
    "pt": "🇵🇹", "pt-br": "🇧🇷", "nl": "🇳🇱", "pl": "🇵🇱", "ru": "🇷🇺", "uk": "🇺🇦", "ar": "🇸🇦",
    "tr": "🇹🇷", "fa": "🇮🇷", "he": "🇮🇱", "hi": "🇮🇳", "bn": "🇧🇩", "pa": "🇮🇳", "mr": "🇮🇳",
    "ta": "🇮🇳", "te": "🇮🇳", "ml": "🇮🇳", "ur": "🇵🇰", "id": "🇮🇩", "ms": "🇲🇾", "vi": "🇻🇳",
    "th": "🇹🇭", "ja": "🇯🇵", "ko": "🇰🇷", "zh": "🇨🇳", "zh-hans": "🇨🇳", "zh-hant": "🇹🇼",
    "sv": "🇸🇪", "no": "🇳🇴", "da": "🇩🇰", "fi": "🇫🇮", "cs": "🇨🇿", "sk": "🇸🇰", "ro": "🇷🇴",
    "hu": "🇭🇺", "el": "🇬🇷", "bg": "🇧🇬", "sr": "🇷🇸", "hr": "🇭🇷", "sw": "🇰🇪", "wo": "🇸🇳",
    "ff": "🇬🇳", "ha": "🇳🇬", "yo": "🇳🇬", "am": "🇪🇹", "fil": "🇵🇭", "ca": "🇪🇸",
}


def base(code):
    return (code or "").lower().replace("_", "-").split("-")[0]


def meme_langue(a, b):
    return bool(a and b) and base(a) == base(b)


def nom(code):
    c = (code or "").lower()
    if c in NOMS:
        return NOMS[c]
    n = NOMS.get(base(c))
    if n and "-" in c:
        return f"{n} ({c.split('-', 1)[1].upper()})"
    return n or code or "Inconnue"


def drapeau(code):
    c = (code or "").lower()
    return DRAPEAUX.get(c) or DRAPEAUX.get(base(c)) or "🌐"
