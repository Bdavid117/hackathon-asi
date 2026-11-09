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

  group('textEvidence: una similitud con pocas palabras compartidas casi no es evidencia', () {
    test('«no hay atrapados» frente a «estoy atrapado» (una sola palabra, con una falta) vale poco', () {
      expect(textSimilarity('no hay atrapados', 'estoy atrapado'), 1.0, reason: 'la similitud cruda es engañosa');
      expect(weightedTextSimilarity('no hay atrapados', 'estoy atrapado'), lessThan(0.25));
    });

    test('con 5 o más palabras compartidas el crédito es completo', () {
      const t = 'dicen por la radio que el puente de la calle veinte colapsó, que nadie pase';
      expect(weightedTextSimilarity(t, t), 1.0);
    });

    test('crece con las palabras compartidas y nunca supera a la similitud cruda', () {
      var prev = 0.0;
      const base = 'puente colapsado calle veinte carros abajo gente';
      final words = base.split(' ');
      for (var n = 1; n <= words.length; n++) {
        final t = words.take(n).join(' ');
        final w = weightedTextSimilarity(t, t);
        expect(w, greaterThanOrEqualTo(prev), reason: 'n=$n');
        expect(w, lessThanOrEqualTo(textSimilarity(t, t)));
        prev = w;
      }
    });

    test('es simétrica y vale 0 si falta algún texto', () {
      expect(weightedTextSimilarity('uno dos tres cuatro', 'uno dos tres cinco'), closeTo(weightedTextSimilarity('uno dos tres cinco', 'uno dos tres cuatro'), 1e-12));
      expect(weightedTextSimilarity(null, 'algo largo aquí'), 0.0);
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
