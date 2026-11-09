import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

const double _lat = 5.07, _lon = -75.52;
final int _t0 = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;

/// Desplaza un punto [m] metros al este.
double _east(double m) => _lon + m / (111320.0 * cos(_lat * pi / 180));

Observation obs(
  String key, {
  String device = 'dev',
  double? eastM = 0,
  LocQuality q = LocQuality.within50m,
  int dtMs = 0,
  int type = 1,
  String? text,
  String cls = 'app',
}) =>
    Observation(
      reportKey: key,
      deviceId: device,
      incidentType: type,
      flags: 0,
      lat: eastM == null ? null : _lat,
      lon: eastM == null ? null : _east(eastM),
      locQuality: eastM == null ? LocQuality.none : q,
      capturedAtMs: _t0 + dtMs,
      text: text,
      sourceClass: cls,
    );

void main() {
  group('término espacial: la distancia se mide RELATIVA a la precisión declarada', () {
    test('a 40 m con precisión ±50 m cada uno (suma 100 m) son compatibles', () {
      final p = scorePair(obs('a'), obs('b', eastM: 40));
      expect(p.terms['espacial'], closeTo(0.6, 0.02));
    });

    test('a 40 m con precisión ±10 m (suma 20 m) NO son compatibles', () {
      final p = scorePair(obs('a', q: LocQuality.within10m), obs('b', eastM: 40, q: LocQuality.within10m));
      expect(p.terms['espacial'], 0.0);
    });

    test('a 400 m con ±50 m no son compatibles; el mismo punto da 1', () {
      expect(scorePair(obs('a'), obs('b', eastM: 400)).terms['espacial'], 0.0);
      expect(scorePair(obs('a'), obs('b', eastM: 0)).terms['espacial'], 1.0);
    });
  });

  group('demás términos', () {
    test('tiempo: Δt = 0 ⇒ 1; Δt = τ (30 min) ⇒ e⁻¹; reloj desfasado no da negativos y es simétrico', () {
      expect(scorePair(obs('a'), obs('b')).terms['temporal'], 1.0);
      expect(scorePair(obs('a'), obs('b', dtMs: 30 * 60000)).terms['temporal'], closeTo(exp(-1), 1e-9));
      final fwd = scorePair(obs('a'), obs('b', dtMs: 3 * 3600000));
      final back = scorePair(obs('b', dtMs: 3 * 3600000), obs('a'));
      expect(fwd.terms['temporal'], closeTo(back.terms['temporal']!, 1e-12));
      expect(fwd.terms['temporal'], inInclusiveRange(0.0, 0.01));
    });

    test('tipo: igual ⇒ 1, distinto ⇒ 0', () {
      expect(scorePair(obs('a', type: 2), obs('b', type: 2)).terms['tipo'], 1.0);
      expect(scorePair(obs('a', type: 2), obs('b', type: 3)).terms['tipo'], 0.0);
    });

    test('texto: idéntico ⇒ 1; si a uno le falta ⇒ 0', () {
      expect(scorePair(obs('a', text: 'puente colapsado calle veinte'), obs('b', text: 'puente colapsado calle veinte')).terms['texto'], 1.0);
      expect(scorePair(obs('a', text: 'puente colapsado'), obs('b')).terms['texto'], 0.0);
    });
  });

  group('decisión tri-estado con los pesos del PDF (0,40 · 0,15 · 0,15 · 0,30; θhi 0,80; θlo 0,55)', () {
    test('mismo punto, misma hora, mismo tipo y mismo texto ⇒ same (puntaje 1,0)', () {
      final p = scorePair(obs('a', text: 'puente colapsado calle veinte'), obs('b', text: 'puente colapsado calle veinte'));
      expect(p.score, closeTo(1.0, 1e-9));
      expect(p.state, LinkState.same);
    });

    test('lo mismo pero sin texto: 0,40+0,15+0,15 = 0,70 ⇒ possible (nunca same sin texto que lo respalde)', () {
      final p = scorePair(obs('a'), obs('b'));
      expect(p.score, closeTo(0.70, 1e-9));
      expect(p.state, LinkState.possible);
    });

    test('lejos pero con la misma hora, tipo y texto: 0,60 ⇒ possible, jamás same', () {
      final p = scorePair(obs('a', text: 'puente colapsado calle veinte'), obs('b', eastM: 5000, text: 'puente colapsado calle veinte'));
      expect(p.score, closeTo(0.60, 1e-9));
      expect(p.state, LinkState.possible);
    });

    test('otro tipo, lejos, una hora después y sin texto ⇒ different', () {
      final p = scorePair(obs('a'), obs('b', eastM: 5000, dtMs: 3600000, type: 2));
      expect(p.state, LinkState.different);
    });

    test('es simétrica: scorePair(a,b) == scorePair(b,a) con datos al azar', () {
      final r = Random(7);
      for (var i = 0; i < 200; i++) {
        final a = obs('a$i', eastM: r.nextBool() ? r.nextDouble() * 300 : null, dtMs: r.nextInt(7200000), type: 1 + r.nextInt(3), text: r.nextBool() ? 'puente colapsado ${r.nextInt(4)}' : null);
        final b = obs('b$i', eastM: r.nextBool() ? r.nextDouble() * 300 : null, dtMs: r.nextInt(7200000), type: 1 + r.nextInt(3), text: r.nextBool() ? 'puente caído ${r.nextInt(4)}' : null);
        final p = scorePair(a, b), q = scorePair(b, a);
        expect(p.score, closeTo(q.score, 1e-12));
        expect(p.state, q.state);
        expect(p.score.isNaN, isFalse);
        expect(p.score, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('sin ubicación: umbral más estricto y marca ubicacion_ausente', () {
    test('texto idéntico, misma hora y tipo ⇒ same (puntaje renormalizado 1,0 ≥ 0,92)', () {
      final p = scorePair(obs('a', eastM: null, text: 'puente colapsado calle veinte'), obs('b', eastM: null, text: 'puente colapsado calle veinte'));
      expect(p.state, LinkState.same);
      expect(p.uncertainty, contains('ubicacion_ausente'));
    });

    test('con sólo uno sin ubicación no se puede usar la distancia: el otro cuenta como sin ubicación', () {
      final p = scorePair(obs('a', eastM: null, text: 'puente colapsado calle veinte'), obs('b', text: 'puente colapsado calle veinte'));
      expect(p.uncertainty, contains('ubicacion_ausente'));
      expect(p.terms.containsKey('espacial'), isFalse);
    });

    test('sin texto no hay nada con qué agrupar: nunca pasa de possible', () {
      expect(scorePair(obs('a', eastM: null), obs('b', eastM: null)).state, isNot(LinkState.same));
    });

    test('textos parecidos pero no idénticos quedan en possible, no en same', () {
      final p = scorePair(
        obs('a', eastM: null, text: 'puente colapsado calle veinte hay carros abajo'),
        obs('b', eastM: null, text: 'puente colapsado calle veinte ayuda urgente por favor'),
      );
      expect(p.state, isNot(LinkState.same));
    });

    test('sin ubicación por la calidad «ninguna» aunque vengan coordenadas viejas', () {
      final a = Observation(
        reportKey: 'a', deviceId: 'd', incidentType: 1, flags: 0, lat: _lat, lon: _lon, locQuality: LocQuality.none,
        capturedAtMs: _t0, text: 'x', sourceClass: 'app',
      );
      expect(scorePair(a, obs('b')).uncertainty, contains('ubicacion_ausente'));
    });
  });

  test('ubicación imprecisa (σ ≥ 1 km) se marca ubicacion_imprecisa', () {
    final p = scorePair(obs('a', q: LocQuality.over1km), obs('b'));
    expect(p.uncertainty, contains('ubicacion_imprecisa'));
  });
}
