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

  group('con incidentes (recomendación y aprobación entran en la huella)', () {
    Map<String, Object?> inc(String id, {List<String> members = const ['a-1'], String urgency = 'P2', List<String> signals = const ['atrapado'], String recState = 'propuesta', String recId = '0123456789abcdef', List<String> actions = const ['rescate'], List<String> resources = const ['RES-01'], List<String> pending = const [], String approval = 'pendiente', bool discrepancy = false, int firstAt = 100, int lastAt = 100, int receivedAt = 5000, int size = 1}) => {
      'id': id,
      'members': members,
      'size': size,
      'urgency': urgency,
      'signals': signals,
      'recommendation': {'state': recState, 'id': recId, 'actions': actions, 'resourceIds': resources, 'pending': pending},
      'approval': {'status': approval, 'discrepancy': discrepancy, 'decisions': 0},
      'firstAt': firstAt,
      'lastAt': lastAt,
      'receivedAt': receivedAt,
    };
    final q = [it('a-1'), it('b-1')];
    final base = [inc('a-1'), inc('b-1', members: ['b-1'], recId: 'fedcba9876543210')];

    test('mismos incidentes ⇒ misma huella, aunque cambie el orden y los relojes (captura, llegada)', () {
      final other = [inc('b-1', members: ['b-1'], recId: 'fedcba9876543210', firstAt: 9, lastAt: 9, receivedAt: 1), inc('a-1', firstAt: 7, lastAt: 8, receivedAt: 2)];
      expect(projectionFingerprint(q, incidents: other), projectionFingerprint(q, incidents: base));
    });

    test('no depende de cómo se llame el incidente, sólo de quiénes lo forman', () {
      expect(projectionFingerprint(q, incidents: [inc('zzz'), inc('b-1', members: ['b-1'], recId: 'fedcba9876543210')]), projectionFingerprint(q, incidents: base));
    });

    test('incluir incidentes cambia la huella respecto de no incluirlos', () {
      expect(projectionFingerprint(q, incidents: base), isNot(projectionFingerprint(q)));
    });

    test('cambia si cambia la recomendación: acción, recursos, requisitos pendientes o estado', () {
      final h = projectionFingerprint(q, incidents: base);
      expect(projectionFingerprint(q, incidents: [inc('a-1', actions: const ['bomberos']), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', resources: const ['RES-02']), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', pending: const ['confirmar_personas']), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', recState: 'informacion_requerida'), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', recId: 'ffffffffffffffff'), base[1]]), isNot(h));
    });

    test('cambia si cambia la aprobación o su discrepancia', () {
      final h = projectionFingerprint(q, incidents: base);
      expect(projectionFingerprint(q, incidents: [inc('a-1', approval: 'aprobada'), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', approval: 'denegada', discrepancy: true), base[1]]), isNot(projectionFingerprint(q, incidents: [inc('a-1', approval: 'denegada'), base[1]])));
    });

    test('cambia si cambia quién forma el incidente o su urgencia', () {
      final h = projectionFingerprint(q, incidents: base);
      expect(projectionFingerprint(q, incidents: [inc('a-1', members: const ['a-1', 'c-1'], size: 2), base[1]]), isNot(h));
      expect(projectionFingerprint(q, incidents: [inc('a-1', urgency: 'P1'), base[1]]), isNot(h));
    });
  });
}
