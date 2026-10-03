import 'package:flutter_test/flutter_test.dart';
import 'package:yt_nexus/moteur/langues.dart' as langues;
import 'package:yt_nexus/ui/etat.dart';

void main() {
  test('langues', () {
    expect(langues.nom('fr-CA'), 'Français (CA)');
    expect(langues.memeLangue('fr-FR', 'fr'), isTrue);
  });

  test('extraction des liens', () {
    expect(extraireLiens('regarde https://youtu.be/abc et https://youtu.be/def'), hasLength(2));
    expect(extraireLiens('youtube.com/watch?v=abc'), ['https://youtube.com/watch?v=abc']);
  });
}
