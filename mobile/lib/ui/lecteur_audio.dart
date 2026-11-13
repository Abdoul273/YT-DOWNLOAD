/// Lecteur musical persistant (« Onde » intégrée à YT-NEXUS) :
/// moteur global qui continue en arrière-plan et entre les onglets,
/// mini-lecteur flottant en verre dépoli et studio plein écran avec
/// platine vinyle animée, égaliseur 5 bandes + Bass Boost + Amplificateur,
/// paroles synchronisées (.srt / .vtt), boucle A-B, file d'attente réorganisable,
/// mode aléatoire, répétition et minuteur de sommeil.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageByteFormat, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../moteur/gouts.dart';
import '../moteur/langues.dart' as langues;
import '../moteur/miniatures.dart' as miniatures;
import '../moteur/natif.dart';
import '../moteur/paroles.dart';
import '../moteur/reglages.dart';
import '../moteur/taches.dart';
import 'theme.dart';

/// Profils d'égalisation 5 bandes (60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) entre -1.0 et +1.0.
const profilsEgaliseur = <String, (String, IconData, List<double>)>{
  'neutre': ('Studio Neutre', Icons.graphic_eq_rounded, [0.0, 0.0, 0.0, 0.0, 0.0]),
  'basses': ('Ultra Basses', Icons.speaker_rounded, [0.85, 0.55, 0.0, -0.1, 0.15]),
  'voix': ('Voix & Podcast', Icons.mic_rounded, [-0.25, 0.15, 0.75, 0.55, 0.1]),
  'club': ('Électro & Club', Icons.nightlife_rounded, [0.75, 0.35, -0.15, 0.45, 0.75]),
  'acoustique': ('Acoustique', Icons.music_note_rounded, [0.35, 0.2, 0.15, 0.45, 0.5]),
  'cinema': ('Spatial & Clair', Icons.surround_sound_rounded, [0.55, 0.25, -0.1, 0.5, 0.8]),
  'perso': ('Personnalisé', Icons.tune_rounded, [0.0, 0.0, 0.0, 0.0, 0.0]),
};

const frequencesBandes = ['60 Hz', '230 Hz', '910 Hz', '3,6 kHz', '14 kHz'];

/// Contrôleur global de lecture musicale.
class MoteurAudio extends ChangeNotifier {
  VideoPlayerController? _ctrl;
  int _generation = 0;
  List<Tache> _file = [];
  List<int> _ordreAleatoire = [];
  int _index = 0;
  String? _erreur;
  bool _enLecture = false;
  bool _signale = false;
  List<VideoAudioTrack> _pistes = [];
  DonneesParoles? _donneesParoles;
  DonneesParoles? _parolesEnLigne;
  List<({String id, String label, FichierPublie fichier})> _sourcesLocales = [];
  bool _rechercheParolesEnCours = false;
  int _decalageParolesMs = 0;
  Duration? _a, _b;
  Timer? _sommeil;
  DateTime? _finSommeil;
  int _sommeilMin = 0;
  Duration? _departInitial;
  StreamSubscription? _aboMedia;
  final morceauActif = ValueNotifier<String?>('');

  double _vitesse = _pref<num>('lecteur_vitesse', 1.0).toDouble();
  bool _aleatoire = _pref<bool>('audio_aleatoire', false);
  int _repetition = _pref<num>('audio_repetition', 0).toInt().clamp(0, 2); // 0: non, 1: tout, 2: un
  String _stylePochette = _pref<String>('audio_style_pochette', 'vinyle');
  bool _spectreActif = _pref<bool>('audio_spectre', true);
  bool _eqActif = _pref<bool>('audio_eq_actif', false);
  String _eqProfil = _pref<String>('audio_eq_profil', 'neutre');
  List<double> _bandes = _lireBandes();
  int _basses = _pref<num>('audio_basses', 0).toInt().clamp(0, 1000);
  double _gain = _pref<num>('audio_gain', 0.0).toDouble().clamp(0.0, 15.0);

  static T _pref<T>(String cle, T defaut) {
    final v = reglages[cle];
    return v is T ? v : defaut;
  }

  static List<double> _lireBandes() {
    final l = reglages['audio_eq_bandes'];
    if (l is List && l.length == 5) {
      return [for (final e in l) (e is num ? e.toDouble() : 0.0).clamp(-1.0, 1.0)];
    }
    return [0.0, 0.0, 0.0, 0.0, 0.0];
  }

  bool get actif => _file.isNotEmpty && _index >= 0 && _index < _file.length;
  Tache? get tache => actif ? _file[_index] : null;
  List<Tache> get file => List.unmodifiable(_file);
  int get index => _index;
  String? get erreur => _erreur;
  VideoPlayerController? get ctrl => _ctrl;
  bool get initialise => _ctrl?.value.isInitialized ?? false;
  bool get enLecture => _ctrl?.value.isPlaying ?? false;
  Duration get position => _ctrl?.value.position ?? Duration.zero;
  Duration get duree => _ctrl?.value.duration ?? Duration.zero;
  double get avancement {
    final d = duree.inMilliseconds;
    if (d <= 0) return 0;
    return (position.inMilliseconds / d).clamp(0.0, 1.0);
  }

  double get vitesse => _vitesse;
  bool get aleatoire => _aleatoire;
  int get repetition => _repetition;
  String get stylePochette => _stylePochette;
  bool get spectreActif => _spectreActif;
  bool get eqActif => _eqActif;
  String get eqProfil => _eqProfil;
  List<double> get bandes => List.unmodifiable(_bandes);
  int get basses => _basses;
  double get gain => _gain;
  List<VideoAudioTrack> get pistes => _pistes;
  List<LigneParole> get paroles => _donneesParoles?.lignes ?? const [];
  DonneesParoles? get donneesParoles => _donneesParoles;
  DonneesParoles? get parolesEnLigne => _parolesEnLigne;
  List<({String id, String label, FichierPublie fichier})> get sourcesLocales => _sourcesLocales;
  bool get rechercheParolesEnCours => _rechercheParolesEnCours;
  int get decalageParolesMs => _decalageParolesMs;
  Duration get positionParoles {
    final p = position + Duration(milliseconds: _decalageParolesMs);
    return p < Duration.zero ? Duration.zero : p;
  }
  Duration? get pointA => _a;
  Duration? get pointB => _b;
  int get sommeilMin => _sommeilMin;

  int get minutesSommeilRestantes {
    final f = _finSommeil;
    if (f == null) return 0;
    final d = f.difference(DateTime.now()).inMinutes + 1;
    return d.clamp(1, 999);
  }

  bool get aPrecedent => _file.length > 1 || position.inSeconds > 3;
  bool get aSuivant {
    if (_file.isEmpty) return false;
    if (_repetition != 0 || _aleatoire) return true;
    return _index < _file.length - 1;
  }

  /// Piste cible en cas de glissement vers la droite (précédent) ou la gauche (suivant).
  Tache? get tacheSuivante {
    if (_file.length <= 1) return null;
    if (_aleatoire && _ordreAleatoire.length == _file.length) {
      final pos = _ordreAleatoire.indexOf(_index);
      if (pos >= 0 && pos < _ordreAleatoire.length - 1) {
        return _file[_ordreAleatoire[pos + 1]];
      }
      return _file[_ordreAleatoire.first];
    }
    return _file[(_index + 1) % _file.length];
  }

  Tache? get tachePrecedente {
    if (_file.length <= 1) return null;
    if (_aleatoire && _ordreAleatoire.length == _file.length) {
      final pos = _ordreAleatoire.indexOf(_index);
      if (pos > 0) return _file[_ordreAleatoire[pos - 1]];
    }
    if (_index > 0) return _file[_index - 1];
    return _repetition == 1 ? _file.last : null;
  }

  void _ecouterCommandes() {
    _aboMedia ??= Natif.commandesMedia.listen((m) {
      if (!actif) return;
      switch (m.action) {
        case 'play':
          reprendre();
        case 'pause':
          pause();
        case 'next':
          suivant();
        case 'prev':
          precedent();
        case 'seek':
          allerA(Duration(milliseconds: m.position));
        case 'stop':
          fermer();
      }
    });
  }

  /// Lance une liste de morceaux à partir de [indexInitial].
  Future<void> ouvrir(
    List<Tache> liste,
    int indexInitial, {
    bool melanger = false,
    Duration? departPosition,
  }) async {
    if (liste.isEmpty) return;
    _ecouterCommandes();
    _file = List.of(liste);
    _index = indexInitial.clamp(0, _file.length - 1);
    _departInitial = departPosition;
    // Synchroniser les réglages EQ au cas où ils auraient été modifiés côté lecteur vidéo
    _eqActif = _pref<bool>('audio_eq_actif', false);
    _eqProfil = _pref<String>('audio_eq_profil', 'neutre');
    _bandes = _lireBandes();
    _basses = _pref<num>('audio_basses', 0).toInt().clamp(0, 1000);
    _gain = _pref<num>('audio_gain', 0.0).toDouble().clamp(0.0, 15.0);
    if (melanger) {
      _aleatoire = true;
      reglages.ecrireSansPrevenir('audio_aleatoire', true);
    }
    _recalculerOrdreAleatoire();
    await _charger();
  }

  /// Ajoute un titre juste après le morceau en cours.
  void lireEnsuite(Tache t) {
    if (!actif) {
      ouvrir([t], 0);
      return;
    }
    final existant = _file.indexWhere((e) => e.id == t.id);
    if (existant == _index) return;
    if (existant >= 0) {
      _file.removeAt(existant);
      if (existant < _index) _index--;
    }
    _file.insert(_index + 1, t);
    _recalculerOrdreAleatoire();
    notifyListeners();
  }

  /// Ajoute un titre à la fin de la file d'attente.
  void ajouterAFile(Tache t) {
    if (!actif) {
      ouvrir([t], 0);
      return;
    }
    if (_file.any((e) => e.id == t.id)) return;
    _file.add(t);
    _recalculerOrdreAleatoire();
    notifyListeners();
  }

  /// Réorganise la file d'attente.
  void deplacerDansFile(int ancien, int nouveau) {
    if (ancien < 0 || ancien >= _file.length) return;
    nouveau = nouveau.clamp(0, _file.length - 1);
    if (ancien == nouveau) return;
    final actuel = tache;
    final elem = _file.removeAt(ancien);
    _file.insert(nouveau, elem);
    if (actuel != null) _index = _file.indexOf(actuel);
    _recalculerOrdreAleatoire();
    notifyListeners();
  }

  void retirerDeFile(int idx) {
    if (idx < 0 || idx >= _file.length) return;
    if (_file.length == 1) {
      fermer();
      return;
    }
    final etaitActuel = idx == _index;
    _file.removeAt(idx);
    if (idx < _index) {
      _index--;
    } else if (_index >= _file.length) {
      _index = 0;
    }
    _recalculerOrdreAleatoire();
    if (etaitActuel) {
      _charger();
    } else {
      notifyListeners();
    }
  }

  void _recalculerOrdreAleatoire() {
    _ordreAleatoire = List.generate(_file.length, (i) => i);
    if (_file.length > 1) {
      final r = Random();
      _ordreAleatoire.remove(_index);
      _ordreAleatoire.shuffle(r);
      _ordreAleatoire.insert(0, _index);
    }
  }

  Future<void> _charger() async {
    final gen = ++_generation;
    bool perime() => gen != _generation || !actif;
    _memoriserPosition();
    final ancien = _ctrl;
    ancien?.removeListener(_maj);
    _enLecture = false;
    _ctrl = null;
    _erreur = null;
    _pistes = [];
    _donneesParoles = null;
    _parolesEnLigne = null;
    _sourcesLocales = [];
    _rechercheParolesEnCours = false;
    _signale = false;
    _a = _b = null;
    notifyListeners();
    await ancien?.dispose();
    if (perime()) return;

    final t = tache!;
    final f = t.fichierPrincipal;
    if (f == null) {
      _erreur = 'Fichier audio introuvable.';
      notifyListeners();
      return;
    }
    final decMap = (reglages['decalages_paroles'] as Map?) ?? const {};
    _decalageParolesMs = (decMap[t.id] as num?)?.toInt() ?? 0;

    final uri = Uri.parse(f.uri);
    final opts = VideoPlayerOptions(allowBackgroundPlayback: true);
    final ctrl = uri.scheme == 'content'
        ? VideoPlayerController.contentUri(uri, videoPlayerOptions: opts)
        : VideoPlayerController.file(
            File(f.chemin.isNotEmpty ? f.chemin : uri.toFilePath()),
            videoPlayerOptions: opts,
          );
    try {
      await ctrl.initialize();
    } catch (_) {
      ctrl.dispose();
      if (!perime()) {
        _erreur = 'Impossible de lire ce fichier audio (déplacé ou format non supporté).';
        notifyListeners();
      }
      return;
    }
    if (perime()) {
      ctrl.dispose();
      return;
    }
    await ctrl.setLooping(_repetition == 2);
    await ctrl.setPlaybackSpeed(_vitesse);
    final depart = _departInitial;
    _departInitial = null;
    if (depart != null && depart > Duration.zero && depart < ctrl.value.duration) {
      await ctrl.seekTo(depart);
    } else {
      final pos = ((reglages['positions'] as Map?) ?? {})[t.id];
      // Pour la musique de moins de 12 min, on repart du début ; pour un long podcast/mix, on reprend.
      if (pos is int && ctrl.value.duration.inMinutes >= 12 && pos > 10000 && pos < ctrl.value.duration.inMilliseconds * 0.95) {
        await ctrl.seekTo(Duration(milliseconds: pos));
      }
    }
    if (perime()) {
      ctrl.dispose();
      return;
    }
    ctrl.addListener(_maj);
    _ctrl = ctrl;
    await ctrl.play();
    if (perime()) return;
    _appliquerEffets();
    _synchro();
    notifyListeners();

    try {
      final p = await ctrl.getAudioTracks();
      if (!perime()) {
        _pistes = p;
        notifyListeners();
      }
    } catch (_) {}

    _initialiserParolesPiste(t, gen);
  }

  Future<void> _initialiserParolesPiste(Tache t, int gen) async {
    bool perime() => gen != _generation || !actif || tache?.id != t.id;
    final locales = sourcesLocalesDisponibles(t);
    _sourcesLocales = locales;
    final cache = lireCacheParoles(t.id);

    // 1. Si l'utilisateur a choisi des sous-titres YouTube (.srt / .vtt / .lrc) lors du téléchargement,
    //    ils s'affichent immédiatement dans l'onglet Paroles (sauf si l'utilisateur a explicitement forcé
    //    une autre source manuelle en cache).
    final choixManuelEnLigne = cache != null &&
        !cache.vide &&
        (cache.idSource.startsWith('lrclib:') ||
            cache.idSource.startsWith('netease:') ||
            cache.idSource == 'import') &&
        locales.isEmpty;

    if (locales.isNotEmpty) {
      final srcCible = locales.firstWhere(
        (s) => cache != null && cache.idSource == s.id,
        orElse: () => locales.first,
      );
      final local = await chargerFichierParolesLocal(
        srcCible.fichier,
        labelSource: srcCible.label,
        dureeTotaleSec: t.duree,
      );
      if (perime()) return;
      if (local != null && !local.vide) {
        _donneesParoles = local;
        notifyListeners();
      }
      // Si l'utilisateur avait sélectionné une source en ligne sur ce morceau, on la restaure
      if (cache != null &&
          !cache.vide &&
          (cache.idSource.startsWith('lrclib:') ||
              cache.idSource.startsWith('netease:') ||
              cache.idSource == 'import')) {
        _parolesEnLigne = cache;
        _donneesParoles = cache;
        notifyListeners();
        return;
      }
    } else if (choixManuelEnLigne) {
      _parolesEnLigne = cache;
      _donneesParoles = cache;
      notifyListeners();
      return;
    }

    // 2. Recherche automatique LRCLIB + NetEase (mot-à-mot YRC/KRC) en arrière-plan
    if (cache != null && !cache.vide && !cache.idSource.startsWith('local:')) {
      _parolesEnLigne = cache;
      if (_donneesParoles == null || _donneesParoles!.vide) {
        _donneesParoles = cache;
      }
      notifyListeners();
      return;
    }

    _rechercheParolesEnCours = true;
    notifyListeners();
    final enLigne = await chercherParolesAutoEnLigne(t);
    if (perime()) return;
    _rechercheParolesEnCours = false;
    if (enLigne != null && !enLigne.vide) {
      sauverCacheParoles(t.id, enLigne);
      _parolesEnLigne = enLigne;
      // Si aucun sous-titre YouTube n'était présent (ou s'il était vide), afficher LRCLIB/NetEase
      if (_donneesParoles == null || _donneesParoles!.vide) {
        _donneesParoles = enLigne;
      }
    } else if (_donneesParoles == null) {
      sauverCacheParoles(t.id, const DonneesParoles(source: 'Aucune'));
    }
    notifyListeners();
  }

  /// Change la source de paroles active (entre un fichier `.srt` YouTube et LRCLIB/NetEase).
  Future<void> basculerSourceParoles(String idSource) async {
    final t = tache;
    if (t == null) return;
    HapticFeedback.selectionClick();
    if (idSource == 'en_ligne') {
      if (_parolesEnLigne != null && !_parolesEnLigne!.vide) {
        _donneesParoles = _parolesEnLigne;
        sauverCacheParoles(t.id, _parolesEnLigne!);
        notifyListeners();
        return;
      }
      await relancerRechercheParoles(forcerEnLigne: true);
      return;
    }
    for (final s in _sourcesLocales) {
      if (s.id == idSource) {
        final local = await chargerFichierParolesLocal(
          s.fichier,
          labelSource: s.label,
          dureeTotaleSec: t.duree,
        );
        if (local != null) {
          _donneesParoles = local;
          sauverCacheParoles(t.id, local);
          notifyListeners();
        }
        return;
      }
    }
  }

  /// Force une nouvelle recherche automatique de paroles sur LRCLIB et NetEase.
  Future<bool> relancerRechercheParoles({bool forcerEnLigne = false}) async {
    final t = tache;
    if (t == null || _rechercheParolesEnCours) return false;
    _rechercheParolesEnCours = true;
    notifyListeners();
    final enLigne = await chercherParolesAutoEnLigne(t);
    if (tache?.id != t.id) return false;
    _rechercheParolesEnCours = false;
    if (enLigne != null && !enLigne.vide) {
      _parolesEnLigne = enLigne;
      if (forcerEnLigne || _donneesParoles == null || _donneesParoles!.vide) {
        _donneesParoles = enLigne;
        sauverCacheParoles(t.id, enLigne);
      }
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  /// Applique un candidat de paroles choisi manuellement dans la feuille de recherche.
  Future<bool> choisirParolesManuelles(CandidatParoles c) async {
    final t = tache;
    if (t == null) return false;
    _rechercheParolesEnCours = true;
    notifyListeners();
    final res = await choisirCandidatParoles(t, c);
    if (tache?.id != t.id) return false;
    _rechercheParolesEnCours = false;
    if (res != null && !res.vide) {
      _parolesEnLigne = res;
      _donneesParoles = res;
      ajusterDecalageParoles(0, reinitialiser: true);
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  /// Importe un texte LRC ou texte brut collé par l'utilisateur.
  void importerParoles(String texte) {
    final t = tache;
    if (t == null || texte.trim().isEmpty) return;
    final res = importerTexteParoles(t, texte);
    _parolesEnLigne = res;
    _donneesParoles = res;
    ajusterDecalageParoles(0, reinitialiser: true);
    notifyListeners();
  }

  /// Ajuste le décalage temporel des paroles (en millisecondes) pour le morceau en cours.
  void ajusterDecalageParoles(int deltaMs, {bool reinitialiser = false}) {
    final t = tache;
    if (t == null) return;
    HapticFeedback.selectionClick();
    if (reinitialiser) {
      _decalageParolesMs = 0;
    } else {
      _decalageParolesMs = (_decalageParolesMs + deltaMs).clamp(-60000, 60000);
    }
    final map = Map<String, dynamic>.from((reglages['decalages_paroles'] as Map?) ?? {});
    if (_decalageParolesMs == 0) {
      map.remove(t.id);
    } else {
      map[t.id] = _decalageParolesMs;
    }
    reglages.ecrireSansPrevenir('decalages_paroles', map);
    notifyListeners();
  }

  /// Cale immédiatement le début d'une ligne de paroles sur la position audio actuelle (comme Onde « Caler »).
  void calerParoleSurVoix(Duration debutLigne) {
    final t = tache;
    if (t == null) return;
    HapticFeedback.mediumImpact();
    _decalageParolesMs = (debutLigne.inMilliseconds - position.inMilliseconds).clamp(-60000, 60000);
    final map = Map<String, dynamic>.from((reglages['decalages_paroles'] as Map?) ?? {});
    if (_decalageParolesMs == 0) {
      map.remove(t.id);
    } else {
      map[t.id] = _decalageParolesMs;
    }
    reglages.ecrireSansPrevenir('decalages_paroles', map);
    notifyListeners();
  }

  void _maj() {
    final c = _ctrl;
    if (c == null || !actif) return;
    final v = c.value;
    if (v.hasError) {
      if (_erreur == null) {
        _erreur = 'Lecture interrompue.';
        Natif.mediaArreter();
        notifyListeners();
      }
      return;
    }
    if (v.isInitialized && v.isPlaying != _enLecture) _synchro();
    final t = tache!;
    if (!_signale && v.duration > Duration.zero &&
        (v.position.inSeconds > 45 || v.position.inMilliseconds > v.duration.inMilliseconds * 0.35)) {
      _signale = true;
      gouts.signal('lecture', url: t.url, titre: t.titre, chaine: t.chaine);
    }
    final b = _b;
    if (b != null && v.isPlaying && v.position >= b) {
      c.seekTo(_a ?? Duration.zero);
    }
    final fini = _repetition != 2 &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        (v.isCompleted || v.position >= v.duration) &&
        !v.isPlaying;
    if (fini) {
      _effacerPosition();
      if (_aProchainAuto) {
        suivant(auto: true);
        return;
      }
    }
    notifyListeners();
  }

  bool get _aProchainAuto {
    if (_file.isEmpty) return false;
    if (_repetition == 1) return true;
    if (_aleatoire) {
      final pos = _ordreAleatoire.indexOf(_index);
      return pos >= 0 && pos < _ordreAleatoire.length - 1;
    }
    return _index < _file.length - 1;
  }

  void _synchro() {
    final c = _ctrl;
    final t = tache;
    if (c == null || t == null || !c.value.isInitialized) return;
    final v = c.value;
    _enLecture = v.isPlaying;
    morceauActif.value = '${t.id}:${v.isPlaying}';
    Natif.media(
      titre: t.titre,
      artiste: t.chaine ?? 'YT-NEXUS Music',
      image: miniatures.locale(t.miniature) ?? t.miniature,
      lecture: v.isPlaying,
      position: v.position.inMilliseconds,
      duree: v.duration.inMilliseconds,
      vitesse: _vitesse,
      prec: aPrecedent,
      suiv: aSuivant,
    );
  }

  void lecturePause() {
    final c = _ctrl;
    if (c == null) return;
    final v = c.value;
    HapticFeedback.lightImpact();
    if (v.position >= v.duration && v.duration > Duration.zero) {
      c.seekTo(Duration.zero).then((_) {
        c.play();
        _synchro();
      });
    } else {
      v.isPlaying ? pause() : reprendre();
    }
  }

  void pause() {
    _ctrl?.pause();
    _memoriserPosition();
    _synchro();
    notifyListeners();
  }

  void reprendre() {
    _ctrl?.play();
    _synchro();
    notifyListeners();
  }

  Future<void> allerA(Duration cible) async {
    final c = _ctrl;
    if (c == null) return;
    final d = c.value.duration;
    final borne = cible < Duration.zero ? Duration.zero : (cible > d ? d : cible);
    await c.seekTo(borne);
    _synchro();
    notifyListeners();
  }

  void sauterSecondes(int delta) {
    final c = _ctrl;
    if (c == null) return;
    HapticFeedback.selectionClick();
    allerA(c.value.position + Duration(seconds: delta));
  }

  void suivant({bool auto = false}) {
    if (_file.isEmpty) return;
    if (!auto) HapticFeedback.lightImpact();
    if (_aleatoire && _ordreAleatoire.length == _file.length) {
      final pos = _ordreAleatoire.indexOf(_index);
      if (pos >= 0 && pos < _ordreAleatoire.length - 1) {
        _allerIndex(_ordreAleatoire[pos + 1]);
        return;
      } else if (_repetition == 1 || !auto) {
        _recalculerOrdreAleatoire();
        _allerIndex(_ordreAleatoire.first);
        return;
      }
    } else {
      if (_index < _file.length - 1) {
        _allerIndex(_index + 1);
        return;
      } else if (_repetition == 1 || !auto) {
        _allerIndex(0);
        return;
      }
    }
  }

  void precedent() {
    if (_file.isEmpty) return;
    HapticFeedback.lightImpact();
    if (position.inSeconds > 4) {
      allerA(Duration.zero);
      return;
    }
    if (_aleatoire && _ordreAleatoire.length == _file.length) {
      final pos = _ordreAleatoire.indexOf(_index);
      if (pos > 0) {
        _allerIndex(_ordreAleatoire[pos - 1]);
        return;
      }
    }
    if (_index > 0) {
      _allerIndex(_index - 1);
    } else if (_repetition == 1) {
      _allerIndex(_file.length - 1);
    } else {
      allerA(Duration.zero);
    }
  }

  void allerIndex(int i) {
    if (i < 0 || i >= _file.length || i == _index) return;
    HapticFeedback.selectionClick();
    _allerIndex(i);
  }

  void _allerIndex(int i) {
    _memoriserPosition();
    _ctrl?.removeListener(_maj);
    _ctrl?.pause();
    _index = i;
    _charger();
  }

  void basculerAleatoire() {
    HapticFeedback.selectionClick();
    _aleatoire = !_aleatoire;
    reglages.ecrireSansPrevenir('audio_aleatoire', _aleatoire);
    _recalculerOrdreAleatoire();
    _synchro();
    notifyListeners();
  }

  void basculerRepetition() {
    HapticFeedback.selectionClick();
    _repetition = (_repetition + 1) % 3;
    reglages.ecrireSansPrevenir('audio_repetition', _repetition);
    _ctrl?.setLooping(_repetition == 2);
    _synchro();
    notifyListeners();
  }

  static const _stylesPochette = ['vinyle', 'carte', 'onde'];

  void basculerStylePochette() {
    HapticFeedback.selectionClick();
    final i = _stylesPochette.indexOf(_stylePochette);
    _stylePochette = _stylesPochette[(i + 1) % _stylesPochette.length];
    reglages.ecrireSansPrevenir('audio_style_pochette', _stylePochette);
    notifyListeners();
  }

  void choisirStylePochette(String style) {
    if (!_stylesPochette.contains(style) || _stylePochette == style) return;
    HapticFeedback.selectionClick();
    _stylePochette = style;
    reglages.ecrireSansPrevenir('audio_style_pochette', _stylePochette);
    notifyListeners();
  }

  void basculerSpectre() {
    HapticFeedback.selectionClick();
    _spectreActif = !_spectreActif;
    reglages.ecrireSansPrevenir('audio_spectre', _spectreActif);
    notifyListeners();
  }

  void changerVitesse(double v) {
    _vitesse = (v.clamp(0.25, 3.0) * 20).round() / 20;
    reglages.ecrireSansPrevenir('lecteur_vitesse', _vitesse);
    _ctrl?.setPlaybackSpeed(_vitesse);
    _synchro();
    notifyListeners();
  }

  void basculerBoucleAB() {
    final c = _ctrl;
    if (c == null) return;
    HapticFeedback.selectionClick();
    final p = c.value.position;
    if (_a == null) {
      _a = p;
    } else if (_b == null) {
      if (p > _a! + const Duration(seconds: 1)) {
        _b = p;
      } else {
        _a = null;
      }
    } else {
      _a = _b = null;
    }
    notifyListeners();
  }

  void programmerSommeil(int minutes) {
    _sommeil?.cancel();
    _sommeilMin = minutes;
    if (minutes <= 0) {
      _finSommeil = null;
      notifyListeners();
      return;
    }
    _finSommeil = DateTime.now().add(Duration(minutes: minutes));
    _sommeil = Timer(Duration(minutes: minutes), () {
      pause();
      _sommeilMin = 0;
      _finSommeil = null;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> choisirPisteAudio(String id) async {
    final c = _ctrl;
    if (c == null) return;
    await c.selectAudioTrack(id);
    try {
      _pistes = await c.getAudioTracks();
      notifyListeners();
    } catch (_) {}
  }

  // ── Égaliseur & Effets Studio ───────────────────────────────────────
  void basculerEgaliseur(bool v) {
    _eqActif = v;
    reglages.ecrireSansPrevenir('audio_eq_actif', v);
    _appliquerEffets();
    notifyListeners();
  }

  void choisirProfilEq(String cle) {
    final p = profilsEgaliseur[cle];
    if (p == null) return;
    _eqProfil = cle;
    _eqActif = true;
    if (cle != 'perso') {
      _bandes = List.of(p.$3);
      reglages.ecrireSansPrevenir('audio_eq_bandes', _bandes);
    }
    reglages.ecrireSansPrevenir('audio_eq_profil', cle);
    reglages.ecrireSansPrevenir('audio_eq_actif', true);
    _appliquerEffets();
    notifyListeners();
  }

  void modifierBandeEq(int i, double valeur) {
    if (i < 0 || i >= 5) return;
    _bandes[i] = valeur.clamp(-1.0, 1.0);
    _eqProfil = 'perso';
    _eqActif = true;
    reglages.ecrireSansPrevenir('audio_eq_bandes', _bandes);
    reglages.ecrireSansPrevenir('audio_eq_profil', 'perso');
    reglages.ecrireSansPrevenir('audio_eq_actif', true);
    _appliquerEffets();
    notifyListeners();
  }

  void modifierBasses(int force) {
    _basses = force.clamp(0, 1000);
    reglages.ecrireSansPrevenir('audio_basses', _basses);
    _appliquerEffets();
    notifyListeners();
  }

  void modifierGain(double db) {
    _gain = db.clamp(0.0, 15.0);
    reglages.ecrireSansPrevenir('audio_gain', _gain);
    _appliquerEffets();
    notifyListeners();
  }

  void reinitialiserEffets() {
    _eqActif = false;
    _eqProfil = 'neutre';
    _bandes = [0.0, 0.0, 0.0, 0.0, 0.0];
    _basses = 0;
    _gain = 0.0;
    reglages.ecrireSansPrevenir('audio_eq_actif', false);
    reglages.ecrireSansPrevenir('audio_eq_profil', 'neutre');
    reglages.ecrireSansPrevenir('audio_eq_bandes', _bandes);
    reglages.ecrireSansPrevenir('audio_basses', 0);
    reglages.ecrireSansPrevenir('audio_gain', 0.0);
    _appliquerEffets();
    notifyListeners();
  }

  void _appliquerEffets() {
    Natif.effetsAudio(
      actif: _eqActif,
      bandes: _bandes,
      basses: _basses,
      gain: _gain,
    );
  }

  void _memoriserPosition() {
    final c = _ctrl;
    final t = tache;
    if (c == null || t == null || !c.value.isInitialized) return;
    final positions = Map<String, dynamic>.of((reglages['positions'] as Map?)?.cast<String, dynamic>() ?? {});
    final p = c.value.position.inMilliseconds;
    if (p > c.value.duration.inMilliseconds * 0.95) {
      positions.remove(t.id);
    } else {
      positions.remove(t.id);
      positions[t.id] = p;
    }
    while (positions.length > 300) {
      positions.remove(positions.keys.first);
    }
    reglages.ecrireSansPrevenir('positions', positions);
  }

  void _effacerPosition() {
    final t = tache;
    if (t == null) return;
    final positions = Map<String, dynamic>.of((reglages['positions'] as Map?)?.cast<String, dynamic>() ?? {});
    if (positions.remove(t.id) != null) reglages.ecrireSansPrevenir('positions', positions);
  }

  Future<void> fermer() async {
    _generation++;
    _memoriserPosition();
    _sommeil?.cancel();
    _sommeilMin = 0;
    _finSommeil = null;
    final ancien = _ctrl;
    ancien?.removeListener(_maj);
    _ctrl = null;
    _file = [];
    _index = 0;
    _erreur = null;
    _enLecture = false;
    morceauActif.value = '';
    Natif.mediaArreter();
    notifyListeners();
    await ancien?.dispose();
  }
}

final moteurAudio = MoteurAudio();

/// Ouvre le lecteur musical studio plein écran (et lance [liste] si fournie).
Future<void> ouvrirLecteurAudio(
  BuildContext context, {
  List<Tache>? liste,
  int index = 0,
  bool melanger = false,
  Duration? departPosition,
}) async {
  if (liste != null && liste.isNotEmpty) {
    final memeMorceau = moteurAudio.actif &&
        index >= 0 &&
        index < liste.length &&
        moteurAudio.tache?.id == liste[index].id &&
        !melanger;
    if (!memeMorceau) {
      unawaited(moteurAudio.ouvrir(liste, index, melanger: melanger, departPosition: departPosition));
    } else {
      if (departPosition != null) unawaited(moteurAudio.allerA(departPosition));
      if (!moteurAudio.enLecture) moteurAudio.reprendre();
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    pageBuilder: (_, _, _) => const PageLecteurAudio(),
    transitionsBuilder: (_, a, _, w) {
      final courbe = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return FadeTransition(
        opacity: courbe,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(courbe),
          child: w,
        ),
      );
    },
  ));
}

// ═══════════════════════════════════════════════════════════════════════════
// PALETTE ADAPTATIVE EXTRAITE DE LA POCHETTE
// ═══════════════════════════════════════════════════════════════════════════

typedef PaletteAudio = ({Color primaire, Color secondaire});

final _cachePalettesAudio = <String, PaletteAudio?>{};
final _requetesPalettesAudio = <String, Future<PaletteAudio?>>{};

PaletteAudio? paletteAudioEnCache(String? url) =>
    (url == null || url.isEmpty) ? null : _cachePalettesAudio[url];

void _memoriserPaletteAudio(String url, PaletteAudio? p) {
  _cachePalettesAudio.remove(url);
  _cachePalettesAudio[url] = p;
  if (_cachePalettesAudio.length > 64) {
    _cachePalettesAudio.remove(_cachePalettesAudio.keys.first);
  }
}

/// Calcule une paire de couleurs vibrantes et contrastées depuis un tampon RGBA 8 bits.
PaletteAudio? calculerPaletteAudioDepuisRgba(Uint8List rgba) {
  if (rgba.length < 4) return null;
  const bins = 18;
  final poids = List<double>.filled(bins, 0);
  final sumR = List<double>.filled(bins, 0);
  final sumG = List<double>.filled(bins, 0);
  final sumB = List<double>.filled(bins, 0);

  final totalPixels = rgba.length ~/ 4;
  final pas = max(1, totalPixels ~/ 512);

  for (var idx = 0; idx < totalPixels; idx += pas) {
    final o = idx * 4;
    final a = rgba[o + 3];
    if (a < 160) continue;
    final r = rgba[o];
    final g = rgba[o + 1];
    final b = rgba[o + 2];
    final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
    if (hsv.value < 0.16) continue;
    if (hsv.saturation < 0.12 && hsv.value > 0.86) continue;
    final w = (0.14 + hsv.saturation * 1.45) * (0.4 + 0.6 * sin(hsv.value * pi));
    final bin = ((hsv.hue / 20.0).floor()) % bins;
    poids[bin] += w;
    sumR[bin] += r * w;
    sumG[bin] += g * w;
    sumB[bin] += b * w;
  }

  var meilleur = -1;
  var maxW = 0.0;
  for (var i = 0; i < bins; i++) {
    if (poids[i] > maxW) {
      maxW = poids[i];
      meilleur = i;
    }
  }
  if (meilleur < 0 || maxW <= 0) return null;

  Color normaliserBin(int i, double minSat, double maxVal) {
    final w = poids[i];
    final c = Color.fromARGB(
      255,
      (sumR[i] / w).round().clamp(0, 255),
      (sumG[i] / w).round().clamp(0, 255),
      (sumB[i] / w).round().clamp(0, 255),
    );
    final h = HSVColor.fromColor(c);
    return h
        .withSaturation(h.saturation.clamp(minSat, 0.92))
        .withValue(h.value.clamp(0.54, maxVal))
        .toColor();
  }

  final primaire = normaliserBin(meilleur, 0.55, 0.80);

  var second = -1;
  var maxSecondW = 0.0;
  for (var i = 0; i < bins; i++) {
    final dist = min((i - meilleur).abs(), bins - (i - meilleur).abs());
    if (dist >= 2 && poids[i] > maxSecondW) {
      maxSecondW = poids[i];
      second = i;
    }
  }

  final Color secondaire;
  if (second >= 0 && maxSecondW >= maxW * 0.18) {
    secondaire = normaliserBin(second, 0.50, 0.84);
  } else {
    final h = HSVColor.fromColor(primaire);
    secondaire = h
        .withHue((h.hue + 44) % 360)
        .withSaturation((h.saturation * 0.92).clamp(0.50, 0.90))
        .withValue((h.value + 0.06).clamp(0.56, 0.84))
        .toColor();
  }
  return (primaire: primaire, secondaire: secondaire);
}

Future<PaletteAudio?> extrairePaletteMiniature(String? url) {
  if (url == null || url.isEmpty) return Future.value(null);
  if (_cachePalettesAudio.containsKey(url)) {
    return Future.value(_cachePalettesAudio[url]);
  }
  final enCours = _requetesPalettesAudio[url];
  if (enCours != null) return enCours;

  final comp = Completer<PaletteAudio?>();
  _requetesPalettesAudio[url] = comp.future;

  try {
    final flux = ResizeImage.resizeIfNeeded(24, null, miniatures.image(url))
        .resolve(ImageConfiguration.empty);
    late final ImageStreamListener ecoute;
    ecoute = ImageStreamListener(
      (info, _) async {
        flux.removeListener(ecoute);
        try {
          final octets = await info.image.toByteData(format: ImageByteFormat.rawRgba);
          final res = octets == null ? null : calculerPaletteAudioDepuisRgba(octets.buffer.asUint8List());
          _memoriserPaletteAudio(url, res);
          if (!comp.isCompleted) comp.complete(res);
        } catch (_) {
          if (!comp.isCompleted) comp.complete(null);
        } finally {
          info.dispose();
          _requetesPalettesAudio.remove(url);
        }
      },
      onError: (_, _) {
        flux.removeListener(ecoute);
        _requetesPalettesAudio.remove(url);
        if (!comp.isCompleted) comp.complete(null);
      },
    );
    flux.addListener(ecoute);
  } catch (_) {
    _requetesPalettesAudio.remove(url);
    if (!comp.isCompleted) comp.complete(null);
  }
  return comp.future;
}

class _PaletteAnimee extends StatefulWidget {
  final String? url;
  final Color defaut1;
  final Color defaut2;
  final Widget Function(BuildContext context, Color primaire, Color secondaire) builder;

  const _PaletteAnimee({
    required this.url,
    required this.defaut1,
    required this.defaut2,
    required this.builder,
  });

  @override
  State<_PaletteAnimee> createState() => _PaletteAnimeeState();
}

class _PaletteAnimeeState extends State<_PaletteAnimee> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
  late final Animation<double> _courbe =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);

  late Color _depuis1 = widget.defaut1;
  late Color _vers1 = widget.defaut1;
  late Color _depuis2 = widget.defaut2;
  late Color _vers2 = widget.defaut2;
  PaletteAudio? _extraite;

  @override
  void initState() {
    super.initState();
    _chargerPalette(widget.url, instantane: true);
  }

  @override
  void didUpdateWidget(covariant _PaletteAnimee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _chargerPalette(widget.url);
    } else if (_extraite == null &&
        (oldWidget.defaut1 != widget.defaut1 || oldWidget.defaut2 != widget.defaut2)) {
      _transitionVers(widget.defaut1, widget.defaut2);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _transitionVers(Color c1, Color c2, {bool instantane = false}) {
    final t = _courbe.value;
    _depuis1 = Color.lerp(_depuis1, _vers1, t) ?? _vers1;
    _depuis2 = Color.lerp(_depuis2, _vers2, t) ?? _vers2;
    _vers1 = c1;
    _vers2 = c2;
    if (instantane) {
      _depuis1 = c1;
      _depuis2 = c2;
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward(from: 0);
    }
  }

  void _chargerPalette(String? url, {bool instantane = false}) {
    final cache = paletteAudioEnCache(url);
    _extraite = cache;
    _transitionVers(
      cache?.primaire ?? widget.defaut1,
      cache?.secondaire ?? widget.defaut2,
      instantane: instantane,
    );
    if (cache != null || url == null || url.isEmpty) return;
    extrairePaletteMiniature(url).then((p) {
      if (!mounted || widget.url != url || p == null) return;
      _extraite = p;
      _transitionVers(p.primaire, p.secondaire);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _courbe,
      builder: (context, _) {
        final t = _courbe.value;
        final p = Color.lerp(_depuis1, _vers1, t) ?? _vers1;
        final s = Color.lerp(_depuis2, _vers2, t) ?? _vers2;
        return widget.builder(context, p, s);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MINI-LECTEUR FLOTTANT (visible en bas de l'application au-dessus des onglets)
// ═══════════════════════════════════════════════════════════════════════════

class MiniLecteurAudio extends StatefulWidget {
  const MiniLecteurAudio({super.key});
  @override
  State<MiniLecteurAudio> createState() => _MiniLecteurAudioState();
}

class _MiniLecteurAudioState extends State<MiniLecteurAudio> with SingleTickerProviderStateMixin {
  late final AnimationController _rotation =
      AnimationController(vsync: this, duration: const Duration(seconds: 12));
  double _glisseX = 0;

  @override
  void initState() {
    super.initState();
    moteurAudio.addListener(_synchroRotation);
    _synchroRotation();
  }

  @override
  void dispose() {
    moteurAudio.removeListener(_synchroRotation);
    _rotation.dispose();
    super.dispose();
  }

  void _synchroRotation() {
    if (moteurAudio.enLecture) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListenableBuilder(
      listenable: moteurAudio,
      builder: (context, _) {
        final t = moteurAudio.tache;
        if (t == null) return const SizedBox.shrink();
        final lecture = moteurAudio.enLecture;
        final prog = moteurAudio.avancement;
        final chargement = !moteurAudio.initialise && moteurAudio.erreur == null;

        return _PaletteAnimee(
          url: t.miniature,
          defaut1: c.indigo,
          defaut2: c.cyan,
          builder: (context, acc1, acc2) {
            final fondDebut = c.sombre
                ? Color.alphaBlend(acc1.withAlpha(32), const Color(0xEA121428))
                : Color.alphaBlend(acc1.withAlpha(22), const Color(0xF5FFFFFF));
            final fondFin = c.sombre
                ? Color.alphaBlend(acc2.withAlpha(22), const Color(0xEE0B0D1C))
                : Color.alphaBlend(acc2.withAlpha(18), const Color(0xECF1F3FC));

            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: GestureDetector(
                onTap: () => ouvrirLecteurAudio(context),
                onHorizontalDragUpdate: (d) {
                  setState(() => _glisseX = (_glisseX + d.delta.dx).clamp(-38.0, 38.0));
                },
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  final x = _glisseX;
                  setState(() => _glisseX = 0);
                  if (v < -240 || x < -26) {
                    moteurAudio.suivant();
                  } else if (v > 240 || x > 26) {
                    moteurAudio.precedent();
                  }
                },
                onHorizontalDragCancel: () => setState(() => _glisseX = 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [fondDebut, fondFin],
                        ),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: acc1.withAlpha(c.sombre ? 130 : 90),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(c.sombre ? 115 : 24),
                            blurRadius: 22,
                            offset: const Offset(0, 6),
                          ),
                          BoxShadow(
                            color: acc1.withAlpha(lecture ? (c.sombre ? 65 : 28) : 18),
                            blurRadius: 18,
                            spreadRadius: -3,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.translate(
                            offset: Offset(_glisseX * 0.55, 0),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                              child: Row(
                                children: [
                                  RotationTransition(
                                    turns: _rotation,
                                    child: _DisqueMiniature(
                                      url: t.miniature,
                                      taille: 44,
                                      accent: acc1,
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            if (lecture) ...[
                                              _MiniSpectre(couleur: acc1, couleur2: acc2),
                                              const SizedBox(width: 6),
                                            ],
                                            Expanded(
                                              child: Text(
                                                t.titre,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 13.5,
                                                  color: c.t1,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            if (t.chaine != null && t.chaine!.isNotEmpty) t.chaine!,
                                            if (moteurAudio.file.length > 1)
                                              '${moteurAudio.index + 1}/${moteurAudio.file.length}',
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 11.5, color: c.t2),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Précédent',
                                    icon: Icon(Icons.skip_previous_rounded, color: c.t1, size: 22),
                                    onPressed: moteurAudio.precedent,
                                  ),
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      if (chargement)
                                        SizedBox(
                                          width: 42,
                                          height: 42,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: acc2,
                                          ),
                                        ),
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [acc1, acc2],
                                          ),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: acc1.withAlpha(lecture ? 120 : 65),
                                              blurRadius: 12,
                                            ),
                                          ],
                                        ),
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          tooltip: lecture ? 'Pause' : 'Lecture',
                                          icon: Icon(
                                            lecture ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 22,
                                          ),
                                          onPressed: moteurAudio.lecturePause,
                                        ),
                                      ),
                                    ],
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Suivant',
                                    icon: Icon(Icons.skip_next_rounded, color: c.t1, size: 22),
                                    onPressed: moteurAudio.aSuivant ? moteurAudio.suivant : null,
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Arrêter',
                                    icon: Icon(Icons.close_rounded, color: c.t3, size: 19),
                                    onPressed: moteurAudio.fermer,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ClipRRect(
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(22)),
                            child: SizedBox(
                              height: 3,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColoredBox(color: c.trait),
                                  FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: prog.clamp(0.0, 1.0),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [acc1, acc2]),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DisqueMiniature extends StatelessWidget {
  final String? url;
  final double taille;
  final Color? accent;
  const _DisqueMiniature({required this.url, required this.taille, this.accent});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final teinte = accent ?? c.indigo;
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFF282C46), Color(0xFF0E101D), Color(0xFF22253A), Color(0xFF090A12)],
          stops: [0.0, 0.45, 0.75, 1.0],
        ),
        border: Border.all(color: teinte.withAlpha(115), width: 1.1),
      ),
      padding: EdgeInsets.all(taille * 0.14),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image(
                image: ResizeImage.resizeIfNeeded(160, null, miniatures.image(url!)),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(Icons.music_note_rounded, color: teinte, size: 16),
              )
            else
              ColoredBox(
                color: teinte.withAlpha(60),
                child: Icon(Icons.music_note_rounded, color: teinte, size: 16),
              ),
            Center(
              child: Container(
                width: taille * 0.16,
                height: taille * 0.16,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E1020),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white54, width: 1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniSpectre extends StatefulWidget {
  final Color couleur;
  final Color? couleur2;
  const _MiniSpectre({required this.couleur, this.couleur2});
  @override
  State<_MiniSpectre> createState() => _MiniSpectreState();
}

class _MiniSpectreState extends State<_MiniSpectre> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c2 = widget.couleur2 ?? widget.couleur;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final v = _c.value;
        return SizedBox(
          width: 14,
          height: 12,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, d) in const [(0, 0.0), (1, 0.35), (2, 0.7)])
                Container(
                  width: 3,
                  height: 3 + 9 * (0.5 + 0.5 * sin((v + d) * 2 * pi)),
                  decoration: BoxDecoration(
                    color: Color.lerp(widget.couleur, c2, i / 2) ?? widget.couleur,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LECTEUR MUSICAL PLEIN ÉCRAN — STUDIO « ONDE »
// ═══════════════════════════════════════════════════════════════════════════

class PageLecteurAudio extends StatefulWidget {
  const PageLecteurAudio({super.key});
  @override
  State<PageLecteurAudio> createState() => _PageLecteurAudioState();
}

class _PageLecteurAudioState extends State<PageLecteurAudio> with TickerProviderStateMixin {
  late final AnimationController _vinyle =
      AnimationController(vsync: this, duration: const Duration(seconds: 18));
  late final AnimationController _onde =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  late final AnimationController _aurore =
      AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat(reverse: true);

  Duration? _cibleGlisse;
  bool _reste = false;
  bool _immersion = false;
  double _glisseY = 0;
  double _glisseX = 0;
  int _panneau = 0; // 0: platine/visuel, 1: paroles synchronisées, 2: file d'attente

  @override
  void initState() {
    super.initState();
    moteurAudio.addListener(_majEtat);
    _majEtat();
  }

  @override
  void dispose() {
    moteurAudio.removeListener(_majEtat);
    _vinyle.dispose();
    _onde.dispose();
    _aurore.dispose();
    super.dispose();
  }

  void _majEtat() {
    if (!mounted) return;
    if (!moteurAudio.actif) {
      Navigator.of(context).maybePop();
      return;
    }
    if (moteurAudio.enLecture) {
      if (!_vinyle.isAnimating) _vinyle.repeat();
    } else {
      _vinyle.stop();
    }
    setState(() {});
  }

  Set<String> get _favoris => {for (final e in (reglages['favoris'] as List? ?? const [])) '$e'};

  void _basculerFavori(String id) {
    HapticFeedback.lightImpact();
    final f = _favoris;
    if (!f.remove(id)) f.add(id);
    reglages['favoris'] = f.toList();
    setState(() {});
  }

  void _onDragVerticalUpdate(DragUpdateDetails d) {
    final dy = _glisseY + d.delta.dy;
    setState(() => _glisseY = dy.clamp(0.0, 420.0));
  }

  void _onDragVerticalEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (_glisseY > 115 || v > 520) {
      Navigator.of(context).pop();
    } else if (_glisseY != 0) {
      setState(() => _glisseY = 0);
    }
  }

  String _temps(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  String _qualiteBadge(Tache t) {
    final f = t.fichierPrincipal;
    final ext = (f?.nom.split('.').last ?? t.options['format_audio'] ?? 'AUDIO').toString().toUpperCase();
    final d = t.duree ?? 0;
    if (f != null && f.taille > 0 && d > 0) {
      final kbps = ((f.taille * 8) / (d * 1000)).round();
      if (kbps > 0 && kbps < 2500) return '$ext · $kbps kbps';
    }
    return ext;
  }

  ChapitreVideo? _chapitreActif(Tache t, Duration pos) {
    if (t.chapitres.isEmpty) return null;
    final ms = pos.inMilliseconds;
    ChapitreVideo? actif;
    for (final ch in t.chapitres) {
      if (ms >= ch.debutMs) actif = ch;
    }
    return actif ?? t.chapitres.first;
  }

  (IconData, String) _infoStyle(String style) => switch (style) {
        'carte' => (Icons.crop_square_rounded, 'Pochette Glass'),
        'onde' => (Icons.blur_circular_rounded, 'Orbe Spectre'),
        _ => (Icons.album_rounded, 'Platine Vinyle'),
      };

  @override
  Widget build(BuildContext context) {
    final t = moteurAudio.tache;
    if (t == null) return const Scaffold(backgroundColor: Colors.black);
    final c = context.c;
    final estFav = _favoris.contains(t.id);
    final pos = _cibleGlisse ?? moteurAudio.position;
    final dur = moteurAudio.duree;
    final dureeMs = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);

    return _PaletteAnimee(
      url: t.miniature,
      defaut1: c.indigo,
      defaut2: c.cyan,
      builder: (context, acc1, acc2) {
        final opaciteFond = (1.0 - (_glisseY / 420.0)).clamp(0.35, 1.0);
        final rayon = _glisseY > 0 ? (_glisseY * 0.25).clamp(0.0, 28.0) : 0.0;
        final echelle = 1.0 - (_glisseY / 2400.0).clamp(0.0, 0.08);

        return AnimatedContainer(
          duration: _glisseY > 0 ? Duration.zero : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _glisseY, 0.0, 1.0)
            ..scaleByDouble(echelle, echelle, 1.0, 1.0),
          transformAlignment: Alignment.topCenter,
          child: Opacity(
            opacity: opaciteFond,
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(top: Radius.circular(rayon)),
              child: Scaffold(
                backgroundColor: const Color(0xFF060711),
                body: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragUpdate: _panneau == 0 ? _onDragVerticalUpdate : null,
                  onVerticalDragEnd: _panneau == 0 ? _onDragVerticalEnd : null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _FondPochette(
                        url: t.miniature,
                        primaire: acc1,
                        secondaire: acc2,
                        animation: _aurore,
                        enLecture: moteurAudio.enLecture,
                        immersion: _immersion,
                      ),
                      SafeArea(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final paysage = box.maxWidth > box.maxHeight && box.maxHeight < 520;
                            if (paysage) {
                              return _construirePaysage(
                                context,
                                t,
                                c,
                                acc1,
                                acc2,
                                estFav,
                                pos,
                                dur,
                                dureeMs,
                              );
                            }
                            if (_immersion) {
                              return _construireImmersion(
                                context,
                                t,
                                c,
                                acc1,
                                acc2,
                                estFav,
                                pos,
                                dur,
                                dureeMs,
                              );
                            }
                            return Column(
                              children: [
                                _barreHaut(context, t, c, acc1, acc2),
                                _selecteurMode(c, t, acc1, acc2),
                                Expanded(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 280),
                                    child: switch (_panneau) {
                                      1 => _VueParoles(
                                          key: const ValueKey('paroles'),
                                          paroles: moteurAudio.paroles,
                                          position: moteurAudio.positionParoles,
                                          primaire: acc1,
                                          secondaire: acc2,
                                          onTapLigne: (d) => moteurAudio.allerA(
                                            d - Duration(milliseconds: moteurAudio.decalageParolesMs),
                                          ),
                                          onOuvrirRecherche: () => _ouvrirRechercheParoles(context, t),
                                        ),
                                      2 => _VueFileInline(
                                          key: const ValueKey('file'),
                                          accent: acc1,
                                        ),
                                      _ => _zoneCentralePochette(t, c, acc1, acc2),
                                    },
                                  ),
                                ),
                                if (moteurAudio.spectreActif &&
                                    _panneau == 0 &&
                                    moteurAudio.stylePochette != 'onde')
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 28),
                                    child: RepaintBoundary(
                                      child: SizedBox(
                                        height: 32,
                                        child: AnimatedBuilder(
                                          animation: _onde,
                                          builder: (_, _) => CustomPaint(
                                            painter: _PeintreSpectre(
                                              phase: _onde.value,
                                              enLecture: moteurAudio.enLecture,
                                              avancement: pos.inMilliseconds / dureeMs,
                                              vitesse: moteurAudio.vitesse,
                                              couleur1: acc1,
                                              couleur2: acc2,
                                              couleur3: c.rose,
                                            ),
                                            size: Size.infinite,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(22, 6, 22, 10),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _infosTitre(context, t, c, acc1, acc2, estFav, pos),
                                      const SizedBox(height: 10),
                                      _barreProgression(c, t, acc1, acc2, pos, dur, dureeMs),
                                      const SizedBox(height: 6),
                                      _commandesPrincipales(c, acc1, acc2),
                                      const SizedBox(height: 10),
                                      _dockStudio(context, t, c, acc1, acc2),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _construireImmersion(
    BuildContext context,
    Tache t,
    Couleurs c,
    Color acc1,
    Color acc2,
    bool estFav,
    Duration pos,
    Duration dur,
    double dureeMs,
  ) {
    final afficheParoles = _panneau == 1;
    final chap = _chapitreActif(t, pos);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 2),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: acc1.withAlpha(110), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 13, color: acc2),
                    const SizedBox(width: 6),
                    Text(
                      'IMMERSION',
                      style: mono(context, taille: 10, couleur: Colors.white70),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: afficheParoles ? 'Afficher le visuel' : 'Afficher les paroles',
                icon: Icon(
                  afficheParoles ? Icons.album_rounded : Icons.lyrics_rounded,
                  color: Colors.white,
                ),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() => _panneau = afficheParoles ? 0 : 1);
                },
              ),
              IconButton(
                tooltip: 'Quitter le mode Immersion',
                icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white, size: 26),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() => _immersion = false);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: afficheParoles
                ? _VueParoles(
                    key: const ValueKey('imm_paroles'),
                    paroles: moteurAudio.paroles,
                    position: moteurAudio.positionParoles,
                    primaire: acc1,
                    secondaire: acc2,
                    onTapLigne: (d) => moteurAudio.allerA(
                      d - Duration(milliseconds: moteurAudio.decalageParolesMs),
                    ),
                    onOuvrirRecherche: () => _ouvrirRechercheParoles(context, t),
                  )
                : _zoneCentralePochette(t, c, acc1, acc2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(115),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: acc1.withAlpha(95), width: 1.1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.titre,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                [
                                  t.chaine ?? 'Artiste inconnu',
                                  if (chap != null) chap.titre,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: acc2, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: estFav ? 'Retirer des favoris' : 'Ajouter aux favoris',
                          onPressed: () => _basculerFavori(t.id),
                          icon: Icon(
                            estFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: estFav ? c.rose : Colors.white70,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _barreProgression(c, t, acc1, acc2, pos, dur, dureeMs),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: 'Précédent',
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 30),
                          onPressed: moteurAudio.precedent,
                        ),
                        GestureDetector(
                          onTap: moteurAudio.lecturePause,
                          child: Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [acc1, acc2],
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: acc1.withAlpha(110), blurRadius: 20),
                              ],
                              border: Border.all(color: Colors.white38, width: 1.2),
                            ),
                            child: Icon(
                              moteurAudio.enLecture ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Suivant',
                          icon: Icon(
                            Icons.skip_next_rounded,
                            color: moteurAudio.aSuivant ? Colors.white : Colors.white30,
                            size: 30,
                          ),
                          onPressed: moteurAudio.aSuivant ? moteurAudio.suivant : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _construirePaysage(
    BuildContext context,
    Tache t,
    Couleurs c,
    Color acc1,
    Color acc2,
    bool estFav,
    Duration pos,
    Duration dur,
    double dureeMs,
  ) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Column(
            children: [
              _barreHaut(context, t, c, acc1, acc2),
              Expanded(child: _zoneCentralePochette(t, c, acc1, acc2)),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 20, 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _selecteurMode(c, t, acc1, acc2),
                if (_panneau != 0)
                  Expanded(
                    child: _panneau == 1
                        ? _VueParoles(
                            paroles: moteurAudio.paroles,
                            position: moteurAudio.positionParoles,
                            primaire: acc1,
                            secondaire: acc2,
                            onTapLigne: (d) => moteurAudio.allerA(
                              d - Duration(milliseconds: moteurAudio.decalageParolesMs),
                            ),
                            onOuvrirRecherche: () => _ouvrirRechercheParoles(context, t),
                          )
                        : _VueFileInline(accent: acc1),
                  )
                else ...[
                  _infosTitre(context, t, c, acc1, acc2, estFav, pos),
                  _barreProgression(c, t, acc1, acc2, pos, dur, dureeMs),
                  _commandesPrincipales(c, acc1, acc2),
                  _dockStudio(context, t, c, acc1, acc2),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _barreHaut(BuildContext context, Tache t, Couleurs c, Color acc1, Color acc2) {
    final (iconeStyle, nomStyle) = _infoStyle(moteurAudio.stylePochette);
    final dspActif = moteurAudio.eqActif || moteurAudio.basses > 0 || moteurAudio.gain > 0;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _onDragVerticalUpdate,
      onVerticalDragEnd: _onDragVerticalEnd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Réduire dans le mini-lecteur',
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: moteurAudio.enLecture ? acc2 : Colors.white38,
                          boxShadow: moteurAudio.enLecture
                              ? [BoxShadow(color: acc2.withAlpha(180), blurRadius: 8)]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'ONDE STUDIO',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w800,
                          color: Colors.white.withAlpha(200),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: dspActif ? acc1.withAlpha(160) : Colors.white24,
                        width: 0.85,
                      ),
                    ),
                    child: Text(
                      [
                        _qualiteBadge(t),
                        if (t.pistes.isNotEmpty) t.pistes,
                        if (dspActif) 'DSP',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context, taille: 10, couleur: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Visuel : $nomStyle (appuyer pour changer)',
              icon: Icon(iconeStyle, color: acc2, size: 22),
              onPressed: moteurAudio.basculerStylePochette,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Mode Immersion',
              icon: const Icon(Icons.center_focus_strong_rounded, color: Colors.white70, size: 21),
              onPressed: () {
                HapticFeedback.selectionClick();
                setState(() {
                  if (_panneau == 2) _panneau = 0;
                  _immersion = true;
                });
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Plus d’options',
              icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
              onPressed: () => _ouvrirMenuPlus(context, t, acc1, acc2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selecteurMode(Couleurs c, Tache t, Color acc1, Color acc2) {
    final nbParoles = moteurAudio.paroles.where((l) => !l.estPause).length;
    final labelParoles = moteurAudio.rechercheParolesEnCours && nbParoles == 0
        ? 'Paroles…'
        : (nbParoles > 0 ? 'Paroles ($nbParoles)' : 'Paroles');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            _ongletMode(0, Icons.album_rounded, 'Studio', acc1, acc2),
            _ongletMode(1, Icons.lyrics_rounded, labelParoles, acc1, acc2),
            _ongletMode(2, Icons.queue_music_rounded, 'File (${moteurAudio.file.length})', acc1, acc2),
          ],
        ),
      ),
    );
  }

  Widget _ongletMode(int idx, IconData icone, String label, Color acc1, Color acc2) {
    final actif = _panneau == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _panneau = idx);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            gradient: actif ? LinearGradient(colors: [acc1, acc2]) : null,
            borderRadius: BorderRadius.circular(15),
            boxShadow: actif
                ? [BoxShadow(color: acc1.withAlpha(90), blurRadius: 10, spreadRadius: -2)]
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icone, size: 14, color: actif ? Colors.white : Colors.white70),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
                    color: actif ? Colors.white : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _zoneCentralePochette(Tache t, Couleurs c, Color acc1, Color acc2) {
    if (moteurAudio.erreur != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: c.rouge, size: 46),
              const SizedBox(height: 12),
              Text(
                moteurAudio.erreur!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              if (t.fichierPrincipal != null)
                FilledButton.icon(
                  onPressed: () => Natif.ouvrir(t.fichierPrincipal!.uri, t.fichierPrincipal!.mime),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Ouvrir avec une autre application'),
                ),
            ],
          ),
        ),
      );
    }

    final pistePeek = _glisseX < -24
        ? moteurAudio.tacheSuivante
        : (_glisseX > 24 ? moteurAudio.tachePrecedente : null);
    final normSwipe = (_glisseX / 150.0).clamp(-1.0, 1.0);
    final matrice = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..translateByDouble(_glisseX * 0.6, 0.0, 0.0, 1.0)
      ..rotateY(-normSwipe * 0.16)
      ..scaleByDouble(1.0 - normSwipe.abs() * 0.08, 1.0 - normSwipe.abs() * 0.08, 1.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: moteurAudio.lecturePause,
      onHorizontalDragUpdate: (d) {
        setState(() => _glisseX = (_glisseX + d.delta.dx).clamp(-150.0, 150.0));
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        final x = _glisseX;
        setState(() => _glisseX = 0);
        if (x < -68 || v < -320) {
          moteurAudio.suivant();
        } else if (x > 68 || v > 320) {
          moteurAudio.precedent();
        }
      },
      onHorizontalDragCancel: () => setState(() => _glisseX = 0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: LayoutBuilder(
              builder: (context, box) {
                final cote = (min(box.maxWidth, box.maxHeight) - 28).clamp(110.0, 340.0);
                final Widget visuel = switch (moteurAudio.stylePochette) {
                  'carte' => _PochetteGlass(
                      url: t.miniature,
                      cote: cote,
                      enLecture: moteurAudio.enLecture,
                      primaire: acc1,
                      secondaire: acc2,
                    ),
                  'onde' => _OrbeSpectre(
                      url: t.miniature,
                      cote: cote,
                      phase: _onde,
                      enLecture: moteurAudio.enLecture,
                      vitesse: moteurAudio.vitesse,
                      primaire: acc1,
                      secondaire: acc2,
                    ),
                  _ => _PlatineVinyle(
                      url: t.miniature,
                      cote: cote,
                      rotation: _vinyle,
                      onde: _onde,
                      enLecture: moteurAudio.enLecture,
                      primaire: acc1,
                      secondaire: acc2,
                    ),
                };

                return Transform(
                  alignment: Alignment.center,
                  transform: matrice,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: visuel,
                  ),
                );
              },
            ),
          ),
          if (pistePeek != null)
            Positioned(
              bottom: 12,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 260),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(175),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: acc1.withAlpha(150)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_glisseX > 0) ...[
                      Icon(Icons.skip_previous_rounded, size: 15, color: acc2),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        pistePeek.titre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (_glisseX < 0) ...[
                      const SizedBox(width: 5),
                      Icon(Icons.skip_next_rounded, size: 15, color: acc2),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infosTitre(
    BuildContext context,
    Tache t,
    Couleurs c,
    Color acc1,
    Color acc2,
    bool estFav,
    Duration pos,
  ) {
    final apercu = _panneau == 0 ? _apercuParoleEnDirect(acc1, acc2) : null;
    final chap = _chapitreActif(t, pos);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (apercu != null) ...[
          apercu,
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.titre,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.chaine ?? 'Artiste inconnu',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: acc2,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (chap != null) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _ouvrirChapitres(context, t, acc1, acc2),
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 165),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: acc1.withAlpha(42),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: acc1.withAlpha(110), width: 0.8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bookmarks_rounded, size: 11, color: acc2),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    chap.titre,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: estFav ? 'Retirer des favoris' : 'Ajouter aux favoris',
              onPressed: () => _basculerFavori(t.id),
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (w, a) => ScaleTransition(scale: a, child: w),
                child: Icon(
                  estFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  key: ValueKey(estFav),
                  color: estFav ? c.rose : Colors.white70,
                  size: 26,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget? _apercuParoleEnDirect(Color acc1, Color acc2) {
    final paroles = moteurAudio.paroles;
    if (paroles.isEmpty) return null;
    final pos = moteurAudio.positionParoles;
    LigneParole? active;
    for (var i = 0; i < paroles.length; i++) {
      final l = paroles[i];
      if (pos >= l.debut) active = l;
    }
    if (active == null || active.estPause || active.texte.trim().isEmpty) return null;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _panneau = 1);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [acc1.withAlpha(38), Colors.white.withAlpha(14)],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: acc1.withAlpha(110), width: 0.9),
        ),
        child: Row(
          children: [
            Icon(Icons.lyrics_rounded, size: 15, color: acc2),
            const SizedBox(width: 8),
            Expanded(
              child: active.mots.isNotEmpty
                  ? Text.rich(
                      TextSpan(
                        children: [
                          for (var i = 0; i < active.mots.length; i++)
                            TextSpan(
                              text: '${active.mots[i].texte}${i < active.mots.length - 1 ? ' ' : ''}',
                              style: TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                fontSize: 12.5,
                                fontWeight: pos >= active.mots[i].debut ? FontWeight.w800 : FontWeight.w600,
                                color: (pos >= active.mots[i].debut && pos <= active.mots[i].fin)
                                    ? acc2
                                    : (pos > active.mots[i].fin ? Colors.white : Colors.white60),
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : Text(
                      active.texte,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white54),
          ],
        ),
      ),
    );
  }

  void _ouvrirRechercheParoles(BuildContext context, Tache t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FeuilleRechercheParoles(tache: t),
    );
  }

  Widget _barreProgression(
    Couleurs c,
    Tache t,
    Color acc1,
    Color acc2,
    Duration pos,
    Duration dur,
    double dureeMs,
  ) {
    final a = moteurAudio.pointA;
    final b = moteurAudio.pointB;
    final enGlisse = _cibleGlisse != null;

    return Column(
      children: [
        if (enGlisse)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(170),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: acc2.withAlpha(150)),
              ),
              child: Text(
                _temps(pos),
                style: mono(context, taille: 12, couleur: Colors.white),
              ),
            ),
          ),
        SizedBox(
          height: 30,
          child: LayoutBuilder(
            builder: (ctx, box) {
              final l = box.maxWidth;
              double x(Duration d) => 12 + (d.inMilliseconds / dureeMs).clamp(0.0, 1.0) * (l - 24);
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (a != null && b != null)
                    Positioned(
                      left: min(x(a), x(b)),
                      width: max(4.0, (x(b) - x(a)).abs()),
                      child: IgnorePointer(
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: c.ambre.withAlpha(110),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  for (final ch in t.chapitres)
                    if (ch.debutMs > 0)
                      Positioned(
                        left: x(Duration(milliseconds: ch.debutMs)) - 1,
                        child: IgnorePointer(
                          child: Container(
                            width: 2,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Colors.white54,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: enGlisse ? 6 : 4.5,
                      trackShape: _PisteProgressionDegradee(acc1, acc2),
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: enGlisse ? 9 : 6.5),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: acc1,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: acc1.withAlpha(65),
                    ),
                    child: Slider(
                      min: 0,
                      max: dureeMs,
                      value: pos.inMilliseconds.toDouble().clamp(0.0, dureeMs),
                      onChanged: (v) => setState(() => _cibleGlisse = Duration(milliseconds: v.round())),
                      onChangeEnd: (v) {
                        moteurAudio.allerA(Duration(milliseconds: v.round()));
                        setState(() => _cibleGlisse = null);
                      },
                    ),
                  ),
                  if (a != null)
                    Positioned(
                      left: x(a),
                      child: IgnorePointer(
                        child: Container(
                          width: 3,
                          height: 14,
                          decoration: BoxDecoration(color: c.ambre, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ),
                  if (b != null)
                    Positioned(
                      left: x(b),
                      child: IgnorePointer(
                        child: Container(
                          width: 3,
                          height: 14,
                          decoration: BoxDecoration(color: c.ambre, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_temps(pos), style: mono(context, taille: 11.5, couleur: Colors.white70)),
              if (a != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: c.ambre.withAlpha(40),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    b != null ? 'Boucle ${_temps(a)} → ${_temps(b)}' : 'Point A : ${_temps(a)}',
                    style: mono(context, taille: 10, couleur: c.ambre),
                  ),
                ),
              GestureDetector(
                onTap: () => setState(() => _reste = !_reste),
                child: Text(
                  _reste ? '−${_temps(dur - pos)}' : _temps(dur),
                  style: mono(context, taille: 11.5, couleur: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _commandesPrincipales(Couleurs c, Color acc1, Color acc2) {
    final lecture = moteurAudio.enLecture;
    final rep = moteurAudio.repetition;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Lecture aléatoire',
              onPressed: moteurAudio.basculerAleatoire,
              icon: Icon(
                Icons.shuffle_rounded,
                color: moteurAudio.aleatoire ? acc2 : Colors.white54,
                size: 23,
              ),
            ),
            if (moteurAudio.aleatoire)
              Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: acc2)),
          ],
        ),
        IconButton(
          tooltip: 'Précédent',
          onPressed: moteurAudio.precedent,
          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 34),
        ),
        IconButton(
          tooltip: 'Reculer de 10 s',
          onPressed: () => moteurAudio.sauterSecondes(-10),
          icon: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 26),
        ),
        GestureDetector(
          onTap: moteurAudio.lecturePause,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [acc1, acc2],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: acc1.withAlpha(lecture ? 150 : 75),
                  blurRadius: lecture ? 30 : 16,
                  spreadRadius: lecture ? 3 : 0,
                ),
                BoxShadow(
                  color: acc2.withAlpha(lecture ? 85 : 30),
                  blurRadius: lecture ? 20 : 10,
                ),
              ],
              border: Border.all(color: Colors.white54, width: 1.4),
            ),
            child: Icon(
              lecture ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 40,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Avancer de 10 s',
          onPressed: () => moteurAudio.sauterSecondes(10),
          icon: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 26),
        ),
        IconButton(
          tooltip: 'Suivant',
          onPressed: moteurAudio.aSuivant ? moteurAudio.suivant : null,
          icon: Icon(
            Icons.skip_next_rounded,
            color: moteurAudio.aSuivant ? Colors.white : Colors.white30,
            size: 34,
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: switch (rep) {
                1 => 'Répéter la file',
                2 => 'Répéter ce titre',
                _ => 'Répétition désactivée',
              },
              onPressed: moteurAudio.basculerRepetition,
              icon: Icon(
                rep == 2 ? Icons.repeat_one_on_rounded : (rep == 1 ? Icons.repeat_on_rounded : Icons.repeat_rounded),
                color: rep != 0 ? acc2 : Colors.white54,
                size: 23,
              ),
            ),
            if (rep != 0)
              Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: acc2)),
          ],
        ),
      ],
    );
  }

  Widget _dockStudio(BuildContext context, Tache t, Couleurs c, Color acc1, Color acc2) {
    final eqActif = moteurAudio.eqActif || moteurAudio.basses > 0 || moteurAudio.gain > 0;
    final som = moteurAudio.sommeilMin > 0;
    final vit = moteurAudio.vitesse != 1.0;
    final ab = moteurAudio.pointA != null;

    Widget boutonDock({
      required IconData icone,
      required String label,
      required VoidCallback onTap,
      bool actif = false,
    }) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: actif
                ? BoxDecoration(
                    color: acc1.withAlpha(42),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: acc1.withAlpha(110), width: 0.8),
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icone, size: 19, color: actif ? acc2 : Colors.white70),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
                    color: actif ? Colors.white : Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(16),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          boutonDock(
            icone: Icons.equalizer_rounded,
            label: eqActif ? 'Studio ON' : 'Studio EQ',
            actif: eqActif,
            onTap: () => _ouvrirEgaliseur(context, acc1, acc2),
          ),
          boutonDock(
            icone: Icons.speed_rounded,
            label: vit ? '${moteurAudio.vitesse.toString().replaceAll('.0', '')}×' : 'Vitesse',
            actif: vit,
            onTap: () => _ouvrirVitesse(context, acc1),
          ),
          boutonDock(
            icone: Icons.repeat_rounded,
            label: ab ? (moteurAudio.pointB != null ? 'A-B actif' : 'Point B…') : 'Boucle A-B',
            actif: ab,
            onTap: moteurAudio.basculerBoucleAB,
          ),
          boutonDock(
            icone: Icons.bedtime_rounded,
            label: som ? '${moteurAudio.minutesSommeilRestantes} min' : 'Sommeil',
            actif: som,
            onTap: () => _ouvrirSommeil(context, acc1),
          ),
          if (moteurAudio.pistes.length > 1)
            boutonDock(
              icone: Icons.translate_rounded,
              label: 'Piste',
              onTap: () => _ouvrirPistes(context, acc1),
            )
          else
            boutonDock(
              icone: Icons.share_rounded,
              label: 'Partager',
              onTap: () {
                final f = t.fichierPrincipal;
                if (f != null) Natif.partager(f.uri, f.mime);
              },
            ),
        ],
      ),
    );
  }

  // ── Feuilles modales Studio ──────────────────────────────────────────

  Future<void> _feuille(
    BuildContext context,
    Color bordureAccent,
    Widget Function(BuildContext, StateSetter) builder,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
            decoration: BoxDecoration(
              color: const Color(0xF0101326),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(color: bordureAccent.withAlpha(120), width: 1.2),
              ),
            ),
            child: SafeArea(
              top: false,
              child: StatefulBuilder(builder: builder),
            ),
          ),
        ),
      ),
    );
  }

  void _ouvrirChapitres(BuildContext context, Tache t, Color acc1, Color acc2) {
    _feuille(context, acc1, (ctx, _) {
      final posMs = moteurAudio.position.inMilliseconds;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                Icon(Icons.bookmarks_rounded, color: acc2, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Chapitres (${t.chapitres.length})',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: t.chapitres.length,
                itemBuilder: (_, i) {
                  final ch = t.chapitres[i];
                  final courant = posMs >= ch.debutMs && (ch.finMs <= ch.debutMs || posMs < ch.finMs);
                  return ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    tileColor: courant ? acc1.withAlpha(55) : null,
                    leading: Text(
                      _temps(Duration(milliseconds: ch.debutMs)),
                      style: mono(context, taille: 12, couleur: courant ? acc2 : Colors.white60),
                    ),
                    title: Text(
                      ch.titre,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: courant ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    trailing: courant ? Icon(Icons.graphic_eq_rounded, color: acc2, size: 18) : null,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      moteurAudio.allerA(Duration(milliseconds: ch.debutMs));
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
    });
  }

  void _ouvrirEgaliseur(BuildContext context, Color acc1, Color acc2) {
    _feuille(context, acc1, (ctx, maj) {
      final c = context.c;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                Icon(Icons.equalizer_rounded, color: acc2),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Studio Audio & Égaliseur',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    moteurAudio.reinitialiserEffets();
                    maj(() {});
                  },
                  child: const Text('Réinitialiser'),
                ),
                Switch(
                  value: moteurAudio.eqActif,
                  onChanged: (v) {
                    moteurAudio.basculerEgaliseur(v);
                    maj(() {});
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 68,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(10),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: acc1.withAlpha(moteurAudio.eqActif ? 105 : 40)),
              ),
              child: CustomPaint(
                painter: _PeintreCourbeEq(
                  bandes: moteurAudio.bandes,
                  actif: moteurAudio.eqActif,
                  couleur1: acc1,
                  couleur2: acc2,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in profilsEgaliseur.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: Icon(e.value.$2, size: 16, color: moteurAudio.eqProfil == e.key ? Colors.white : Colors.white70),
                        label: Text(e.value.$1),
                        selected: moteurAudio.eqProfil == e.key && moteurAudio.eqActif,
                        selectedColor: acc1,
                        backgroundColor: Colors.white10,
                        labelStyle: TextStyle(
                          color: Colors.white,
                          fontWeight: moteurAudio.eqProfil == e.key ? FontWeight.w700 : FontWeight.w500,
                        ),
                        onSelected: (_) {
                          moteurAudio.choisirProfilEq(e.key);
                          maj(() {});
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 185,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 5; i++)
                    Column(
                      children: [
                        Text(
                          '${moteurAudio.bandes[i] >= 0 ? '+' : ''}${(moteurAudio.bandes[i] * 12).round()} dB',
                          style: mono(context, taille: 10.5, couleur: acc2),
                        ),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                activeTrackColor: acc1,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                min: -1.0,
                                max: 1.0,
                                value: moteurAudio.bandes[i],
                                onChanged: (v) {
                                  moteurAudio.modifierBandeEq(i, v);
                                  maj(() {});
                                },
                              ),
                            ),
                          ),
                        ),
                        Text(frequencesBandes[i], style: mono(context, taille: 10.5, couleur: Colors.white70)),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.speaker_rounded, color: acc2, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Renforcement des basses (Bass Boost)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
                Text('${(moteurAudio.basses / 10).round()} %', style: mono(context, taille: 12, couleur: acc2)),
              ],
            ),
            Slider(
              min: 0,
              max: 1000,
              value: moteurAudio.basses.toDouble(),
              activeColor: acc2,
              inactiveColor: Colors.white24,
              onChanged: (v) {
                moteurAudio.modifierBasses(v.round());
                maj(() {});
              },
            ),
            Row(
              children: [
                Icon(Icons.bolt_rounded, color: c.ambre, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Amplificateur de volume (Gain)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
                Text('+${moteurAudio.gain.toStringAsFixed(1)} dB', style: mono(context, taille: 12, couleur: c.ambre)),
              ],
            ),
            Slider(
              min: 0,
              max: 15,
              divisions: 30,
              value: moteurAudio.gain,
              activeColor: c.ambre,
              inactiveColor: Colors.white24,
              onChanged: (v) {
                moteurAudio.modifierGain(v);
                maj(() {});
              },
            ),
          ],
        ),
      );
    });
  }

  void _ouvrirVitesse(BuildContext context, Color acc1) {
    _feuille(context, acc1, (ctx, maj) {
      final v = moteurAudio.vitesse;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const Text('Vitesse & Tempo', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 10),
            Text(
              '${v.toStringAsFixed(2).replaceAll('.00', '').replaceAll('.', ',')}×',
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            Slider(
              min: 0.5,
              max: 2.5,
              divisions: 40,
              value: v.clamp(0.5, 2.5),
              activeColor: acc1,
              onChanged: (x) {
                moteurAudio.changerVitesse(x);
                maj(() {});
              },
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in const [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0])
                  ChoiceChip(
                    label: Text(p == 1.0 ? 'Normale (1×)' : '${p.toString().replaceAll('.', ',')}×'),
                    selected: (v - p).abs() < 0.01,
                    selectedColor: acc1,
                    backgroundColor: Colors.white10,
                    labelStyle: const TextStyle(color: Colors.white),
                    onSelected: (_) {
                      moteurAudio.changerVitesse(p);
                      maj(() {});
                    },
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }

  void _ouvrirSommeil(BuildContext context, Color acc1) {
    _feuille(context, acc1, (ctx, _) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            ),
            const Text('Minuteur de sommeil', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 10),
            for (final m in const [0, 10, 20, 30, 45, 60, 90])
              ListTile(
                leading: Icon(m == 0 ? Icons.timer_off_outlined : Icons.bedtime_rounded, color: m == moteurAudio.sommeilMin ? acc1 : Colors.white70),
                title: Text(m == 0 ? 'Désactivé' : 'Arrêter dans $m minutes', style: const TextStyle(color: Colors.white)),
                trailing: m == moteurAudio.sommeilMin ? Icon(Icons.check_rounded, color: acc1) : null,
                onTap: () {
                  moteurAudio.programmerSommeil(m);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    });
  }

  void _ouvrirPistes(BuildContext context, Color acc1) {
    _feuille(context, acc1, (ctx, _) {
      final pistes = moteurAudio.pistes;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            ),
            const Text('Piste audio', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
            const SizedBox(height: 8),
            for (var i = 0; i < pistes.length; i++)
              ListTile(
                title: Text(
                  [
                    if (pistes[i].language != null && pistes[i].language != 'und')
                      '${langues.drapeau(pistes[i].language!)} ${langues.nom(pistes[i].language!)}'
                    else
                      'Piste ${i + 1}',
                    if (pistes[i].label != null && pistes[i].label!.isNotEmpty) pistes[i].label!,
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: pistes[i].isSelected ? Icon(Icons.check_rounded, color: acc1) : null,
                onTap: () {
                  moteurAudio.choisirPisteAudio(pistes[i].id);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      );
    });
  }

  void _ouvrirMenuPlus(BuildContext context, Tache t, Color acc1, Color acc2) {
    _feuille(context, acc1, (ctx, maj) {
      final c = context.c;
      final f = t.fichierPrincipal;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Visuel du studio',
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in const [
                    ('vinyle', Icons.album_rounded, 'Vinyle'),
                    ('carte', Icons.crop_square_rounded, 'Pochette'),
                    ('onde', Icons.blur_circular_rounded, 'Orbe 360°'),
                  ])
                    ChoiceChip(
                      avatar: Icon(s.$2, size: 16, color: Colors.white),
                      label: Text(s.$3),
                      selected: moteurAudio.stylePochette == s.$1,
                      selectedColor: acc1,
                      backgroundColor: Colors.white10,
                      labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      onSelected: (_) {
                        moteurAudio.choisirStylePochette(s.$1);
                        maj(() {});
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              secondary: Icon(Icons.waves_rounded, color: acc2),
              title: const Text('Spectre lumineux animé', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('Onde audio synchronisée sous la platine', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: moteurAudio.spectreActif,
              onChanged: (_) {
                moteurAudio.basculerSpectre();
                maj(() {});
              },
            ),
            ListTile(
              leading: Icon(Icons.center_focus_strong_rounded, color: acc1),
              title: const Text('Mode Immersion totale', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Masque les barres pour mettre en avant l’œuvre et les paroles', style: TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  if (_panneau == 2) _panneau = 0;
                  _immersion = true;
                });
              },
            ),
            if (t.chapitres.isNotEmpty)
              ListTile(
                leading: Icon(Icons.bookmarks_rounded, color: acc2),
                title: Text('Chapitres (${t.chapitres.length})', style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _ouvrirChapitres(context, t, acc1, acc2);
                },
              ),
            if (f != null) ...[
              ListTile(
                leading: Icon(Icons.share_rounded, color: c.vert),
                title: const Text('Partager le fichier audio', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Natif.partager(f.uri, f.mime);
                },
              ),
              ListTile(
                leading: Icon(Icons.open_in_new_rounded, color: c.bleu),
                title: const Text('Ouvrir avec une autre application', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Natif.ouvrir(f.uri, f.mime);
                },
              ),
            ],
            if (t.url.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.smart_display_rounded, color: Color(0xFFFF0000)),
                title: const Text('Voir sur YouTube', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Natif.ouvrirLien(t.url);
                },
              ),
            const Divider(color: Colors.white12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                '${f?.nom ?? t.titre}\n${formaterTaille(t.tailleFichier)} · ${_qualiteBadge(t)}',
                style: mono(context, taille: 11, couleur: Colors.white54),
              ),
            ),
          ],
        ),
      );
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPOSANTS VISUELS DU STUDIO : PLATINE VINYLE, FOND, SPECTRE, PAROLES, FILE
// ═══════════════════════════════════════════════════════════════════════════

class _FondPochette extends StatelessWidget {
  final String? url;
  final Color primaire;
  final Color secondaire;
  final Animation<double> animation;
  final bool enLecture;
  final bool immersion;

  const _FondPochette({
    required this.url,
    required this.primaire,
    required this.secondaire,
    required this.animation,
    required this.enLecture,
    this.immersion = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF060711)),
        if (url != null)
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 520),
              child: SizedBox.expand(
                key: ValueKey(url),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 54, sigmaY: 54),
                  child: Opacity(
                    opacity: immersion ? 0.50 : 0.38,
                    child: Image(
                      image: ResizeImage(miniatures.image(url!), width: 200),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: animation,
            builder: (_, _) => CustomPaint(
              painter: _PeintreAuroreAmbiante(
                phase: animation.value,
                primaire: primaire,
                secondaire: secondaire,
                enLecture: enLecture,
                immersion: immersion,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.08,
              colors: [
                Colors.transparent,
                const Color(0x88060711),
                const Color(0xED060711),
              ],
              stops: const [0.32, 0.76, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _PeintreAuroreAmbiante extends CustomPainter {
  final double phase;
  final Color primaire;
  final Color secondaire;
  final bool enLecture;
  final bool immersion;

  _PeintreAuroreAmbiante({
    required this.phase,
    required this.primaire,
    required this.secondaire,
    required this.enLecture,
    required this.immersion,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final t = phase * pi;
    final intensite = (enLecture ? 1.0 : 0.62) * (immersion ? 1.15 : 1.0);

    void orb(Offset centre, double rayon, Color couleur, double alpha) {
      final rect = Rect.fromCircle(center: centre, radius: rayon);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            couleur.withAlpha((alpha * intensite).round().clamp(0, 255)),
            couleur.withAlpha((alpha * 0.25 * intensite).round().clamp(0, 255)),
            Colors.transparent,
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(rect);
      canvas.drawCircle(centre, rayon, paint);
    }

    final diag = max(size.width, size.height);
    orb(
      Offset(size.width * (0.24 + 0.16 * sin(t)), size.height * (0.26 + 0.10 * cos(t))),
      diag * 0.46,
      primaire,
      115,
    );
    orb(
      Offset(size.width * (0.78 - 0.18 * sin(t)), size.height * (0.64 - 0.12 * cos(t))),
      diag * 0.44,
      secondaire,
      100,
    );
  }

  @override
  bool shouldRepaint(covariant _PeintreAuroreAmbiante old) =>
      old.phase != phase ||
      old.primaire != primaire ||
      old.secondaire != secondaire ||
      old.enLecture != enLecture ||
      old.immersion != immersion;
}

class _PochetteGlass extends StatelessWidget {
  final String? url;
  final double cote;
  final bool enLecture;
  final Color primaire;
  final Color secondaire;

  const _PochetteGlass({
    required this.url,
    required this.cote,
    required this.enLecture,
    required this.primaire,
    required this.secondaire,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: enLecture ? 1.0 : 0.93,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutBack,
      child: Container(
        width: cote,
        height: cote,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: primaire.withAlpha(enLecture ? 125 : 45),
              blurRadius: enLecture ? 48 : 24,
              offset: const Offset(-10, -8),
            ),
            BoxShadow(
              color: secondaire.withAlpha(enLecture ? 95 : 30),
              blurRadius: enLecture ? 44 : 20,
              offset: const Offset(10, 12),
            ),
            const BoxShadow(color: Colors.black87, blurRadius: 32, offset: Offset(0, 18)),
          ],
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withAlpha(85),
              primaire.withAlpha(65),
              Colors.white.withAlpha(25),
            ],
          ),
        ),
        padding: const EdgeInsets.all(1.6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26.5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url != null)
                Image(
                  image: miniatures.image(url!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _secours(),
                )
              else
                _secours(),
              // Reflet vitré diagonal fixe en coin supérieur gauche
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: const Alignment(0.2, 0.45),
                      colors: [
                        Colors.white.withAlpha(50),
                        Colors.white.withAlpha(10),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _secours() => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [primaire.withAlpha(130), const Color(0xFF12152E)],
          ),
        ),
        child: const Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: 72)),
      );
}

class _OrbeSpectre extends StatelessWidget {
  final String? url;
  final double cote;
  final Animation<double> phase;
  final bool enLecture;
  final double vitesse;
  final Color primaire;
  final Color secondaire;

  const _OrbeSpectre({
    required this.url,
    required this.cote,
    required this.phase,
    required this.enLecture,
    required this.vitesse,
    required this.primaire,
    required this.secondaire,
  });

  @override
  Widget build(BuildContext context) {
    final diametreCoeur = cote * 0.62;
    return SizedBox(
      width: cote,
      height: cote,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: phase,
              builder: (_, _) => CustomPaint(
                size: Size(cote, cote),
                painter: _PeintreSpectreRadial(
                  phase: phase.value,
                  enLecture: enLecture,
                  vitesse: vitesse,
                  primaire: primaire,
                  secondaire: secondaire,
                ),
              ),
            ),
          ),
          AnimatedScale(
            scale: enLecture ? 1.0 : 0.93,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutBack,
            child: Container(
              width: diametreCoeur,
              height: diametreCoeur,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: primaire.withAlpha(enLecture ? 130 : 50),
                    blurRadius: 34,
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: secondaire.withAlpha(enLecture ? 85 : 30),
                    blurRadius: 22,
                  ),
                ],
                gradient: SweepGradient(colors: [primaire, secondaire, primaire]),
              ),
              padding: const EdgeInsets.all(2.4),
              child: ClipOval(
                child: url != null
                    ? Image(
                        image: miniatures.image(url!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _secours(),
                      )
                    : _secours(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _secours() => ColoredBox(
        color: primaire.withAlpha(95),
        child: const Center(child: Icon(Icons.music_note_rounded, color: Colors.white, size: 54)),
      );
}

class _PeintreSpectreRadial extends CustomPainter {
  final double phase;
  final bool enLecture;
  final double vitesse;
  final Color primaire;
  final Color secondaire;

  _PeintreSpectreRadial({
    required this.phase,
    required this.enLecture,
    required this.vitesse,
    required this.primaire,
    required this.secondaire,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const nb = 64;
    final centre = Offset(size.width / 2, size.height / 2);
    final rBase = size.width * 0.34;
    final maxAmp = size.width * 0.145;
    final t = phase * 2 * pi * vitesse.clamp(0.6, 1.8);

    // Anneaux orbitaux subtils
    canvas.drawCircle(
      centre,
      rBase * 0.98,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withAlpha(32),
    );
    canvas.drawCircle(
      centre,
      rBase + maxAmp * 0.72,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = secondaire.withAlpha(enLecture ? 42 : 16),
    );

    final barrePaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (size.width / 105).clamp(2.2, 4.2);

    for (var i = 0; i < nb; i++) {
      final frac = i / nb;
      final angle = frac * 2 * pi - pi / 2;
      final onde = enLecture
          ? (0.24 +
                  0.76 *
                      (0.45 +
                          0.30 * sin(t * 2 + i * 0.45) +
                          0.25 * cos(t * 3 - i * 0.75)))
              .clamp(0.16, 1.0)
          : 0.14;
      final rExt = rBase + maxAmp * onde;
      final cosA = cos(angle);
      final sinA = sin(angle);
      final p1 = Offset(centre.dx + rBase * cosA, centre.dy + rBase * sinA);
      final p2 = Offset(centre.dx + rExt * cosA, centre.dy + rExt * sinA);

      final mix = (sin(frac * 2 * pi) + 1) * 0.5;
      barrePaint.color = (Color.lerp(primaire, secondaire, mix) ?? primaire)
          .withAlpha(enLecture ? 225 : 95);
      canvas.drawLine(p1, p2, barrePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PeintreSpectreRadial old) =>
      old.phase != phase ||
      old.enLecture != enLecture ||
      old.vitesse != vitesse ||
      old.primaire != primaire ||
      old.secondaire != secondaire;
}

class _PlatineVinyle extends StatelessWidget {
  final String? url;
  final double cote;
  final Animation<double> rotation;
  final Animation<double> onde;
  final bool enLecture;
  final Color primaire;
  final Color secondaire;

  const _PlatineVinyle({
    required this.url,
    required this.cote,
    required this.rotation,
    required this.onde,
    required this.enLecture,
    required this.primaire,
    required this.secondaire,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cote + 28,
      height: cote + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo respirant synchronisé sur la lecture
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: onde,
              builder: (_, _) {
                final resp = enLecture ? 0.5 + 0.5 * sin(onde.value * 2 * pi) : 0.0;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 420),
                  width: cote * (enLecture ? 0.94 + resp * 0.06 : 0.82),
                  height: cote * (enLecture ? 0.94 + resp * 0.06 : 0.82),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: primaire.withAlpha(enLecture ? (100 + (resp * 35).round()) : 40),
                        blurRadius: enLecture ? 54 : 24,
                        spreadRadius: enLecture ? 6 : 0,
                      ),
                      BoxShadow(
                        color: secondaire.withAlpha(enLecture ? 65 : 18),
                        blurRadius: enLecture ? 40 : 18,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // Disque vinyle tournant avec sillons
          RotationTransition(
            turns: rotation,
            child: Container(
              width: cote,
              height: cote,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(color: Colors.black87, blurRadius: 28, offset: Offset(0, 14)),
                ],
                gradient: const RadialGradient(
                  colors: [
                    Color(0xFF141625),
                    Color(0xFF0A0B14),
                    Color(0xFF1B1F34),
                    Color(0xFF080910),
                  ],
                  stops: [0.0, 0.56, 0.78, 1.0],
                ),
                border: Border.all(color: Colors.white24, width: 1.5),
              ),
              child: CustomPaint(
                painter: _PeintreSillons(),
                child: Center(
                  child: Container(
                    width: cote * 0.56,
                    height: cote * 0.56,
                    padding: const EdgeInsets.all(2.2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [primaire, secondaire],
                      ),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
                    ),
                    child: ClipOval(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (url != null)
                            Image(
                              image: miniatures.image(url!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: primaire.withAlpha(80),
                                child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 48),
                              ),
                            )
                          else
                            ColoredBox(
                              color: primaire.withAlpha(80),
                              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 48),
                            ),
                          // Trou central & broche métallique du vinyle
                          Center(
                            child: Container(
                              width: cote * 0.085,
                              height: cote * 0.085,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A0B14),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white70, width: 1.6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Reflet spéculaire fixe sur le vinyle (ne tourne pas avec le disque)
          IgnorePointer(
            child: Container(
              width: cote,
              height: cote,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    Colors.white.withAlpha(24),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.white.withAlpha(20),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.white.withAlpha(24),
                  ],
                ),
              ),
            ),
          ),
          // Bras de lecture (tonearm) qui se pose sur le disque quand ça joue
          Positioned(
            top: 4,
            right: 2,
            child: IgnorePointer(
              child: AnimatedRotation(
                turns: enLecture ? 0.0 : -0.078,
                alignment: const Alignment(0.65, -0.75),
                duration: const Duration(milliseconds: 440),
                curve: Curves.easeOutBack,
                child: SizedBox(
                  width: cote * 0.28,
                  height: cote * 0.48,
                  child: CustomPaint(painter: _PeintreBras(primaire, secondaire, enLecture)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeintreSillons extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final rMax = size.width / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.white.withAlpha(20);
    for (double f = 0.60; f < 0.96; f += 0.04) {
      canvas.drawCircle(c, rMax * f, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PeintreBras extends CustomPainter {
  final Color primaire;
  final Color secondaire;
  final bool enLecture;

  _PeintreBras(this.primaire, this.secondaire, this.enLecture);

  @override
  void paint(Canvas canvas, Size size) {
    final haut = Offset(size.width * 0.82, size.height * 0.04);
    final pivot = Offset(size.width * 0.76, size.height * 0.16);
    final coude = Offset(size.width * 0.62, size.height * 0.66);
    final tete = Offset(size.width * 0.24, size.height * 0.90);

    // Ombre du bras
    final ombre = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = Colors.black.withAlpha(110);

    final bras = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFDCE1F0);

    final chemin = Path()
      ..moveTo(haut.dx, haut.dy)
      ..lineTo(pivot.dx, pivot.dy)
      ..quadraticBezierTo(size.width * 0.72, size.height * 0.45, coude.dx, coude.dy)
      ..lineTo(tete.dx, tete.dy);

    canvas.drawPath(chemin.shift(const Offset(2, 3)), ombre);
    canvas.drawPath(chemin, bras);

    // Contrepoids & pivot chromé
    canvas.drawCircle(haut, 6.5, Paint()..color = const Color(0xFF434A6C));
    canvas.drawCircle(pivot, 11, Paint()..color = const Color(0xFF1F2338));
    canvas.drawCircle(
      pivot,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white30,
    );
    canvas.drawCircle(pivot, 5.2, Paint()..color = primaire);

    // Coquille / cellule + pointe LED
    canvas.drawCircle(tete, 6.5, Paint()..color = const Color(0xFF282D44));
    canvas.drawCircle(tete, 3.8, Paint()..color = enLecture ? secondaire : Colors.white54);
  }

  @override
  bool shouldRepaint(covariant _PeintreBras old) =>
      old.primaire != primaire || old.secondaire != secondaire || old.enLecture != enLecture;
}

class _PeintreSpectre extends CustomPainter {
  final double phase;
  final bool enLecture;
  final double avancement;
  final double vitesse;
  final Color couleur1, couleur2, couleur3;

  _PeintreSpectre({
    required this.phase,
    required this.enLecture,
    required this.avancement,
    this.vitesse = 1.0,
    required this.couleur1,
    required this.couleur2,
    required this.couleur3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const nb = 42;
    final l = size.width / nb;
    final largeurBarre = (l * 0.56).clamp(2.4, 5.5);
    final t = phase * 2 * pi * vitesse.clamp(0.6, 1.8);

    for (var i = 0; i < nb; i++) {
      final frac = i / nb;
      final centre = 1.0 - (frac - 0.5).abs() * 1.35;
      final hNorm = enLecture
          ? (0.16 +
                  0.84 *
                      centre.clamp(0.15, 1.0) *
                      (0.46 + 0.32 * sin(t + i * 0.52) + 0.22 * cos(t * 2 - i * 0.88)))
              .clamp(0.12, 1.0)
          : 0.14;
      final h = size.height * hNorm;
      final x = i * l + (l - largeurBarre) / 2;
      final passe = frac <= avancement;
      final cBarre = Color.lerp(couleur1, couleur2, frac) ?? couleur1;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - h) / 2, largeurBarre, h),
        const Radius.circular(4),
      );
      if (passe && enLecture && hNorm > 0.45) {
        canvas.drawRRect(
          rect.inflate(1.2),
          Paint()..color = cBarre.withAlpha(42),
        );
      }
      canvas.drawRRect(
        rect,
        Paint()
          ..color = passe ? cBarre : Colors.white.withAlpha(enLecture ? 56 : 28),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PeintreSpectre old) =>
      old.phase != phase ||
      old.enLecture != enLecture ||
      old.avancement != avancement ||
      old.vitesse != vitesse ||
      old.couleur1 != couleur1 ||
      old.couleur2 != couleur2;
}

class _PisteProgressionDegradee extends RoundedRectSliderTrackShape {
  final Color debut;
  final Color fin;

  const _PisteProgressionDegradee(this.debut, this.fin);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final rayon = Radius.circular(trackRect.height / 2);
    final actif = Rect.fromLTRB(trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom);
    final inactif = Rect.fromLTRB(thumbCenter.dx, trackRect.top, trackRect.right, trackRect.bottom);

    final c = context.canvas;
    if (inactif.width > 0) {
      c.drawRRect(
        RRect.fromRectAndRadius(inactif, rayon),
        Paint()..color = sliderTheme.inactiveTrackColor ?? Colors.white24,
      );
    }
    if (actif.width > 0) {
      c.drawRRect(
        RRect.fromRectAndRadius(actif, rayon),
        Paint()
          ..shader = LinearGradient(colors: [debut, fin]).createShader(trackRect),
      );
    }
  }
}

class _PeintreCourbeEq extends CustomPainter {
  final List<double> bandes;
  final bool actif;
  final Color couleur1;
  final Color couleur2;

  _PeintreCourbeEq({
    required this.bandes,
    required this.actif,
    required this.couleur1,
    required this.couleur2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = Colors.white.withAlpha(28)
        ..strokeWidth = 1,
    );

    final pts = <Offset>[];
    for (var i = 0; i < 5; i++) {
      final v = actif ? bandes[i].clamp(-1.0, 1.0) : 0.0;
      final x = size.width * (i + 0.5) / 5;
      final y = midY - v * (size.height * 0.38);
      pts.add(Offset(x, y));
    }

    final tousPts = [
      Offset(0, pts.first.dy),
      ...pts,
      Offset(size.width, pts.last.dy),
    ];

    final courbe = Path()..moveTo(tousPts.first.dx, tousPts.first.dy);
    for (var i = 0; i < tousPts.length - 1; i++) {
      final p0 = tousPts[i];
      final p1 = tousPts[i + 1];
      final mx = (p0.dx + p1.dx) / 2;
      courbe.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
    }

    final aire = Path.from(courbe)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final rect = Offset.zero & size;
    canvas.drawPath(
      aire,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            couleur1.withAlpha(actif ? 95 : 28),
            couleur2.withAlpha(actif ? 18 : 6),
          ],
        ).createShader(rect),
    );

    canvas.drawPath(
      courbe,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [couleur1, couleur2]).createShader(rect),
    );

    for (var i = 0; i < pts.length; i++) {
      final ptColor = Color.lerp(couleur1, couleur2, i / 4) ?? couleur1;
      canvas.drawCircle(pts[i], 4.2, Paint()..color = ptColor);
      canvas.drawCircle(pts[i], 2.0, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _PeintreCourbeEq old) =>
      old.actif != actif ||
      old.couleur1 != couleur1 ||
      old.couleur2 != couleur2 ||
      old.bandes.join(',') != bandes.join(',');
}

class _VueParoles extends StatefulWidget {
  final List<LigneParole> paroles;
  final Duration position;
  final ValueChanged<Duration> onTapLigne;
  final VoidCallback onOuvrirRecherche;
  final Color? primaire;
  final Color? secondaire;

  const _VueParoles({
    super.key,
    required this.paroles,
    required this.position,
    required this.onTapLigne,
    required this.onOuvrirRecherche,
    this.primaire,
    this.secondaire,
  });

  @override
  State<_VueParoles> createState() => _VueParolesState();
}

class _VueParolesState extends State<_VueParoles> {
  final _scroll = ScrollController();
  List<GlobalKey> _cles = const [];
  int _dernierActif = -1;
  bool _defilementLibre = false;
  Timer? _minuteurReprise;

  @override
  void initState() {
    super.initState();
    _preparerCles();
    WidgetsBinding.instance.addPostFrameCallback((_) => _centrerLigneActive(instantane: true));
  }

  @override
  void didUpdateWidget(covariant _VueParoles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paroles.length != widget.paroles.length) {
      _preparerCles();
      _dernierActif = -1;
      _defilementLibre = false;
    }
    final actif = _calculerActif();
    if (actif != _dernierActif) {
      _dernierActif = actif;
      if (!_defilementLibre && actif >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _centrerLigneActive());
      }
    }
  }

  @override
  void dispose() {
    _minuteurReprise?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _preparerCles() {
    _cles = List.generate(widget.paroles.length, (_) => GlobalKey());
  }

  int _calculerActif() {
    var actif = -1;
    final pos = widget.position;
    for (var i = 0; i < widget.paroles.length; i++) {
      if (pos >= widget.paroles[i].debut) {
        actif = i;
      } else {
        break;
      }
    }
    return actif;
  }

  void _centrerLigneActive({bool instantane = false}) {
    if (!mounted) return;
    final idx = _dernierActif;
    if (idx < 0 || idx >= _cles.length) return;
    final ctx = _cles[idx].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.32,
      duration: instantane ? Duration.zero : const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  void _activerDefilementLibre() {
    if (!_defilementLibre) {
      setState(() => _defilementLibre = true);
    }
    _minuteurReprise?.cancel();
    _minuteurReprise = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _defilementLibre = false);
      _centrerLigneActive();
    });
  }

  String _formaterDecalage(int ms) {
    if (ms == 0) return "0s";
    final s = ms / 1000.0;
    final signe = s > 0 ? "+" : "";
    return "$signe${s.toStringAsFixed(1)}s";
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final donnees = moteurAudio.donneesParoles;
    final paroles = widget.paroles;
    final actif = _calculerActif();

    return Column(
      children: [
        _barreOutilsParoles(c, donnees),
        Expanded(
          child: _corpsParoles(c, donnees, paroles, actif),
        ),
      ],
    );
  }

  Widget _barreOutilsParoles(Couleurs c, DonneesParoles? donnees) {
    final sourcesLocales = moteurAudio.sourcesLocales;
    final decMs = moteurAudio.decalageParolesMs;
    final sourceActive = donnees?.source ?? "";

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (sourcesLocales.isNotEmpty) ...[
                  for (final f in sourcesLocales)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _puceSource(
                        c: c,
                        icone: Icons.subtitles_rounded,
                        label: f.label,
                        actif: donnees?.idSource == f.id,
                        onTap: () => moteurAudio.basculerSourceParoles(f.id),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _puceSource(
                      c: c,
                      icone: Icons.cloud_done_rounded,
                      label: moteurAudio.parolesEnLigne != null
                          ? "Karaoké (${moteurAudio.parolesEnLigne!.source})"
                          : "LRCLIB / NetEase",
                      actif: donnees != null && !donnees.idSource.startsWith("local:"),
                      onTap: () => moteurAudio.basculerSourceParoles("en_ligne"),
                    ),
                  ),
                ] else if (sourceActive.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: c.indigo.withAlpha(32),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: c.indigo.withAlpha(110)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          donnees?.motAMot == true ? Icons.auto_awesome_rounded : Icons.lyrics_rounded,
                          size: 13,
                          color: c.cyan,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          donnees?.motAMot == true ? "$sourceActive · Mot-à-mot" : sourceActive,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                _boutonOutil(
                  label: "-0.5s",
                  onTap: () => moteurAudio.ajusterDecalageParoles(-500),
                ),
                const SizedBox(width: 4),
                _boutonOutil(
                  label: "-0.1s",
                  onTap: () => moteurAudio.ajusterDecalageParoles(-100),
                ),
                const SizedBox(width: 4),
                _boutonOutil(
                  label: _formaterDecalage(decMs),
                  actif: decMs != 0,
                  couleurActive: c.cyan,
                  onTap: () => moteurAudio.ajusterDecalageParoles(0, reinitialiser: true),
                ),
                const SizedBox(width: 4),
                _boutonOutil(
                  label: "+0.1s",
                  onTap: () => moteurAudio.ajusterDecalageParoles(100),
                ),
                const SizedBox(width: 4),
                _boutonOutil(
                  label: "+0.5s",
                  onTap: () => moteurAudio.ajusterDecalageParoles(500),
                ),
                const SizedBox(width: 6),
                _boutonOutil(
                  icone: Icons.manage_search_rounded,
                  label: "Chercher",
                  actif: true,
                  couleurActive: c.indigo,
                  onTap: widget.onOuvrirRecherche,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _puceSource({
    required Couleurs c,
    required IconData icone,
    required String label,
    required bool actif,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: actif ? gradBouton : null,
          color: actif ? null : Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: actif ? Colors.white38 : Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, size: 13, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boutonOutil({
    IconData? icone,
    required String label,
    bool actif = false,
    Color? couleurActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: actif ? (couleurActive ?? Colors.white).withAlpha(42) : Colors.white.withAlpha(16),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: actif ? (couleurActive ?? Colors.white).withAlpha(140) : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icone != null) ...[
              Icon(icone, size: 13, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: actif ? Colors.white : Colors.white70,
                fontSize: 11,
                fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _corpsParoles(Couleurs c, DonneesParoles? donnees, List<LigneParole> paroles, int actif) {
    if (moteurAudio.rechercheParolesEnCours && paroles.isEmpty && (donnees?.texteBrut.isEmpty ?? true)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 2.8, color: c.cyan),
              ),
              const SizedBox(height: 14),
              const Text(
                "Recherche des paroles synchronisées…",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text(
                "Inspection des sous-titres YouTube, LRCLIB et NetEase Karaoké",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    if (donnees?.instrumental == true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.piano_rounded, color: c.cyan, size: 46),
              const SizedBox(height: 12),
              const Text(
                "♪ Morceau instrumental",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onOuvrirRecherche,
                icon: const Icon(Icons.search_rounded, size: 16),
                label: const Text("Chercher une autre version"),
              ),
            ],
          ),
        ),
      );
    }

    if (paroles.isEmpty && (donnees?.texteBrut.trim().isNotEmpty ?? false)) {
      return Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withAlpha(28),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withAlpha(110)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 15, color: Colors.amber),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Paroles non synchronisées — appuie sur Chercher pour une version karaoké",
                    style: TextStyle(color: Colors.white, fontSize: 11.5),
                  ),
                ),
                TextButton(
                  onPressed: widget.onOuvrirRecherche,
                  child: const Text("Chercher"),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Text(
                donnees!.texteBrut,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.55,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (paroles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lyrics_outlined, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              const Text(
                "Aucune parole synchronisée trouvée automatiquement",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text(
                "Tu peux lancer une recherche manuelle sur LRCLIB / NetEase ou coller un fichier .lrc / .srt.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12.5),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: widget.onOuvrirRecherche,
                    icon: const Icon(Icons.search_rounded, size: 17),
                    label: const Text("Chercher des paroles"),
                  ),
                  OutlinedButton.icon(
                    onPressed: moteurAudio.relancerRechercheParoles,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text("Réessayer auto"),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (n) {
            _activerDefilementLibre();
            return false;
          },
          child: ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0.0, 0.06, 0.90, 1.0],
            ).createShader(bounds),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 110),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < paroles.length; i++)
                    _construireLigneParole(c, paroles[i], i, actif),
                ],
              ),
            ),
          ),
        ),
        if (_defilementLibre)
          Positioned(
            right: 18,
            bottom: 14,
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                _minuteurReprise?.cancel();
                setState(() => _defilementLibre = false);
                _centrerLigneActive();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                decoration: BoxDecoration(
                  gradient: gradBouton,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4))],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.my_location_rounded, size: 15, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      "Suivre la voix",
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _construireLigneParole(Couleurs c, LigneParole l, int i, int actif) {
    final acc1 = widget.primaire ?? c.indigo;
    final acc2 = widget.secondaire ?? c.cyan;
    final courant = i == actif;
    final passe = i < actif;
    final cle = i < _cles.length ? _cles[i] : null;

    if (l.estPause) {
      if (!courant) return SizedBox(key: cle, height: 6);
      final pos = widget.position;
      final totalMs = max(1, (l.fin - l.debut).inMilliseconds);
      final ecouleMs = (pos - l.debut).inMilliseconds.clamp(0, totalMs);
      final prog = ecouleMs / totalMs;
      return Container(
        key: cle,
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: acc1.withAlpha(32),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: acc2.withAlpha(95)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note_rounded, size: 18, color: acc2),
            const SizedBox(width: 8),
            for (var p = 0; p < 3; p++)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: prog >= (p + 1) / 4
                      ? acc2
                      : Colors.white.withAlpha(75),
                ),
              ),
          ],
        ),
      );
    }

    final pos = widget.position;

    return GestureDetector(
      key: cle,
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTapLigne(l.debut);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: EdgeInsets.symmetric(
          horizontal: courant ? 14 : 10,
          vertical: courant ? 12 : 7,
        ),
        decoration: BoxDecoration(
          gradient: courant
              ? LinearGradient(
                  colors: [acc1.withAlpha(46), Colors.white.withAlpha(18)],
                )
              : null,
          borderRadius: BorderRadius.circular(16),
          border: courant ? Border.all(color: acc1.withAlpha(135), width: 1.1) : null,
          boxShadow: courant
              ? [BoxShadow(color: acc1.withAlpha(38), blurRadius: 16, spreadRadius: -2)]
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: courant && l.mots.isNotEmpty
                  ? Text.rich(
                      TextSpan(
                        children: [
                          for (var mIdx = 0; mIdx < l.mots.length; mIdx++)
                            _spanMotKaraoke(acc1, acc2, l.mots[mIdx], mIdx == l.mots.length - 1, pos),
                        ],
                      ),
                    )
                  : Text(
                      l.texte,
                      style: TextStyle(
                        fontFamily: "PlusJakartaSans",
                        fontSize: courant ? 21 : 16,
                        fontWeight: courant ? FontWeight.w800 : FontWeight.w600,
                        color: courant
                            ? Colors.white
                            : Colors.white.withAlpha(passe ? 85 : 155),
                        height: 1.35,
                      ),
                    ),
            ),
            if (courant) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  moteurAudio.calerParoleSurVoix(l.debut);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: acc1.withAlpha(65),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: acc2.withAlpha(130)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text(
                        "Caler",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  InlineSpan _spanMotKaraoke(Color acc1, Color acc2, MotParole m, bool dernier, Duration pos) {
    final chante = pos > m.fin;
    final enCours = pos >= m.debut && pos <= m.fin;
    final Color couleur;
    if (enCours) {
      couleur = acc2;
    } else if (chante) {
      couleur = Colors.white;
    } else {
      couleur = Colors.white.withAlpha(130);
    }

    return TextSpan(
      text: dernier ? m.texte : "${m.texte} ",
      style: TextStyle(
        fontFamily: "PlusJakartaSans",
        fontSize: 21,
        fontWeight: (enCours || chante) ? FontWeight.w800 : FontWeight.w700,
        color: couleur,
        height: 1.35,
        shadows: enCours
            ? [
                Shadow(color: acc2.withAlpha(170), blurRadius: 14),
                Shadow(color: acc1.withAlpha(130), blurRadius: 24),
              ]
            : null,
      ),
    );
  }
}

class _FeuilleRechercheParoles extends StatefulWidget {
  final Tache tache;
  const _FeuilleRechercheParoles({required this.tache});

  @override
  State<_FeuilleRechercheParoles> createState() => _FeuilleRechercheParolesState();
}

class _FeuilleRechercheParolesState extends State<_FeuilleRechercheParoles> {
  late final TextEditingController _ctrlRequete;
  final TextEditingController _ctrlImport = TextEditingController();
  List<CandidatParoles> _resultats = const [];
  bool _chargement = false;
  bool _modeImport = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    final prop = propositionRecherche(widget.tache);
    _ctrlRequete = TextEditingController(text: [prop.$1, prop.$2].where((s) => s.isNotEmpty).join(" - "));
    _lancerRecherche();
  }

  @override
  void dispose() {
    _ctrlRequete.dispose();
    _ctrlImport.dispose();
    super.dispose();
  }

  Future<void> _lancerRecherche() async {
    final q = _ctrlRequete.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final res = await chercherParolesManuellement(
        q,
        duree: widget.tache.duree,
      );
      if (!mounted) return;
      setState(() {
        _resultats = res;
        _chargement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erreur = "Erreur réseau : $e";
        _chargement = false;
      });
    }
  }

  String _fmtDuree(double s) {
    if (s <= 0) return "";
    final m = s ~/ 60;
    final sec = (s % 60).round().toString().padLeft(2, "0");
    return "$m:$sec";
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final padBas = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: padBas),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1022),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          border: Border.all(color: Colors.white12),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.lyrics_rounded, color: c.cyan, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Paroles & Karaoké (LRCLIB · NetEase)",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _modeImport = !_modeImport),
                  icon: Icon(_modeImport ? Icons.search_rounded : Icons.paste_rounded, size: 16),
                  label: Text(_modeImport ? "Recherche" : "Coller LRC/SRT"),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_modeImport) ...[
              TextField(
                controller: _ctrlImport,
                maxLines: 6,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Colle ici des paroles .lrc ([00:12.34] ...), .srt ou du texte brut…",
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withAlpha(14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    final txt = _ctrlImport.text.trim();
                    if (txt.isEmpty) return;
                    moteurAudio.importerParoles(txt);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text("Enregistrer ces paroles"),
                ),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrlRequete,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _lancerRecherche(),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: "Artiste - Titre…",
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white.withAlpha(16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _chargement ? null : _lancerRecherche,
                    child: const Text("Go"),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_chargement)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_erreur != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_erreur!, style: TextStyle(color: c.rouge)),
                )
              else if (_resultats.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      "Aucun résultat pour cette requête. Essaie avec « Artiste Titre » simplifié.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _resultats.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final r = _resultats[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          HapticFeedback.selectionClick();
                          await moteurAudio.choisirParolesManuelles(r);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: r.motAMot
                                  ? c.cyan.withAlpha(120)
                                  : (r.synchro ? c.indigo.withAlpha(90) : Colors.white12),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      r.titre,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  if (r.duree > 0)
                                    Text(
                                      _fmtDuree(r.duree),
                                      style: mono(context, taille: 11, couleur: Colors.white60),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [r.artiste, if (r.album.isNotEmpty) r.album].join(" · "),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  _badgeCandidat(
                                    r.source,
                                    r.source == "NetEase" ? c.rose : c.indigo,
                                  ),
                                  if (r.motAMot)
                                    _badgeCandidat("Karaoké mot-à-mot", c.cyan)
                                  else if (r.synchro)
                                    _badgeCandidat("Synchronisées", c.vert)
                                  else
                                    _badgeCandidat("Texte seul", Colors.white38),
                                ],
                              ),
                              if (r.extrait.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  r.extrait,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11.5,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _badgeCandidat(String texte, Color couleur) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: couleur.withAlpha(38),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: couleur.withAlpha(130), width: 0.8),
      ),
      child: Text(
        texte,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _VueFileInline extends StatelessWidget {
  final Color? accent;
  const _VueFileInline({super.key, this.accent});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final acc = accent ?? c.indigo;
    final liste = moteurAudio.file;
    final indexActuel = moteurAudio.index;
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: liste.length,
      onReorderItem: moteurAudio.deplacerDansFile,
      proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
      itemBuilder: (context, i) {
        final t = liste[i];
        final actuel = i == indexActuel;
        return Container(
          key: ValueKey('${t.id}-$i'),
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: actuel ? acc.withAlpha(48) : Colors.white.withAlpha(12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: actuel ? acc.withAlpha(155) : Colors.white12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            leading: _DisqueMiniature(url: t.miniature, taille: 42, accent: actuel ? acc : null),
            title: Text(
              t.titre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: actuel ? Colors.white : Colors.white,
                fontWeight: actuel ? FontWeight.w800 : FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            subtitle: Text(
              [if (t.chaine != null) t.chaine!, formaterDuree(t.duree)].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: actuel ? acc : Colors.white54, fontSize: 11.5, fontWeight: actuel ? FontWeight.w600 : FontWeight.w400),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (actuel)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _MiniSpectre(couleur: acc),
                  ),
                if (liste.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                    tooltip: 'Retirer de la file',
                    onPressed: () => moteurAudio.retirerDeFile(i),
                  ),
                const Icon(Icons.drag_handle_rounded, color: Colors.white38),
              ],
            ),
            onTap: () => moteurAudio.allerIndex(i),
          ),
        );
      },
    );
  }
}
