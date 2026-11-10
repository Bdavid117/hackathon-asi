import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('triaje: la imprecisión de la ubicación de UN reporte suelto (antes sólo nacía al comparar pares)', () {
    test('±1 km, «más de 1 km» y «manual» son imprecisas', () {
      for (final q in [LocQuality.within1km, LocQuality.over1km, LocQuality.manual]) {
        expect(triage(SituationFlags.atrapado, hasLocation: true, locQuality: q).uncertainty, contains('ubicacion_imprecisa'), reason: '$q');
      }
    });

    test('±10, ±50 y ±200 m no lo son', () {
      for (final q in [LocQuality.within10m, LocQuality.within50m, LocQuality.within200m]) {
        expect(triage(SituationFlags.atrapado, hasLocation: true, locQuality: q).uncertainty, isNot(contains('ubicacion_imprecisa')), reason: '$q');
      }
    });

    test('sin ubicación sigue diciendo «ubicacion_ausente» y no «imprecisa» (son cosas distintas)', () {
      final r = triage(SituationFlags.atrapado, hasLocation: false, locQuality: LocQuality.manual);
      expect(r.uncertainty, contains('ubicacion_ausente'));
      expect(r.uncertainty, isNot(contains('ubicacion_imprecisa')));
    });

    test('sin decir la calidad (como antes) no cambia nada', () {
      expect(triage(SituationFlags.atrapado).uncertainty, isNot(contains('ubicacion_imprecisa')));
    });

    test('NO cambia la urgencia, las señales ni el escalamiento: sólo se avisa de la duda', () {
      final precise = triage(SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada', hasLocation: true, locQuality: LocQuality.within10m);
      final vague = triage(SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada', hasLocation: true, locQuality: LocQuality.manual);
      expect(vague.urgency, precise.urgency);
      expect(vague.signals, precise.signals);
      expect(vague.escalateToHuman, precise.escalateToHuman);
      expect(vague.confidence, precise.confidence);
    });
  });
}
