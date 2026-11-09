import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

Map<String, Object?> it(String key, {String urgency = 'P2', String group = 'g1', int size = 2, String groupUrgency = 'P2', List<String> signals = const ['atrapado'], int receivedAt = 100, int capturedAt = 50, int sources = 2, double confidence = 0.84, List<String> uncertainty = const []}) => {
  'reportKey': key,
  'urgency': urgency,
  'group': group,
  'groupSize': size,
  'groupUrgency': groupUrgency,
  'signals': signals,
  'receivedAt': receivedAt,
  'capturedAt': capturedAt,
  'sources': sources,
  'confidence': confidence,
  'uncertainty': uncertainty,
  'rev': 0,
  'flags': 0x80,
  'lat': 5.07,
  'lon': -75.5,
  'text': null,
  'similar': <String>[],
  'escalate': false,
};

void main() {
  final base = [it('a-1'), it('b-1'), it('c-1', group: 'g2', size: 1, sources: 1, confidence: 0.6)];

  test('es igual con las mismas proyecciones aunque cambien el ORDEN y los RELOJES (llegada, captura)', () {
    final other = [
      it('c-1', group: 'g2', size: 1, sources: 1, confidence: 0.6, receivedAt: 999, capturedAt: 7),
      it('b-1', receivedAt: 5, capturedAt: 1),
      it('a-1', receivedAt: 6, capturedAt: 2),
    ];
    expect(projectionFingerprint(other), projectionFingerprint(base));
  });

  test('NO depende de cómo se llamen los grupos: sólo de quién está con quién', () {
    final renamed = [it('a-1', group: 'zzz'), it('b-1', group: 'zzz'), it('c-1', group: 'otro', size: 1, sources: 1, confidence: 0.6)];
    expect(projectionFingerprint(renamed), projectionFingerprint(base));
  });

  test('cambia si cambia la urgencia de un reporte', () {
    expect(projectionFingerprint([it('a-1', urgency: 'P1'), base[1], base[2]]), isNot(projectionFingerprint(base)));
  });

  test('cambia si cambia quién está con quién (un reporte pasa de grupo)', () {
    final moved = [it('a-1'), it('b-1', group: 'g2', size: 2), it('c-1', group: 'g2', size: 2)];
    expect(projectionFingerprint(moved), isNot(projectionFingerprint(base)));
  });

  test('cambia si falta un reporte o sobra uno', () {
    expect(projectionFingerprint(base.take(2).toList()), isNot(projectionFingerprint(base)));
    expect(projectionFingerprint([...base, it('d-1', group: 'g3', size: 1)]), isNot(projectionFingerprint(base)));
  });

  test('cambian las señales, la confianza o la incertidumbre (lo que ve el coordinador)', () {
    expect(projectionFingerprint([it('a-1', signals: const ['herido']), base[1], base[2]]), isNot(projectionFingerprint(base)));
    expect(projectionFingerprint([it('a-1', confidence: 0.99), base[1], base[2]]), isNot(projectionFingerprint(base)));
    expect(projectionFingerprint([it('a-1', uncertainty: const ['fuente_unica']), base[1], base[2]]), isNot(projectionFingerprint(base)));
  });

  test('la confianza se redondea (no hay falsas diferencias por coma flotante) y el orden de señales no importa', () {
    expect(projectionFingerprint([it('a-1', confidence: 0.84 + 1e-12), base[1], base[2]]), projectionFingerprint(base));
    expect(projectionFingerprint([it('a-1', signals: const ['herido', 'atrapado']), base[1], base[2]]), projectionFingerprint([it('a-1', signals: const ['atrapado', 'herido']), base[1], base[2]]));
  });

  test('es un SHA-256 en hexadecimal (64 caracteres) y la cola vacía tiene una huella propia', () {
    expect(projectionFingerprint(base), matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(projectionFingerprint(const []), isNot(projectionFingerprint(base)));
  });
}
