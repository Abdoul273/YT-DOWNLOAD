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
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../moteur/gouts.dart';
import '../moteur/langues.dart' as langues;
import '../moteur/miniatures.dart' as miniatures;
import '../moteur/natif.dart';
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

/// Ligne de paroles synchronisées (issue d'un fichier .srt ou .vtt).
class LigneParole {
  final Duration debut, fin;
  final String texte;
  const LigneParole(this.debut, this.fin, this.texte);
}

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
  List<LigneParole> _paroles = [];
  Duration? _a, _b;
  Timer? _sommeil;
  DateTime? _finSommeil;
  int _sommeilMin = 0;
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
  List<LigneParole> get paroles => _paroles;
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
  Future<void> ouvrir(List<Tache> liste, int indexInitial, {bool melanger = false}) async {
    if (liste.isEmpty) return;
    _ecouterCommandes();
    _file = List.of(liste);
    _index = indexInitial.clamp(0, _file.length - 1);
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
    _paroles = [];
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
    final uri = Uri.parse(f.uri);
    final ctrl = uri.scheme == 'content'
        ? VideoPlayerController.contentUri(uri)
        : VideoPlayerController.file(File(f.chemin.isNotEmpty ? f.chemin : uri.toFilePath()));
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
    final pos = ((reglages['positions'] as Map?) ?? {})[t.id];
    // Pour la musique de moins de 12 min, on repart du début ; pour un long podcast/mix, on reprend.
    if (pos is int && ctrl.value.duration.inMinutes >= 12 && pos > 10000 && pos < ctrl.value.duration.inMilliseconds * 0.95) {
      await ctrl.seekTo(Duration(milliseconds: pos));
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

    final lyr = await _chargerParoles(t);
    if (!perime() && lyr.isNotEmpty) {
      _paroles = lyr;
      notifyListeners();
    }
  }

  Future<List<LigneParole>> _chargerParoles(Tache t) async {
    final st = t.fichiers.where((f) => f.nom.endsWith('.srt') || f.nom.endsWith('.vtt')).toList();
    if (st.isEmpty) return const [];
    st.sort((a, b) => (b.nom.contains('.fr') ? 1 : 0).compareTo(a.nom.contains('.fr') ? 1 : 0));
    final f = st.first;
    try {
      final texte = await Natif.lireTexte(f.uri) ?? '';
      if (texte.trim().isEmpty) return const [];
      final ClosedCaptionFile cap = f.nom.endsWith('.vtt') ? WebVTTCaptionFile(texte) : SubRipCaptionFile(texte);
      final res = <LigneParole>[];
      for (final c in cap.captions) {
        final propre = c.text.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (propre.isEmpty) continue;
        if (res.isNotEmpty && res.last.texte == propre) continue;
        res.add(LigneParole(c.start, c.end, propre));
      }
      return res;
    } catch (_) {
      return const [];
    }
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
        v.position >= v.duration &&
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

  void basculerStylePochette() {
    HapticFeedback.selectionClick();
    _stylePochette = _stylePochette == 'vinyle' ? 'carte' : 'vinyle';
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
}) async {
  if (liste != null && liste.isNotEmpty) {
    final memeMorceau = moteurAudio.actif &&
        index >= 0 &&
        index < liste.length &&
        moteurAudio.tache?.id == liste[index].id &&
        !melanger;
    if (!memeMorceau) {
      unawaited(moteurAudio.ouvrir(liste, index, melanger: melanger));
    } else if (!moteurAudio.enLecture) {
      moteurAudio.reprendre();
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: GestureDetector(
            onTap: () => ouvrirLecteurAudio(context),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -250) {
                moteurAudio.suivant();
              } else if (v > 250) {
                moteurAudio.precedent();
              }
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: c.sombre
                          ? [const Color(0xE6151832), const Color(0xE60D0F22)]
                          : [const Color(0xF2FFFFFF), const Color(0xE8EEF0FA)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: c.indigo.withAlpha(c.sombre ? 110 : 75),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(c.sombre ? 110 : 25),
                        blurRadius: 22,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: c.indigo.withAlpha(c.sombre ? 45 : 20),
                        blurRadius: 18,
                        spreadRadius: -4,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                        child: Row(
                          children: [
                            // Mini disque vinyle tournant
                            RotationTransition(
                              turns: _rotation,
                              child: _DisqueMiniature(url: t.miniature, taille: 44),
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
                                        _MiniSpectre(couleur: c.indigo),
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
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                gradient: gradBouton,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(color: c.indigo.withAlpha(90), blurRadius: 10),
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
                      // Barre de progression lumineuse en bas de la pilule
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(22)),
                        child: LinearProgressIndicator(
                          value: prog,
                          minHeight: 2.8,
                          backgroundColor: c.trait,
                          color: c.indigo,
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
}

class _DisqueMiniature extends StatelessWidget {
  final String? url;
  final double taille;
  const _DisqueMiniature({required this.url, required this.taille});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: taille,
      height: taille,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFF282C46), Color(0xFF0E101D), Color(0xFF22253A), Color(0xFF090A12)],
          stops: [0.0, 0.45, 0.75, 1.0],
        ),
        border: Border.all(color: Colors.white24, width: 1),
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
                errorBuilder: (_, _, _) => Icon(Icons.music_note_rounded, color: c.indigo, size: 16),
              )
            else
              ColoredBox(
                color: c.indigo.withAlpha(60),
                child: Icon(Icons.music_note_rounded, color: c.indigo, size: 16),
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
  const _MiniSpectre({required this.couleur});
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
              for (final d in [0.0, 0.35, 0.7])
                Container(
                  width: 3,
                  height: 3 + 9 * (0.5 + 0.5 * sin((v + d) * 2 * pi)),
                  decoration: BoxDecoration(
                    color: widget.couleur,
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

  Duration? _cibleGlisse;
  bool _reste = false;
  int _panneau = 0; // 0: pochette/vinyle, 1: paroles synchronisées, 2: file d'attente

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

  @override
  Widget build(BuildContext context) {
    final t = moteurAudio.tache;
    if (t == null) return const Scaffold(backgroundColor: Colors.black);
    final c = context.c;
    final estFav = _favoris.contains(t.id);
    final pos = _cibleGlisse ?? moteurAudio.position;
    final dur = moteurAudio.duree;
    final dureeMs = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);

    return Scaffold(
      backgroundColor: const Color(0xFF060711),
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 550 && _panneau == 0) {
            Navigator.of(context).pop();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Fond immersif flouté dérivé de la pochette + halo dynamique
            _FondPochette(url: t.miniature),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final paysage = box.maxWidth > box.maxHeight && box.maxHeight < 520;
                  if (paysage) {
                    return _construirePaysage(context, t, c, estFav, pos, dur, dureeMs);
                  }
                  return Column(
                    children: [
                      _barreHaut(context, t, c),
                      _selecteurMode(c, t),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          child: switch (_panneau) {
                            1 => _VueParoles(
                                key: const ValueKey('paroles'),
                                paroles: moteurAudio.paroles,
                                position: pos,
                                onTapLigne: moteurAudio.allerA,
                              ),
                            2 => _VueFileInline(key: const ValueKey('file')),
                            _ => _zoneCentralePochette(t, c),
                          },
                        ),
                      ),
                      if (moteurAudio.spectreActif && _panneau == 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: SizedBox(
                            height: 34,
                            child: AnimatedBuilder(
                              animation: _onde,
                              builder: (_, _) => CustomPaint(
                                painter: _PeintreSpectre(
                                  phase: _onde.value,
                                  enLecture: moteurAudio.enLecture,
                                  avancement: pos.inMilliseconds / dureeMs,
                                  couleur1: c.indigo,
                                  couleur2: c.cyan,
                                  couleur3: c.rose,
                                ),
                                size: Size.infinite,
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _infosTitre(t, c, estFav),
                            const SizedBox(height: 12),
                            _barreProgression(c, pos, dur, dureeMs),
                            const SizedBox(height: 6),
                            _commandesPrincipales(c),
                            const SizedBox(height: 12),
                            _dockStudio(context, t, c),
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
    );
  }

  Widget _construirePaysage(
    BuildContext context,
    Tache t,
    Couleurs c,
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
              _barreHaut(context, t, c),
              Expanded(child: _zoneCentralePochette(t, c)),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 22, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _selecteurMode(c, t),
                if (_panneau != 0)
                  Expanded(
                    child: _panneau == 1
                        ? _VueParoles(paroles: moteurAudio.paroles, position: pos, onTapLigne: moteurAudio.allerA)
                        : const _VueFileInline(),
                  )
                else ...[
                  _infosTitre(t, c, estFav),
                  _barreProgression(c, pos, dur, dureeMs),
                  _commandesPrincipales(c),
                  _dockStudio(context, t, c),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _barreHaut(BuildContext context, Tache t, Couleurs c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Réduire dans le mini-lecteur',
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 30),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.graphic_eq_rounded, color: c.indigo, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      'ONDE STUDIO',
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 1.8,
                        fontWeight: FontWeight.w800,
                        color: Colors.white.withAlpha(190),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(22),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24, width: 0.8),
                  ),
                  child: Text(
                    [
                      _qualiteBadge(t),
                      if (t.pistes.isNotEmpty) t.pistes,
                      if (moteurAudio.eqActif || moteurAudio.basses > 0 || moteurAudio.gain > 0) 'DSP ACTIF',
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
            tooltip: moteurAudio.stylePochette == 'vinyle' ? 'Afficher la pochette carrée' : 'Afficher la platine vinyle',
            icon: Icon(
              moteurAudio.stylePochette == 'vinyle' ? Icons.album_rounded : Icons.crop_square_rounded,
              color: Colors.white70,
            ),
            onPressed: moteurAudio.basculerStylePochette,
          ),
          IconButton(
            tooltip: 'Plus d’options',
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            onPressed: () => _ouvrirMenuPlus(context, t),
          ),
        ],
      ),
    );
  }

  Widget _selecteurMode(Couleurs c, Tache t) {
    final nbParoles = moteurAudio.paroles.length;
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
            _ongletMode(0, Icons.album_rounded, 'Platine', c),
            _ongletMode(1, Icons.lyrics_rounded, nbParoles > 0 ? 'Paroles ($nbParoles)' : 'Paroles', c),
            _ongletMode(2, Icons.queue_music_rounded, 'File (${moteurAudio.file.length})', c),
          ],
        ),
      ),
    );
  }

  Widget _ongletMode(int idx, IconData icone, String label, Couleurs c) {
    final actif = _panneau == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _panneau = idx);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            gradient: actif ? gradBouton : null,
            borderRadius: BorderRadius.circular(15),
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

  Widget _zoneCentralePochette(Tache t, Couleurs c) {
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

    return GestureDetector(
      onDoubleTap: moteurAudio.lecturePause,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -300) {
          moteurAudio.suivant();
        } else if (v > 300) {
          moteurAudio.precedent();
        }
      },
      child: Center(
        child: LayoutBuilder(
          builder: (context, box) {
            final cote = (min(box.maxWidth, box.maxHeight) - 36).clamp(160.0, 340.0);
            if (moteurAudio.stylePochette == 'carte') {
              return AnimatedScale(
                scale: moteurAudio.enLecture ? 1.0 : 0.92,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutBack,
                child: Container(
                  width: cote,
                  height: cote,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: c.indigo.withAlpha(moteurAudio.enLecture ? 120 : 45),
                        blurRadius: 48,
                        spreadRadius: 2,
                      ),
                      const BoxShadow(color: Colors.black87, blurRadius: 30, offset: Offset(0, 16)),
                    ],
                    border: Border.all(color: Colors.white24, width: 1.2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(27),
                    child: t.miniature != null
                        ? Image(
                            image: miniatures.image(t.miniature!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _pochetteSecours(c),
                          )
                        : _pochetteSecours(c),
                  ),
                ),
              );
            }
            return _PlatineVinyle(
              url: t.miniature,
              cote: cote,
              rotation: _vinyle,
              enLecture: moteurAudio.enLecture,
              accent: c.indigo,
            );
          },
        ),
      ),
    );
  }

  Widget _pochetteSecours(Couleurs c) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.indigo.withAlpha(120), const Color(0xFF12152E)],
          ),
        ),
        child: const Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: 72)),
      );

  Widget _infosTitre(Tache t, Couleurs c, bool estFav) {
    return Row(
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
              const SizedBox(height: 5),
              Text(
                t.chaine ?? 'Artiste inconnu',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.indigo,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
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
    );
  }

  Widget _barreProgression(Couleurs c, Duration pos, Duration dur, double dureeMs) {
    final a = moteurAudio.pointA;
    final b = moteurAudio.pointB;
    return Column(
      children: [
        SizedBox(
          height: 30,
          child: LayoutBuilder(
            builder: (ctx, box) {
              final l = box.maxWidth;
              double x(Duration d) => 12 + (d.inMilliseconds / dureeMs).clamp(0.0, 1.0) * (l - 24);
              return Stack(
                alignment: Alignment.center,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: _cibleGlisse != null ? 6 : 4,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: _cibleGlisse != null ? 9 : 6.5),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: c.indigo,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: c.indigo.withAlpha(60),
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
                        child: Container(width: 3, height: 14, color: c.ambre),
                      ),
                    ),
                  if (b != null)
                    Positioned(
                      left: x(b),
                      child: IgnorePointer(
                        child: Container(width: 3, height: 14, color: c.ambre),
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

  Widget _commandesPrincipales(Couleurs c) {
    final lecture = moteurAudio.enLecture;
    final rep = moteurAudio.repetition;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          tooltip: 'Lecture aléatoire',
          onPressed: moteurAudio.basculerAleatoire,
          icon: Icon(
            Icons.shuffle_rounded,
            color: moteurAudio.aleatoire ? c.indigo : Colors.white54,
            size: 23,
          ),
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
            duration: const Duration(milliseconds: 220),
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              gradient: gradBouton,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: c.indigo.withAlpha(lecture ? 140 : 70),
                  blurRadius: lecture ? 28 : 16,
                  spreadRadius: lecture ? 2 : 0,
                ),
              ],
              border: Border.all(color: Colors.white38, width: 1.4),
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
        IconButton(
          tooltip: switch (rep) {
            1 => 'Répéter la file',
            2 => 'Répéter ce titre',
            _ => 'Répétition désactivée',
          },
          onPressed: moteurAudio.basculerRepetition,
          icon: Icon(
            rep == 2 ? Icons.repeat_one_on_rounded : (rep == 1 ? Icons.repeat_on_rounded : Icons.repeat_rounded),
            color: rep != 0 ? c.indigo : Colors.white54,
            size: 23,
          ),
        ),
      ],
    );
  }

  Widget _dockStudio(BuildContext context, Tache t, Couleurs c) {
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
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icone, size: 19, color: actif ? c.indigo : Colors.white70),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: actif ? FontWeight.w800 : FontWeight.w600,
                    color: actif ? c.indigo : Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            onTap: () => _ouvrirEgaliseur(context),
          ),
          boutonDock(
            icone: Icons.speed_rounded,
            label: vit ? '${moteurAudio.vitesse.toString().replaceAll('.0', '')}×' : 'Vitesse',
            actif: vit,
            onTap: () => _ouvrirVitesse(context),
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
            onTap: () => _ouvrirSommeil(context),
          ),
          if (moteurAudio.pistes.length > 1)
            boutonDock(
              icone: Icons.translate_rounded,
              label: 'Piste',
              onTap: () => _ouvrirPistes(context),
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

  Future<void> _feuille(BuildContext context, Widget Function(BuildContext, StateSetter) builder) {
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
                top: BorderSide(color: context.c.indigo.withAlpha(100), width: 1.2),
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

  void _ouvrirEgaliseur(BuildContext context) {
    _feuille(context, (ctx, maj) {
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
                Icon(Icons.equalizer_rounded, color: c.indigo),
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
                        selectedColor: c.indigo,
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
            const SizedBox(height: 18),
            // 5 bandes verticales
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
                          style: mono(context, taille: 10.5, couleur: c.indigo),
                        ),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                activeTrackColor: c.indigo,
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
            // Bass Boost
            Row(
              children: [
                Icon(Icons.speaker_rounded, color: c.cyan, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Renforcement des basses (Bass Boost)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
                Text('${(moteurAudio.basses / 10).round()} %', style: mono(context, taille: 12, couleur: c.cyan)),
              ],
            ),
            Slider(
              min: 0,
              max: 1000,
              value: moteurAudio.basses.toDouble(),
              activeColor: c.cyan,
              inactiveColor: Colors.white24,
              onChanged: (v) {
                moteurAudio.modifierBasses(v.round());
                maj(() {});
              },
            ),
            // Amplificateur de puissance
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

  void _ouvrirVitesse(BuildContext context) {
    _feuille(context, (ctx, maj) {
      final c = context.c;
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
              activeColor: c.indigo,
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
                    selectedColor: c.indigo,
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

  void _ouvrirSommeil(BuildContext context) {
    _feuille(context, (ctx, _) {
      final c = context.c;
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
                leading: Icon(m == 0 ? Icons.timer_off_outlined : Icons.bedtime_rounded, color: m == moteurAudio.sommeilMin ? c.indigo : Colors.white70),
                title: Text(m == 0 ? 'Désactivé' : 'Arrêter dans $m minutes', style: const TextStyle(color: Colors.white)),
                trailing: m == moteurAudio.sommeilMin ? Icon(Icons.check_rounded, color: c.indigo) : null,
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

  void _ouvrirPistes(BuildContext context) {
    _feuille(context, (ctx, _) {
      final c = context.c;
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
                trailing: pistes[i].isSelected ? Icon(Icons.check_rounded, color: c.indigo) : null,
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

  void _ouvrirMenuPlus(BuildContext context, Tache t) {
    _feuille(context, (ctx, maj) {
      final c = context.c;
      final f = t.fichierPrincipal;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 38, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            SwitchListTile(
              secondary: Icon(Icons.waves_rounded, color: c.cyan),
              title: const Text('Spectre lumineux animé', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: const Text('Onde audio synchronisée sous la platine', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: moteurAudio.spectreActif,
              onChanged: (_) {
                moteurAudio.basculerSpectre();
                maj(() {});
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${f?.nom ?? t.titre}\n${formaterTaille(t.tailleFichier)} · ${_qualiteBadge(t)}',
                    style: mono(context, taille: 11, couleur: Colors.white54),
                  ),
                ],
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
  const _FondPochette({required this.url});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF060711)),
        if (url != null)
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
              child: Opacity(
                opacity: 0.42,
                child: Image(
                  image: ResizeImage(miniatures.image(url!), width: 200),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(),
                ),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0x88060711),
                c.indigo.withAlpha(24),
                const Color(0xE6060711),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PlatineVinyle extends StatelessWidget {
  final String? url;
  final double cote;
  final Animation<double> rotation;
  final bool enLecture;
  final Color accent;

  const _PlatineVinyle({
    required this.url,
    required this.cote,
    required this.rotation,
    required this.enLecture,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cote + 28,
      height: cote + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo ambiant
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: cote * (enLecture ? 0.96 : 0.82),
            height: cote * (enLecture ? 0.96 : 0.82),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: accent.withAlpha(enLecture ? 115 : 40),
                  blurRadius: enLecture ? 55 : 25,
                  spreadRadius: enLecture ? 6 : 0,
                ),
              ],
            ),
          ),
          // Disque vinyle avec sillons et reflets
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
                gradient: const SweepGradient(
                  colors: [
                    Color(0xFF10121E),
                    Color(0xFF282D46),
                    Color(0xFF0D0E18),
                    Color(0xFF1E2238),
                    Color(0xFF0D0E18),
                    Color(0xFF282D46),
                    Color(0xFF10121E),
                  ],
                ),
                border: Border.all(color: Colors.white24, width: 1.5),
              ),
              child: CustomPaint(
                painter: _PeintreSillons(),
                child: Center(
                  child: Container(
                    width: cote * 0.56,
                    height: cote * 0.56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30, width: 2),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
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
                                color: accent.withAlpha(80),
                                child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 48),
                              ),
                            )
                          else
                            ColoredBox(
                              color: accent.withAlpha(80),
                              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 48),
                            ),
                          // Trou central du vinyle
                          Center(
                            child: Container(
                              width: cote * 0.08,
                              height: cote * 0.08,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0A0B14),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white60, width: 1.5),
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
          // Bras de lecture (tonearm) qui se pose sur le disque quand ça joue
          Positioned(
            top: 4,
            right: 2,
            child: IgnorePointer(
              child: AnimatedRotation(
                turns: enLecture ? 0.0 : -0.075,
                alignment: const Alignment(0.65, -0.75),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                child: SizedBox(
                  width: cote * 0.28,
                  height: cote * 0.48,
                  child: CustomPaint(painter: _PeintreBras(accent)),
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
      ..color = Colors.white.withAlpha(18);
    for (double f = 0.62; f < 0.96; f += 0.045) {
      canvas.drawCircle(c, rMax * f, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PeintreBras extends CustomPainter {
  final Color accent;
  _PeintreBras(this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = Offset(size.width * 0.78, size.height * 0.14);
    final coude = Offset(size.width * 0.62, size.height * 0.68);
    final tete = Offset(size.width * 0.25, size.height * 0.9);

    final bras = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFD6DAE8);

    final chemin = Path()
      ..moveTo(pivot.dx, pivot.dy)
      ..lineTo(coude.dx, coude.dy)
      ..lineTo(tete.dx, tete.dy);
    canvas.drawPath(chemin, bras);

    canvas.drawCircle(pivot, 10, Paint()..color = const Color(0xFF282C44));
    canvas.drawCircle(pivot, 5, Paint()..color = accent);
    canvas.drawCircle(tete, 5.5, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant _PeintreBras old) => old.accent != accent;
}

class _PeintreSpectre extends CustomPainter {
  final double phase;
  final bool enLecture;
  final double avancement;
  final Color couleur1, couleur2, couleur3;

  _PeintreSpectre({
    required this.phase,
    required this.enLecture,
    required this.avancement,
    required this.couleur1,
    required this.couleur2,
    required this.couleur3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const nb = 38;
    final l = size.width / nb;
    final largeurBarre = (l * 0.58).clamp(2.5, 6.0);
    final t = phase * 2 * pi;

    for (var i = 0; i < nb; i++) {
      final frac = i / nb;
      final centre = 1.0 - (frac - 0.5).abs() * 1.45;
      final hNorm = enLecture
          ? (0.18 +
                  0.82 *
                      centre.clamp(0.15, 1.0) *
                      (0.5 + 0.3 * sin(t + i * 0.55) + 0.2 * cos(t * 2 - i * 0.9)))
              .clamp(0.12, 1.0)
          : 0.14;
      final h = size.height * hNorm;
      final x = i * l + (l - largeurBarre) / 2;
      final passe = frac <= avancement;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, (size.height - h) / 2, largeurBarre, h),
        const Radius.circular(4),
      );
      final paint = Paint()
        ..color = passe
            ? Color.lerp(couleur1, couleur2, frac) ?? couleur1
            : Colors.white.withAlpha(enLecture ? 55 : 30);
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PeintreSpectre old) =>
      old.phase != phase || old.enLecture != enLecture || old.avancement != avancement;
}

class _VueParoles extends StatelessWidget {
  final List<LigneParole> paroles;
  final Duration position;
  final ValueChanged<Duration> onTapLigne;

  const _VueParoles({
    super.key,
    required this.paroles,
    required this.position,
    required this.onTapLigne,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (paroles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined, color: Colors.white38, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Aucune parole synchronisée pour ce titre',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text(
                'Télécharge avec les sous-titres activés pour afficher les paroles synchronisées ici.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ],
          ),
        ),
      );
    }

    var actif = -1;
    for (var i = 0; i < paroles.length; i++) {
      if (position >= paroles[i].debut && position <= paroles[i].fin + const Duration(seconds: 2)) {
        actif = i;
      } else if (position >= paroles[i].debut) {
        actif = i;
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      itemCount: paroles.length,
      itemBuilder: (context, i) {
        final l = paroles[i];
        final courant = i == actif;
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onTapLigne(l.debut);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: TextStyle(
                fontFamily: 'PlusJakartaSans',
                fontSize: courant ? 20 : 15.5,
                fontWeight: courant ? FontWeight.w800 : FontWeight.w600,
                color: courant ? c.indigo : Colors.white.withAlpha(i < actif ? 95 : 150),
                height: 1.35,
              ),
              child: Text(l.texte),
            ),
          ),
        );
      },
    );
  }
}

class _VueFileInline extends StatelessWidget {
  const _VueFileInline({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
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
            color: actuel ? c.indigo.withAlpha(45) : Colors.white.withAlpha(12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: actuel ? c.indigo.withAlpha(140) : Colors.white12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            leading: _DisqueMiniature(url: t.miniature, taille: 42),
            title: Text(
              t.titre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: actuel ? c.indigo : Colors.white,
                fontWeight: actuel ? FontWeight.w800 : FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            subtitle: Text(
              [if (t.chaine != null) t.chaine!, formaterDuree(t.duree)].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 11.5),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
