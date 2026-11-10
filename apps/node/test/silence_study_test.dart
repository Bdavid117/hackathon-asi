import 'dart:math';

import 'package:test/test.dart';

import '../tool/silence_study.dart';

StudyZone zone(int i, List<int> minutes, {int? blackoutAt, double rate = 4}) => StudyZone(index: i, rate: rate, blackoutAtMinute: blackoutAt, reportMinutes: minutes);

void main() {
  group('el generador del estudio (modelo de llegadas aparte del detector)', () {
    test('es reproducible por semilla', () {
      String sig(List<StudyZone> z) => z.map((e) => '${e.rate.toStringAsFixed(4)}/${e.blackoutAtMinute}/${e.reportMinutes.join(',')}').join('|');
      expect(sig(generateStudyZones(Random(1))), sig(generateStudyZones(Random(1))));
      expect(sig(generateStudyZones(Random(1))), isNot(sig(generateStudyZones(Random(2)))));
    });

    test('todo reporte cae dentro de las seis horas y las tasas, dentro de lo pedido', () {
      for (final z in generateStudyZones(Random(3), zones: 300, minRate: 0.5, maxRate: 8)) {
        expect(z.rate, inInclusiveRange(0.5 - 1e-9, 8 + 1e-9));
        for (final m in z.reportMinutes) {
          expect(m, inInclusiveRange(0, kStudyMinutes - 1));
        }
      }
    });

    test('la fracción de zonas que se apagan es la pedida (con tolerancia) y las apagadas llevan un minuto de apagón válido', () {
      final zs = generateStudyZones(Random(4), zones: 2000, blackoutShare: 0.3);
      final share = zs.where((z) => z.blackout).length / zs.length;
      expect(share, closeTo(0.3, 0.04));
      for (final z in zs.where((z) => z.blackout)) {
        expect(z.blackoutAtMinute!, inInclusiveRange(5, kStudyMinutes - 6));
        expect(z.darkForMinutes, kStudyMinutes - z.blackoutAtMinute!);
      }
      expect(zs.where((z) => !z.blackout).every((z) => z.darkForMinutes == null), isTrue);
    });

    test('tras el apagón la tasa cae a una fracción de la de antes (con λ = 12/h: unos 12/h antes, ≈0,6/h después)', () {
      final zs = generateStudyZones(Random(5), zones: 400, blackoutShare: 1, minRate: 12, maxRate: 12);
      var before = 0.0, after = 0.0, beforeMin = 0.0, afterMin = 0.0;
      for (final z in zs) {
        final b = z.blackoutAtMinute!;
        before += z.reportMinutes.where((m) => m < b).length;
        after += z.reportMinutes.where((m) => m >= b).length;
        beforeMin += b;
        afterMin += kStudyMinutes - b;
      }
      final rateBefore = before / beforeMin * 60, rateAfter = after / afterMin * 60;
      expect(rateBefore, closeTo(12, 0.8));
      expect(rateAfter, closeTo(0.6, 0.25));
    });

    test('sin apagones (blackoutShare 0) no hay ninguno, y con 100 % todos', () {
      expect(generateStudyZones(Random(6), blackoutShare: 0).any((z) => z.blackout), isFalse);
      expect(generateStudyZones(Random(6), blackoutShare: 1).every((z) => z.blackout), isTrue);
    });
  });

  group('lo que el detector REAL marca (markedSilent)', () {
    final zones = [
      zone(0, [100]), // último reporte hace 260 min
      zone(1, [350]), // hace 10 min
      zone(2, []), // sin actividad: invisible
      zone(3, [100, 340]), // el último, hace 20 min
      zone(4, [320]), // hace 40 min
      zone(5, [60, 329]), // hace 31 min
      zone(6, [330]), // hace 30 min exactos
    ];

    test('con 30 min: marca las que callaron hace 30 min o más y no las demás ni las invisibles', () {
      expect(markedSilent(zones), {0, 4, 5, 6});
    });

    test('con otra ventana cambia lo marcado: 15 min incluye a la 3, 60 min deja fuera a la 4 y la 5', () {
      expect(markedSilent(zones, silenceMinutes: 15), {0, 3, 4, 5, 6});
      expect(markedSilent(zones, silenceMinutes: 60), {0});
    });

    test('no depende del orden de las zonas', () {
      expect(markedSilent(zones.reversed.toList()), markedSilent(zones));
    });
  });

  group('la matriz de confusión (sólo zonas visibles; las invisibles se cuentan aparte)', () {
    test('cuenta aciertos, falsas alarmas, apagones perdidos y no marcadas, y calcula precisión y exhaustividad', () {
      final zs = [
        zone(0, [10], blackoutAt: 100), // apagón, marcada → tp
        zone(1, [10], blackoutAt: 100), // apagón, marcada → tp
        zone(2, [350], blackoutAt: 100), // apagón, NO marcada → fn
        zone(3, [10]), // normal, marcada → fp
        zone(4, [350]), // normal, no marcada → tn
        zone(5, [], blackoutAt: 100), // apagón invisible
        zone(6, []), // normal invisible
      ];
      final c = confusionOf(zs, {0, 1, 3});
      expect((c.tp, c.fp, c.fn, c.tn, c.invisibleBlackout, c.invisibleNormal), (2, 1, 1, 1, 1, 1));
      expect(c.precision, closeTo(2 / 3, 1e-12));
      expect(c.recall, closeTo(2 / 3, 1e-12));
      expect((c.marked, c.blackouts), (3, 3));
    });

    test('sin marcadas la precisión no existe (null), y sin apagones la exhaustividad tampoco: no se inventa un 0 % ni un 100 %', () {
      final c = confusionOf([zone(0, [350])], {});
      expect((c.precision, c.recall), (null, null));
    });
  });
}
