import 'package:sard_agents/sard_agents.dart';
import 'package:test/test.dart';

void main() {
  group('contentTokens', () {
    test('minúsculas, sin tildes, sin palabras vacías ni tokens de menos de 3 letras', () {
      expect(contentTokens('¡Está HERIDO en la calle 20, por favor!'), containsAll(['herido', 'calle', '20']));
      expect(contentTokens('Está herido en la calle'), isNot(contains('en')));
      expect(contentTokens('Está herido en la calle'), isNot(contains('la')));
    });

    test('texto nulo o vacío ⇒ conjunto vacío', () {
      expect(contentTokens(null), isEmpty);
      expect(contentTokens('   '), isEmpty);
    });
  });

  group('textSimilarity', () {
    test('textos idénticos ⇒ 1; sin palabras en común ⇒ 0', () {
      expect(textSimilarity('puente colapsado en la calle veinte', 'puente colapsado en la calle veinte'), 1.0);
      expect(textSimilarity('puente colapsado', 'hay un incendio forestal'), 0.0);
    });

    test('si falta el texto en alguno NO se parecen (no hay nada que comparar)', () {
      expect(textSimilarity(null, 'puente colapsado'), 0.0);
      expect(textSimilarity('puente colapsado', ''), 0.0);
      expect(textSimilarity(null, null), 0.0);
    });

    test('es simétrica e ignora mayúsculas y tildes', () {
      const a = 'ESTÁ ATRAPADO bajo la losa';
      const b = 'esta atrapado bajo losa';
      expect(textSimilarity(a, b), closeTo(textSimilarity(b, a), 1e-9));
      expect(textSimilarity(a, b), greaterThan(0.9));
    });

    test('tolera una falta de ortografía en palabras largas («atrapao» ≈ «atrapado»)', () {
      expect(textSimilarity('atrapado bajo escombros', 'atrapao bajo escombros'), greaterThan(0.9));
    });

    test('compartir sólo la dirección NO basta: dos sucesos distintos en la misma calle quedan lejos de 1', () {
      final s = textSimilarity('hay heridos carrera 23 con calle 45', 'incendio en un edificio carrera 23 con calle 45');
      expect(s, lessThan(0.6));
      expect(s, greaterThan(0.0));
    });

    test('siempre entre 0 y 1', () {
      for (final (a, b) in [('a b c', 'a b c d e f g'), ('uno dos tres', 'cuatro cinco seis'), ('xxxxx yyyyy', 'xxxxy yyyyy')]) {
        final s = textSimilarity(a, b);
        expect(s, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
