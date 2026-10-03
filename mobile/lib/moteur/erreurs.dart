/// Messages d'erreur yt-dlp lisibles, et détection des erreurs passagères.
library;

const _connues = <(List<String>, String, bool)>[
  (['sign in to confirm you', 'not a bot'],
      "YouTube demande de prouver que tu n'es pas un robot. Ajoute tes cookies YouTube dans Réglages.", false),
  (['sign in to confirm your age', 'age-restricted', 'inappropriate for some users'],
      'Vidéo réservée aux adultes : ajoute tes cookies YouTube (Réglages).', false),
  (['private video', 'this video is private'], 'Vidéo privée : accès refusé.', false),
  (['members-only', 'join this channel'], 'Vidéo réservée aux membres de la chaîne (cookies nécessaires).', false),
  (['not available in your country', 'geo restrict', 'blocked it in your country'], 'Vidéo bloquée dans ton pays.', false),
  ([
    'video unavailable', 'video is unavailable', 'is no longer available', 'has been removed',
    'account associated with this video has been terminated', 'incomplete youtube id'
  ], 'Vidéo indisponible ou supprimée.', false),
  (['premieres in', 'this live event will begin'], "La vidéo n'est pas encore sortie (première à venir).", false),
  (['unsupported url'], "Ce lien n'est pas pris en charge.", false),
  (['requested format is not available'], 'Format demandé indisponible : choisis une autre qualité.', false),
  (['no space left'], 'Stockage plein : libère de la place sur le téléphone.', false),
  (['permission denied'], "Impossible d'écrire le fichier.", false),
  (['http error 429', 'too many requests'], 'YouTube limite les requêtes (429). Nouvelle tentative…', true),
  (['http error 403'], 'Accès refusé par YouTube (403). Nouvelle tentative…', true),
  ([
    'timed out', 'timeout', 'connection reset', 'connection refused', 'temporary failure',
    'network is unreachable', 'name resolution', 'remote end closed', 'incompleteread',
    'http error 5', 'unable to download video data', 'got error', 'fragment', 'failed to resolve'
  ], 'Problème réseau. Nouvelle tentative…', true),
];

/// (message lisible, passagère ?)
(String, bool) analyser(String? texte, [int? code]) {
  final t = texte ?? '';
  final bas = t.toLowerCase();
  for (final (cles, message, passagere) in _connues) {
    if (cles.any(bas.contains)) return (message, passagere);
  }
  final lignes = t.split('\n').map((l) => l.trim()).where((l) => l.contains('ERROR')).toList();
  String coupe(String s) => s.length > 240 ? s.substring(0, 240) : s;
  if (lignes.isNotEmpty) {
    return (coupe(lignes.last.replaceFirst(RegExp(r'^ERROR:\s*(\[[^\]]+\]\s*)?([\w-]+:\s*)?'), '').trim()), false);
  }
  final derniere = t.split('\n').where((l) => l.trim().isNotEmpty).toList();
  return (derniere.isNotEmpty ? coupe(derniere.last) : 'Erreur inconnue (code $code)', false);
}
