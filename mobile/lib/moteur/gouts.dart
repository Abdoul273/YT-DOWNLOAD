/// Goûts de l'utilisateur et fil « Pour vous » : tout reste sur le téléphone.
///
/// Chaque geste laisse un signal pondéré (recherche, aperçu, ouverture, téléchargement,
/// lecture, « pas intéressé ») qui s'efface avec le temps. On en tire un profil
/// (chaînes et mots-clés aimés), puis on va chercher des candidats de plusieurs
/// sources — mix YouTube des vidéos aimées, nouveautés des chaînes suivies,
/// recherches sur les centres d'intérêt, tendances — que l'on classe et mélange.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'analyse.dart';
import 'natif.dart';

/// Poids de chaque geste dans le profil.
const _poids = {
  'clic': 1.0, // résultat ouvert
  'apercu': 2.0,
  'analyse': 1.5, // lien collé ou partagé
  'telechargement': 4.0,
  'lecture': 3.0, // regardé dans le lecteur intégré
  'pas_interesse': -6.0,
};
const _demiVieJours = 21.0;
const _dureeFil = Duration(hours: 1);

String? idVideo(String? url) {
  if (url == null) return null;
  final u = Uri.tryParse(url);
  if (u == null) return null;
  if (u.host.contains('youtu.be')) return u.pathSegments.firstOrNull;
  if (u.queryParameters['v'] != null) return u.queryParameters['v'];
  final i = u.pathSegments.indexOf('shorts');
  if (i >= 0 && i + 1 < u.pathSegments.length) return u.pathSegments[i + 1];
  return null;
}

class Signal {
  final String type;
  final String? id, titre, chaine, chaineId;
  final int t; // secondes
  Signal(this.type, this.id, this.titre, this.chaine, this.chaineId, this.t);
  Map<String, dynamic> versJson() => {'type': type, 'id': id, 'titre': titre, 'chaine': chaine, 'cid': chaineId, 't': t};
  factory Signal.depuis(Map d) => Signal(d['type'] ?? 'clic', d['id'], d['titre'], d['chaine'], d['cid'], d['t'] ?? 0);
}

/// Profil calculé à partir des signaux.
class Profil {
  final Map<String, double> chaines = {}; // nom en minuscules → affinité
  final Map<String, String> idsChaines = {}; // nom → id
  final Map<String, String> nomsChaines = {}; // nom en minuscules → nom affiché
  final Map<String, double> mots = {};
  final Map<String, double> requetes = {};
  final List<(Signal, double)> graines = []; // vidéos aimées, poids actuel
  bool get vide => chaines.isEmpty && mots.isEmpty && requetes.isEmpty;

  double affiniteChaine(String? c) => c == null ? 0 : (chaines[c.toLowerCase()] ?? 0);

  /// Proximité d'un titre avec les mots aimés (0‥1 environ).
  double affiniteTitre(String titre) {
    if (mots.isEmpty) return 0;
    final max = mots.values.fold(0.0, (a, b) => b > a ? b : a);
    if (max <= 0) return 0;
    var s = 0.0;
    for (final m in motsCles(titre)) {
      s += (mots[m] ?? 0) / max;
    }
    return s.clamp(0, 2.5) / 2.5;
  }

  /// Centres d'intérêt à afficher en puces (requêtes et mots les plus forts).
  List<String> interets(int n) {
    final r = <String>[];
    final requetesTriees = requetes.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in requetesTriees) {
      if (r.length >= n ~/ 2) break;
      r.add(e.key);
    }
    final motsTries = mots.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in motsTries) {
      if (r.length >= n) break;
      if (!r.any((x) => x.contains(e.key))) r.add(e.key);
    }
    return r;
  }
}

const _vides = {
  // français
  'les', 'des', 'une', 'pour', 'avec', 'dans', 'sur', 'par', 'est', 'pas', 'que', 'qui', 'son', 'ses', 'aux',
  'mon', 'mes', 'ton', 'tes', 'nous', 'vous', 'ils', 'elle', 'elles', 'mais', 'tout', 'tous', 'plus', 'moins',
  'comment', 'pourquoi', 'quand', 'quoi', 'cette', 'ces', 'cet', 'sans', 'sont', 'fait', 'faire', 'être', 'avoir',
  'très', 'bien', 'trop', 'leur', 'leurs', 'notre', 'votre', 'entre', 'depuis', 'vers', 'chez', 'officiel',
  'officielle', 'vidéo', 'video', 'partie', 'episode', 'épisode', 'full', 'version', 'français', 'francais', 'vf',
  'vostfr', 'complet', 'complète', 'nouveau', 'nouvelle',
  // anglais
  'the', 'and', 'for', 'with', 'you', 'your', 'this', 'that', 'from', 'are', 'was', 'what', 'how', 'why', 'who',
  'official', 'music', 'lyrics', 'lyric', 'audio', 'feat', 'ft', 'part', 'new', 'live', 'hd', '4k', '1080p',
  'shorts', 'short', 'vs',
};

/// Mots porteurs de sens d'un titre ou d'une requête.
List<String> motsCles(String texte) => texte
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .split(' ')
    .where((m) => m.length >= 3 && !_vides.contains(m) && !RegExp(r'^\d+$').hasMatch(m))
    .toSet()
    .toList();

class Gouts extends ChangeNotifier {
  final List<Signal> _signaux = [];
  final List<(String, int)> recherches = []; // (requête, t), plus récente en premier
  final Set<String> _videosBloquees = {}, _chainesBloquees = {};
  final Map<String, int> _impressions = {}; // id → nb d'affichages dans le fil
  List<Entree> fil = [], tendances = [];
  int _majFil = 0, _majTendances = 0;
  bool chargement = false;
  String? erreur;
  Future<void>? _enCours;
  Timer? _sauvegarde;

  File get _fichier => File('${Natif.dossierFichiers}/gouts.json');
  static int get _maintenant => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> charger() async {
    try {
      final d = jsonDecode(await _fichier.readAsString()) as Map;
      _signaux.addAll([for (final s in (d['signaux'] as List?) ?? []) Signal.depuis(s as Map)]);
      recherches.addAll([for (final r in (d['recherches'] as List?) ?? []) ('${r['q']}', (r['t'] ?? 0) as int)]);
      _videosBloquees.addAll(((d['videos_bloquees'] as List?) ?? []).cast<String>());
      _chainesBloquees.addAll(((d['chaines_bloquees'] as List?) ?? []).cast<String>());
      _impressions.addAll(((d['impressions'] as Map?) ?? {}).cast<String, int>());
      fil = [for (final e in (d['fil'] as List?) ?? []) Entree.depuis(e as Map)];
      tendances = [for (final e in (d['tendances'] as List?) ?? []) Entree.depuis(e as Map)];
      _majFil = d['maj_fil'] ?? 0;
      _majTendances = d['maj_tendances'] ?? 0;
    } catch (_) {}
  }

  void _sauver() {
    _sauvegarde?.cancel();
    _sauvegarde = Timer(const Duration(seconds: 2), () async {
      try {
        final tmp = File('${_fichier.path}.tmp');
        await tmp.writeAsString(jsonEncode({
          'signaux': [for (final s in _signaux) s.versJson()],
          'recherches': [for (final (q, t) in recherches) {'q': q, 't': t}],
          'videos_bloquees': _videosBloquees.toList(),
          'chaines_bloquees': _chainesBloquees.toList(),
          'impressions': _impressions,
          'fil': [for (final e in fil) e.versJson()],
          'tendances': [for (final e in tendances) e.versJson()],
          'maj_fil': _majFil,
          'maj_tendances': _majTendances,
        }));
        await tmp.rename(_fichier.path);
      } catch (_) {}
    });
  }

  // ── signaux ─────────────────────────────────────────────────────────
  void signal(String type, {String? url, String? id, String? titre, String? chaine, String? chaineId}) {
    id ??= idVideo(url);
    if (id == null && chaine == null) return;
    // Un même geste répété sur la même vidéo dans l'heure ne compte qu'une fois
    if (_signaux.any((s) => s.type == type && s.id == id && _maintenant - s.t < 3600)) return;
    _signaux.add(Signal(type, id, titre, chaine, chaineId, _maintenant));
    if (_signaux.length > 600) _signaux.removeRange(0, _signaux.length - 600);
    _sauver();
  }

  void signalEntree(String type, Entree e) =>
      signal(type, url: e.url, id: e.id, titre: e.titre, chaine: e.chaine, chaineId: e.chaineId);

  void ajouterRecherche(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    recherches.removeWhere((r) => r.$1.toLowerCase() == q.toLowerCase());
    recherches.insert(0, (q, _maintenant));
    if (recherches.length > 60) recherches.removeLast();
    _sauver();
    notifyListeners();
  }

  void oublierRecherche(String q) {
    recherches.removeWhere((r) => r.$1 == q);
    _sauver();
    notifyListeners();
  }

  void pasInteresse(Entree e) {
    if (e.id != null) _videosBloquees.add(e.id!);
    signalEntree('pas_interesse', e);
    fil.removeWhere((x) => x.id == e.id);
    tendances.removeWhere((x) => x.id == e.id);
    _sauver();
    notifyListeners();
  }

  void bloquerChaine(Entree e) {
    final c = e.chaine?.toLowerCase();
    if (c == null) return;
    _chainesBloquees.add(c);
    fil.removeWhere((x) => x.chaine?.toLowerCase() == c);
    tendances.removeWhere((x) => x.chaine?.toLowerCase() == c);
    _sauver();
    notifyListeners();
  }

  void effacer() {
    _signaux.clear();
    recherches.clear();
    _videosBloquees.clear();
    _chainesBloquees.clear();
    _impressions.clear();
    fil = [];
    _majFil = 0;
    _sauver();
    notifyListeners();
  }

  // ── profil ──────────────────────────────────────────────────────────
  Profil profil() {
    final p = Profil();
    final maintenant = _maintenant;
    double usure(int t) => pow(0.5, (maintenant - t) / 86400 / _demiVieJours).toDouble();
    final parVideo = <String, (Signal, double)>{};
    for (final s in _signaux) {
      final w = (_poids[s.type] ?? 1) * usure(s.t);
      final c = s.chaine?.toLowerCase();
      if (c != null && c.isNotEmpty) {
        // « pas intéressé » pèse surtout sur la vidéo, un peu sur la chaîne
        p.chaines[c] = (p.chaines[c] ?? 0) + (w < 0 ? w / 3 : w);
        p.nomsChaines[c] = s.chaine!;
        if (s.chaineId != null) p.idsChaines[c] = s.chaineId!;
      }
      if (s.titre != null) {
        for (final m in motsCles(s.titre!)) {
          p.mots[m] = (p.mots[m] ?? 0) + w / 2;
        }
      }
      if (s.id != null && w > 0) {
        final prec = parVideo[s.id!];
        parVideo[s.id!] = (s, (prec?.$2 ?? 0) + w);
      }
    }
    for (final (q, t) in recherches) {
      final w = 2.0 * usure(t);
      p.requetes[q.toLowerCase()] = (p.requetes[q.toLowerCase()] ?? 0) + w;
      for (final m in motsCles(q)) {
        p.mots[m] = (p.mots[m] ?? 0) + w;
      }
    }
    for (final c in _chainesBloquees) {
      p.chaines[c] = -100;
    }
    p.graines.addAll(parVideo.values.where((g) => !_videosBloquees.contains(g.$1.id)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2)));
    return p;
  }

  // ── fil ─────────────────────────────────────────────────────────────
  bool get filPerime => DateTime.now().millisecondsSinceEpoch ~/ 1000 - _majFil > _dureeFil.inSeconds;
  bool get aDesGouts => _signaux.any((s) => (_poids[s.type] ?? 0) > 0) || recherches.isNotEmpty;

  /// Recalcule le fil (et les tendances si besoin). Les appels simultanés partagent le même travail.
  Future<void> rafraichir({bool force = false}) {
    if (!force && !filPerime && fil.isNotEmpty) return Future.value();
    return _enCours ??= _rafraichir(force).whenComplete(() => _enCours = null);
  }

  Future<void> _rafraichir(bool force) async {
    chargement = true;
    erreur = null;
    notifyListeners();
    try {
      final p = profil();
      final rnd = Random();
      final taches = <Future<List<(Entree, String, int)>>>[];
      Future<List<(Entree, String, int)>> source(String nom, Future<List<Entree>> f) => f
          .timeout(const Duration(seconds: 45))
          .then((l) => [for (var i = 0; i < l.length; i++) (l[i], nom, i)])
          .catchError((_) => <(Entree, String, int)>[]);

      // 1. Mix YouTube autour de vidéos aimées (tirage pondéré : les favorites reviennent souvent, pas toujours)
      for (final g in _tirage(p.graines, 3, rnd)) {
        final id = g.$1.id!;
        taches.add(source('mix', _limite(() => listeVideos('https://www.youtube.com/watch?v=$id&list=RD$id', max: 25))));
      }
      // 2. Nouveautés des chaînes préférées
      final chaines = p.chaines.entries.where((e) => e.value > 1.5).toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final e in chaines.take(3)) {
        final cid = p.idsChaines[e.key];
        final url = cid != null
            ? 'https://www.youtube.com/channel/$cid/videos'
            : 'ytsearch10:${p.nomsChaines[e.key] ?? e.key}';
        taches.add(source('chaine', _limite(() => listeVideos(url, max: 10))));
      }
      // 3. Centres d'intérêt : recherches récentes du mois
      final interets = p.interets(6)..shuffle(rnd);
      for (final q in interets.take(3)) {
        taches.add(source('interet', _limite(() => rechercher(q, Filtres()..date = 'mois', nombre: 15))));
      }
      // 4. Tendances
      final tendancesFut = (force || tendances.isEmpty || _maintenant - _majTendances > 3 * 3600)
          ? _limite(_chercherTendances)
          : Future.value(tendances);
      taches.add(source('tendance', tendancesFut));

      final resultats = (await Future.wait(taches)).expand((l) => l).toList();
      final nouvellesTendances = [for (final (e, s, _) in resultats) if (s == 'tendance') e];
      if (nouvellesTendances.isNotEmpty && !identical(nouvellesTendances, tendances)) {
        tendances = _filtrer(nouvellesTendances).toList();
        _majTendances = _maintenant;
      }
      final classe = _classer(resultats, p, rnd);
      if (classe.isEmpty && fil.isEmpty && tendances.isEmpty) {
        erreur = 'Impossible de charger des vidéos. Vérifie ta connexion.';
      }
      if (classe.isNotEmpty) {
        fil = classe;
        _majFil = _maintenant;
        for (final e in fil.take(12)) {
          _impressions[e.id!] = (_impressions[e.id!] ?? 0) + 1;
        }
        if (_impressions.length > 1500) {
          final cles = _impressions.keys.take(_impressions.length - 1500).toList();
          cles.forEach(_impressions.remove);
        }
      }
      _sauver();
    } catch (e) {
      erreur = '$e';
    } finally {
      chargement = false;
      notifyListeners();
    }
  }

  Iterable<Entree> _filtrer(Iterable<Entree> l) => l.where((e) =>
      e.id != null &&
      e.url != null &&
      !e.direct &&
      !_videosBloquees.contains(e.id) &&
      !_chainesBloquees.contains(e.chaine?.toLowerCase()));

  List<Entree> _classer(List<(Entree, String, int)> candidats, Profil p, Random rnd) {
    const poidsSource = {'mix': 3.0, 'chaine': 2.6, 'interet': 2.2, 'tendance': 1.2};
    // Déjà ouvertes, regardées ou téléchargées : inutile de les reproposer
    final dejaVus = {for (final s in _signaux) s.id};
    final maintenant = _maintenant;
    final scores = <String, (Entree, double)>{};
    final froid = p.vide;
    for (final (e, src, rang) in candidats) {
      if (!_filtrer([e]).iterator.moveNext() || dejaVus.contains(e.id)) continue;
      var s = (poidsSource[src] ?? 1) * (froid && src == 'tendance' ? 2 : 1) / (1 + rang * 0.06);
      s += 1.4 * (p.affiniteChaine(e.chaine) / 10).clamp(-3.0, 1.0);
      s += 1.2 * p.affiniteTitre(e.titre);
      if (e.date != null) {
        final jours = (maintenant - e.date!) / 86400;
        s += jours < 3 ? 0.6 : jours < 14 ? 0.35 : jours < 60 ? 0.1 : 0;
      }
      if (e.vues != null) s += 0.25 * log(e.vues! + 1) / ln10 / 8;
      if (e.duree != null && e.duree! < 60) s -= 0.3; // shorts : moins prioritaires
      s -= 0.45 * (_impressions[e.id] ?? 0); // déjà proposé souvent sans être choisi
      s += rnd.nextDouble() * 0.7; // part d'exploration
      final prec = scores[e.id!];
      // Proposé par plusieurs sources : signal fort
      scores[e.id!] = prec == null ? (e, s) : (prec.$1, max(prec.$2, s) + 0.5);
    }
    // Sélection gloutonne avec diversité des chaînes
    final restants = scores.values.toList();
    final parChaine = <String, int>{};
    final res = <Entree>[];
    while (restants.isNotEmpty && res.length < 60) {
      var meilleur = 0;
      var meilleurScore = double.negativeInfinity;
      for (var i = 0; i < restants.length; i++) {
        final (e, s) = restants[i];
        final n = parChaine[e.chaine?.toLowerCase() ?? ''] ?? 0;
        final ajuste = s - n * 0.9;
        if (ajuste > meilleurScore) {
          meilleurScore = ajuste;
          meilleur = i;
        }
      }
      final (e, _) = restants.removeAt(meilleur);
      final c = e.chaine?.toLowerCase() ?? '';
      parChaine[c] = (parChaine[c] ?? 0) + 1;
      res.add(e);
    }
    return res;
  }

  /// Tirage pondéré sans remise de [n] graines.
  List<(Signal, double)> _tirage(List<(Signal, double)> graines, int n, Random rnd) {
    final pool = graines.take(25).toList();
    final res = <(Signal, double)>[];
    while (res.length < n && pool.isNotEmpty) {
      final total = pool.fold(0.0, (a, g) => a + g.$2);
      var x = rnd.nextDouble() * total;
      var i = 0;
      while (i < pool.length - 1 && (x -= pool[i].$2) > 0) {
        i++;
      }
      res.add(pool.removeAt(i));
    }
    return res;
  }

  /// YouTube a retiré sa page Tendances : on reconstitue les vidéos les plus vues
  /// de la semaine sur des sujets populaires, dans la langue du téléphone.
  Future<List<Entree>> _chercherTendances() async {
    final langue = PlatformDispatcher.instance.locale.languageCode;
    final sujets = langue == 'fr'
        ? ['clip officiel', 'actualité', 'football', 'humour', 'jeux vidéo', 'bande annonce']
        : ['official music video', 'news', 'football', 'comedy', 'gaming', 'trailer'];
    sujets.shuffle();
    final f = Filtres()
      ..date = 'semaine'
      ..tri = 'vues';
    final listes = await Future.wait([
      for (final s in sujets.take(3)) rechercher(s, f, nombre: 12).catchError((_) => <Entree>[]),
    ]);
    // Entrelacement des sujets pour varier, puis tri léger par vues
    final res = <Entree>[];
    for (var i = 0; i < 12; i++) {
      for (final l in listes) {
        if (i < l.length) res.add(l[i]);
      }
    }
    return res;
  }

  // yt-dlp lance un Python à chaque appel : pas plus de 3 en même temps
  int _actifs = 0;
  final _attente = <Completer<void>>[];
  Future<T> _limite<T>(Future<T> Function() f) async {
    if (_actifs >= 3) {
      final c = Completer<void>();
      _attente.add(c);
      await c.future;
    }
    _actifs++;
    try {
      return await f();
    } finally {
      _actifs--;
      if (_attente.isNotEmpty) _attente.removeAt(0).complete();
    }
  }
}

final gouts = Gouts();

// ── suggestions de recherche ──────────────────────────────────────────
final _cacheSuggestions = <String, List<String>>{};
final _client = HttpClient()..connectionTimeout = const Duration(seconds: 4);

/// Suggestions de saisie de YouTube (même service que l'app officielle).
Future<List<String>> suggestions(String q) async {
  q = q.trim();
  if (q.isEmpty) return [];
  final cle = q.toLowerCase();
  final c = _cacheSuggestions[cle];
  if (c != null) return c;
  final langue = PlatformDispatcher.instance.locale;
  final url = Uri.https('suggestqueries-clients6.youtube.com', '/complete/search', {
    'client': 'firefox',
    'ds': 'yt',
    'hl': langue.languageCode,
    'gl': langue.countryCode ?? 'FR',
    'ie': 'utf-8',
    'oe': 'utf-8',
    'q': q,
  });
  final req = await _client.getUrl(url).timeout(const Duration(seconds: 5));
  req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Android 14; Mobile; rv:130.0) Gecko/130.0 Firefox/130.0');
  final rep = await req.close().timeout(const Duration(seconds: 5));
  final corps = await rep.transform(utf8.decoder).join();
  var texte = corps.trim();
  // Réponse JSON pure (client firefox) ou JSONP (client youtube)
  final debut = texte.indexOf('[');
  final fin = texte.lastIndexOf(']');
  if (debut < 0 || fin < debut) return [];
  texte = texte.substring(debut, fin + 1);
  final d = jsonDecode(texte) as List;
  final res = <String>[
    for (final s in (d.length > 1 ? d[1] as List : []))
      if (s is String)
        s
      else if (s is List && s.isNotEmpty && s.first is String)
        s.first as String
  ];
  _cacheSuggestions[cle] = res;
  if (_cacheSuggestions.length > 300) _cacheSuggestions.remove(_cacheSuggestions.keys.first);
  return res;
}
