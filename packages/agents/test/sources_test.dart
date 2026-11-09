import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

const double _lat = 5.07, _lon = -75.52;
final int _t0 = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;
double _east(double m) => _lon + m / (111320.0 * cos(_lat * pi / 180));

Observation o(
  String key,
  String device, {
  String? text,
  double? eastM = 0,
  int dtMs = 0,
  String cls = 'app',
  LocQuality q = LocQuality.within50m,
}) => Observation(
  reportKey: key,
  deviceId: device,
  incidentType: 1,
  flags: 0,
  lat: eastM == null ? null : _lat,
  lon: eastM == null ? null : _east(eastM),
  locQuality: eastM == null ? LocQuality.none : q,
  capturedAtMs: _t0 + dtMs,
  text: text,
  sourceClass: cls,
);

void main() {
  group('rumor frente a corroboración (T08)', () {
    final rumor = [
      for (var i = 0; i < 1000; i++)
        o(
          'r$i',
          'radio-${i % 3}',
          text: 'dicen por la radio que el puente de la calle veinte colapsó, que nadie pase',
          eastM: null,
          dtMs: i * 7000,
          cls: 'radio',
        ),
    ];
    const palabras = [
      'el puente de la calle veinte se partió por la mitad',
      'vi caer la mitad del puente, hay carros abajo',
      'puente colapsado en la veinte, gente atrapada en un bus',
      'se cayó el puente, ayuden a los del bus',
      'colapso del puente frente a la gasolinera, hay heridos',
    ];
    final corroboracion = [for (var i = 0; i < 5; i++) o('c$i', 'app-$i', text: palabras[i], eastM: i * 15.0, dtMs: i * 120000)];

    test('1 000 copias de 3 dispositivos son UNA sola fuente independiente', () {
      final a = assessGroup(rumor);
      expect(a.reports, 1000);
      expect(a.devices, 3);
      expect(a.independentSources, 1);
      expect(a.uncertainty, containsAll(['fuente_unica', 'fuente_no_independiente']));
      expect(a.confidence, closeTo(0.20, 1e-9));
    });

    test('5 fuentes independientes con texto propio y ubicación: confianza ≈ 1 − 0,4⁵', () {
      final a = assessGroup(corroboracion);
      expect(a.independentSources, 5);
      expect(a.uncertainty, isNot(contains('fuente_unica')));
      expect(a.uncertainty, isNot(contains('fuente_no_independiente')));
      expect(a.confidence, closeTo(1 - pow(0.4, 5), 1e-9));
    });

    test('T08: la confianza del rumor es menor que la de la corroboración', () {
      expect(assessGroup(rumor).confidence, lessThan(assessGroup(corroboracion).confidence));
    });
  });

  group('qué cuenta como una fuente', () {
    test('un dispositivo que manda 50 SOS cuenta UNA fuente y su confianza es la de una', () {
      final a = assessGroup([for (var i = 0; i < 50; i++) o('s$i', 'dev-1', text: 'ayuda atrapados bajo la losa', dtMs: i * 1000)]);
      expect(a.reports, 50);
      expect(a.devices, 1);
      expect(a.independentSources, 1);
      expect(a.confidence, closeTo(0.6, 1e-9));
      expect(a.uncertainty, contains('fuente_unica'));
    });

    test('textos casi idénticos de dispositivos distintos pero LEJOS en el tiempo no forman familia', () {
      const t = 'puente colapsado en la calle veinte hay carros abajo';
      final a = assessGroup([o('a', 'd1', text: t), o('b', 'd2', text: t, dtMs: 3 * 3600000)]);
      expect(a.independentSources, 2);
    });

    test('las mismas palabras en lugares distintos y lejanos no se tratan como copia', () {
      const t = 'hay heridos y fuego en el edificio de la esquina';
      final a = assessGroup([o('a', 'd1', text: t), o('b', 'd2', text: t, eastM: 8000)]);
      expect(a.independentSources, 2);
    });

    test('copias cercanas en el espacio y el tiempo SÍ son una familia', () {
      const t = 'hay heridos y fuego en el edificio de la esquina';
      final a = assessGroup([o('a', 'd1', text: t), o('b', 'd2', text: t, eastM: 20, dtMs: 60000)]);
      expect(a.independentSources, 1);
      expect(a.uncertainty, contains('fuente_no_independiente'));
    });

    test('textos cortos o sin palabras de contenido no cuentan como copia (no hay nada que copiar)', () {
      final a = assessGroup([o('a', 'd1', text: 'ayuda'), o('b', 'd2', text: 'ayuda', dtMs: 1000)]);
      expect(a.independentSources, 2);
    });

    test('la familia vale lo que su origen más creíble: una copia de radio sobre un reporte de la app es app', () {
      const t = 'el puente de la calle veinte se partió por la mitad hay carros abajo';
      final a = assessGroup([o('a', 'dev-app', text: t), o('b', 'dev-radio', text: t, cls: 'radio', eastM: null, dtMs: 30000)]);
      expect(a.independentSources, 1);
      expect(a.confidence, closeTo(0.6, 1e-9));
    });
  });

  group('incertidumbre del grupo y bordes', () {
    test('sin ningún miembro con ubicación ⇒ ubicacion_ausente', () {
      final a = assessGroup([o('a', 'd1', text: 'sin ubicación uno', eastM: null), o('b', 'd2', text: 'otro texto distinto', eastM: null)]);
      expect(a.uncertainty, contains('ubicacion_ausente'));
    });

    test('con ubicación en alguno no se marca ubicacion_ausente', () {
      expect(assessGroup([o('a', 'd1', text: 'uno'), o('b', 'd2', text: 'dos otro', eastM: null)]).uncertainty, isNot(contains('ubicacion_ausente')));
    });

    test('sin modelo las contradicciones quedan «no evaluadas» y así se dice', () {
      expect(assessGroup([o('a', 'd1', text: 'algo')]).contradictionsEvaluated, isFalse);
    });

    test('un grupo vacío tiene confianza 0 y ninguna fuente', () {
      final a = assessGroup(const []);
      expect(a.independentSources, 0);
      expect(a.confidence, 0.0);
    });

    test('la confianza siempre está en [0,1] y crece al añadir fuentes independientes', () {
      var prev = 0.0;
      for (var n = 1; n <= 8; n++) {
        final a = assessGroup([for (var i = 0; i < n; i++) o('k$i', 'd$i', text: 'texto numero ${i * 17} unico ${i * 31}', eastM: i * 5.0)]);
        expect(a.confidence, inInclusiveRange(0.0, 1.0));
        expect(a.confidence, greaterThan(prev));
        prev = a.confidence;
      }
    });

    test('es independiente del orden de los miembros', () {
      final xs = [for (var i = 0; i < 12; i++) o('k$i', 'd${i % 4}', text: i.isEven ? 'puente colapsado calle veinte' : 'texto propio numero $i', dtMs: i * 5000)];
      final a = assessGroup(xs), b = assessGroup(xs.reversed.toList());
      expect(b.independentSources, a.independentSources);
      expect(b.confidence, closeTo(a.confidence, 1e-12));
    });
  });

  group('rendimiento: casi todos los grupos son de un solo reporte', () {
    test('evaluar 6 000 grupos de un reporte cuesta menos de 400 ms', () {
      final single = [for (var i = 0; i < 6000; i++) o('k$i', 'd$i', text: 'texto numero $i con varias palabras distintas aqui', eastM: i % 7 == 0 ? null : i * 3.0)];
      final sw = Stopwatch()..start();
      for (final m in single) {
        assessGroup([m]);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(400), reason: 'tardó ${sw.elapsedMilliseconds} ms');
    });

    test('un grupo de un solo reporte: una fuente, la credibilidad de su clase, fuente_unica', () {
      final a = assessGroup([o('a', 'd1', text: 'algo', cls: 'radio')]);
      expect(a.independentSources, 1);
      expect(a.devices, 1);
      expect(a.confidence, closeTo(0.2, 1e-9));
      expect(a.uncertainty, contains('fuente_unica'));
      final b = assessGroup([o('b', 'd1', text: 'algo', eastM: null)]);
      expect(b.uncertainty, containsAll(['fuente_unica', 'ubicacion_ausente']));
    });
  });
}
