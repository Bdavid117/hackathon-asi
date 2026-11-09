import 'dart:convert';
import 'dart:math' as math;

import 'package:sard_agents/sard_agents.dart' show Urgency;
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

double distM(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  double rad(double x) => x * math.pi / 180;
  final a =
      math.pow(math.sin(rad(la2 - la1) / 2), 2) +
      math.cos(rad(la1)) * math.cos(rad(la2)) * math.pow(math.sin(rad(lo2 - lo1) / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

String sig(SynthDataset d) => d.reports.map((r) => r.signature).join('\n');

void main() {
  final d1 = generateDataset(SynthConfig(seed: 1));

  group('conjunto de T06/T07: 1 000 reportes en 80 sucesos y 20 pares adversariales', () {
    test('misma semilla, mismo conjunto; otra semilla, otro', () {
      expect(sig(generateDataset(SynthConfig(seed: 1))), sig(d1));
      expect(sig(generateDataset(SynthConfig(seed: 2))), isNot(sig(d1)));
    });

    test('exactamente 1 000 reportes en 80 sucesos base', () {
      final base = d1.reports.where((r) => !r.tags.contains('gemelo')).toList();
      expect(base, hasLength(1000));
      expect(base.map((r) => r.trueIncident).toSet(), {for (var i = 0; i < 80; i++) i});
    });

    test('cada suceso base tiene al menos 2 dispositivos distintos', () {
      for (var i = 0; i < 80; i++) {
        final devs = d1.reports.where((r) => r.trueIncident == i).map((r) => r.deviceId).toSet();
        expect(devs.length, greaterThanOrEqualTo(2), reason: 'suceso $i');
      }
    });

    test('20 gemelos adversariales: otro suceso, cerca en espacio y tiempo, mismo tipo', () {
      final twins = d1.incidents.values.where((i) => i.twinOf != null).toList();
      expect(twins, hasLength(20));
      for (final t in twins) {
        final b = d1.incidents[t.twinOf]!;
        expect(t.id, isNot(b.id));
        final dm = distM(t.lat, t.lon, b.lat, b.lon);
        expect(dm, inInclusiveRange(60, 250), reason: 'gemelo ${t.id}');
        expect((t.startMs - b.startMs).abs(), lessThanOrEqualTo(10 * 60 * 1000));
        expect(t.type, b.type);
        expect(d1.reports.where((r) => r.trueIncident == t.id), hasLength(5));
      }
    });
  });

  group('verdad de referencia y casos difíciles (fijados ANTES de escribir ninguna regla)', () {
    test(
      'las fracciones de los reportes de sucesos P1 coinciden con las fijadas (±4 puntos, 5 semillas)',
      () {
        final counts = <String, int>{};
        var total = 0;
        for (final seed in [1, 2, 3, 4, 5]) {
          final d = generateDataset(SynthConfig(seed: seed));
          for (final r in d.reports.where(
            (r) => r.trueUrgency == Urgency.p1 && !r.tags.contains('gemelo'),
          )) {
            counts[r.subgroup] = (counts[r.subgroup] ?? 0) + 1;
            total++;
          }
        }
        double pct(String k) => 100 * (counts[k] ?? 0) / total;
        expect(pct('banderas_coherentes'), closeTo(55, 4));
        expect(pct('parcial_con_texto'), closeTo(20, 4));
        expect(pct('sin_banderas_con_texto'), closeTo(10, 4));
        expect(pct('sin_pistas'), closeTo(10, 4));
        expect(pct('banderas_equivocadas'), closeTo(5, 4));
      },
    );

    test('la urgencia verdadera sale del estado latente, no de las banderas marcadas', () {
      final p1SinBanderas = d1.reports.where((r) => r.trueUrgency == Urgency.p1 && r.flags == 0);
      expect(
        p1SinBanderas,
        isNotEmpty,
        reason: 'hay P1 sin ninguna bandera: las banderas no bastan',
      );
      expect(
        d1.reports
            .where((r) => r.subgroup == 'sin_pistas')
            .every((r) => r.text == null && r.flags == 0),
        isTrue,
      );
    });

    test(
      'hay reportes sin ubicación, imprecisos, sin texto, parafraseados, con faltas y con reloj desfasado',
      () {
        bool has(String tag) => d1.reports.any((r) => r.tags.contains(tag));
        for (final t in [
          'sin_ubicacion',
          'ubicacion_imprecisa',
          'sin_texto',
          'con_texto',
          'parafraseado',
          'con_faltas',
          'reloj_desfasado',
        ]) {
          expect(has(t), isTrue, reason: t);
        }
        expect(
          d1.reports
              .where((r) => r.tags.contains('sin_ubicacion'))
              .every((r) => r.lat == null && r.locQuality == LocQuality.none),
          isTrue,
        );
      },
    );

    test('hay reportes repetidos del mismo dispositivo (SOS repetido) dentro de un suceso', () {
      final byInc = <int, List<String>>{};
      for (final r in d1.reports.where((r) => !r.tags.contains('gemelo'))) {
        (byInc[r.trueIncident] ??= []).add(r.deviceId);
      }
      expect(byInc.values.any((l) => l.length != l.toSet().length), isTrue);
    });

    test('todo texto cabe en 140 bytes UTF-8 y los subgrupos son los esperados', () {
      const ok = {
        'banderas_coherentes',
        'parcial_con_texto',
        'sin_banderas_con_texto',
        'sin_pistas',
        'banderas_equivocadas',
        'no_p1',
      };
      for (final r in d1.reports) {
        if (r.text != null) expect(utf8.encode(r.text!).length, lessThanOrEqualTo(140));
        expect(ok, contains(r.subgroup));
      }
    });

    test(
      'hay sucesos de las cuatro urgencias, y textos con negación («sin heridos») en los no P1',
      () {
        expect(d1.incidents.values.map((i) => i.urgency).toSet(), Urgency.values.toSet());
        expect(
          d1.reports.any(
            (r) =>
                r.trueUrgency != Urgency.p1 && (r.text ?? '').toLowerCase().contains('sin heridos'),
          ),
          isTrue,
        );
      },
    );
  });

  group('rumor y corroboración (T08)', () {
    test('1 000 copias casi idénticas desde 3 dispositivos, clase radio, sin ubicación', () {
      final r = generateRumor(copies: 1000, sources: 3, seed: 1);
      expect(r, hasLength(1000));
      expect(r.map((x) => x.deviceId).toSet(), hasLength(3));
      expect(r.every((x) => x.sourceClass == 'radio' && x.lat == null), isTrue);
      expect(
        r.map((x) => x.text).toSet().length,
        lessThanOrEqualTo(6),
        reason: 'copias casi idénticas',
      );
    });

    test(
      '5 fuentes independientes: dispositivos distintos, texto propio, con ubicación, clase app',
      () {
        final c = generateCorroboration(sources: 5, seed: 1);
        expect(c, hasLength(5));
        expect(c.map((x) => x.deviceId).toSet(), hasLength(5));
        expect(c.map((x) => x.text).toSet(), hasLength(5), reason: 'cada quien con sus palabras');
        expect(c.every((x) => x.sourceClass == 'app' && x.lat != null), isTrue);
      },
    );
  });
}
