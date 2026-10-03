/// Navigation partagée entre les onglets.
library;

import 'package:flutter/foundation.dart';

/// Onglet affiché : 0 Vidéo, 1 Recherche, 2 En cours, 3 Fichiers, 4 Réglages.
final onglet = ValueNotifier<int>(0);

/// Lien(s) à analyser dans l'onglet Vidéo (partage, recherche, presse-papiers).
final lienAAnalyser = ValueNotifier<String?>(null);

void ouvrirLien(String texte) {
  lienAAnalyser.value = null;
  lienAAnalyser.value = texte;
  onglet.value = 0;
}

/// Liens YouTube (ou autres) trouvés dans un texte.
List<String> extraireLiens(String texte) {
  final liens = RegExp(r'https?://[^\s<>"]+').allMatches(texte).map((m) => m.group(0)!).toList();
  if (liens.isEmpty) {
    final t = texte.trim();
    if (RegExp(r'^(www\.|m\.)?(youtube\.com|youtu\.be)/').hasMatch(t)) return ['https://$t'];
  }
  return liens.toSet().toList();
}

String formaterVues(int? v) {
  if (v == null) return '';
  if (v >= 1000000000) return '${(v / 1e9).toStringAsFixed(1).replaceAll('.', ',')} Md vues';
  if (v >= 1000000) return '${(v / 1e6).toStringAsFixed(1).replaceAll('.', ',')} M vues';
  if (v >= 1000) return '${(v / 1e3).toStringAsFixed(v >= 10000 ? 0 : 1).replaceAll('.', ',')} k vues';
  return '$v vues';
}

String ilYA(int? ts) {
  if (ts == null) return '';
  final s = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
  if (s < 3600) return 'il y a ${(s / 60).floor().clamp(1, 59)} min';
  if (s < 86400) return 'il y a ${s ~/ 3600} h';
  if (s < 30 * 86400) return 'il y a ${s ~/ 86400} j';
  if (s < 365 * 86400) return 'il y a ${s ~/ (30 * 86400)} mois';
  return 'il y a ${s ~/ (365 * 86400)} an${s >= 730 * 86400 ? 's' : ''}';
}
