import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('looksCutOff: ¿el mensaje parece cortado a la mitad?', () {
    test('termina en puntos suspensivos', () {
      expect(looksCutOff('hay gente atrapada en el edificio de la...'), isTrue);
      expect(looksCutOff('hay gente atrapada…'), isTrue);
    });

    test('termina en una palabra que pide continuar (conjunción, preposición, artículo)', () {
      for (final t in ['dos personas atrapadas y', 'hay un herido en', 'necesitamos ayuda porque', 'la casa se cayó sobre la', 'estamos con', 'tres niños de', 'sin agua ni', 'hay humo pero']) {
        expect(looksCutOff(t), isTrue, reason: t);
      }
    });

    test('termina en coma, guion o dos puntos', () {
      for (final t in ['hay un incendio,', 'hay un incendio -', 'se necesita: ']) {
        expect(looksCutOff(t), isTrue, reason: t);
      }
    });

    test('ignora mayúsculas, tildes y espacios al final', () {
      expect(looksCutOff('HAY UN HERIDO EN   '), isTrue);
      expect(looksCutOff('hay un herido EN\n'), isTrue);
    });

    test('un mensaje completo NO se marca', () {
      for (final t in [
        'mi mamá no puede salir del segundo piso, hay mucho polvo',
        'hay una persona atrapada.',
        'necesitamos ayuda por favor',
        'calle 20 con carrera 15',
        'hay 3 heridos',
        'sin heridos',
        'estamos bien',
        'se cayó el puente?',
        'urgente!',
      ]) {
        expect(looksCutOff(t), isFalse, reason: t);
      }
    });

    test('si la persona puso punto final, el mensaje está terminado aunque acabe en una palabra rara', () {
      expect(looksCutOff('dijeron que ya vienen, pero.'), isFalse);
      expect(looksCutOff('hay un herido y!'), isFalse);
      expect(looksCutOff('¿cuántos son los de la?'), isFalse);
    });

    test('«no» y «si» al final no cuentan: son respuestas completas («¿hay agua? no»)', () {
      expect(looksCutOff('¿hay agua? no'), isFalse);
      expect(looksCutOff('no sé si'), isFalse);
    });

    test('vacío, sólo espacios o sólo puntuación: no hay nada que decir', () {
      expect(looksCutOff(''), isFalse);
      expect(looksCutOff('   '), isFalse);
      expect(looksCutOff('.'), isFalse);
    });

    test('es una pista, no una afirmación: un solo carácter suelto no dispara nada raro', () {
      expect(looksCutOff('a'), isTrue, reason: 'una «a» suelta al final es, casi seguro, una frase cortada');
      expect(looksCutOff('1'), isFalse);
    });
  });

  group('el triaje lo dice, sin tocar la urgencia ni completar nada', () {
    test('añade «mensaje_cortado» a la incertidumbre', () {
      final r = triage(0, text: 'hay una persona atrapada y');
      expect(r.uncertainty, contains('mensaje_cortado'));
    });

    test('un mensaje completo no lo lleva', () {
      expect(triage(0, text: 'hay una persona atrapada').uncertainty, isNot(contains('mensaje_cortado')));
    });

    test('NO cambia la urgencia, las señales, la evidencia, la confianza ni el escalamiento', () {
      final cut = triage(SituationFlags.herido, text: 'hay una persona atrapada y');
      final whole = triage(SituationFlags.herido, text: 'hay una persona atrapada');
      expect(cut.urgency, whole.urgency);
      expect(cut.signals, whole.signals);
      expect([for (final e in cut.evidence) e.code], [for (final e in whole.evidence) e.code]);
      expect(cut.confidence, whole.confidence);
      expect(cut.escalateToHuman, whole.escalateToHuman);
    });

    test('propiedad: cortar un texto en una conjunción NUNCA baja la urgencia', () {
      const base = ['hay una persona atrapada', 'incendio en la casa', 'no respira', 'sin heridos', 'hay gente en la calle', 'niños solos'];
      for (final b in base) {
        for (final tail in [' y', ' en', ' porque', '...', ',']) {
          final a = triage(0, text: b);
          final c = triage(0, text: '$b$tail');
          expect(c.urgency.index, lessThanOrEqualTo(a.urgency.index), reason: '«$b$tail» no puede ser menos urgente que «$b»');
          expect(c.urgency, a.urgency, reason: 'ni más');
        }
      }
    });

    test('sin texto no inventa un mensaje cortado', () {
      expect(triage(SituationFlags.atrapado).uncertainty, isNot(contains('mensaje_cortado')));
    });

    test('convive con «texto_truncado» (el límite de 140 B): son cosas distintas', () {
      final t = '${'a' * 120} y' * 2;
      final r = triage(0, text: t);
      expect(r.uncertainty, containsAll(['texto_truncado', 'mensaje_cortado']));
    });
  });
}
