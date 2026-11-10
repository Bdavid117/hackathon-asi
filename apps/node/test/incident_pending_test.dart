import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Un incidente sintético con su recomendación y el estado de su aprobación.
IncidentData fakeDecision(String id, Urgency u, {String rec = 'propuesta', String approval = 'pendiente', bool discrepancy = false, int firstAt = 1000}) => IncidentData(
  id: id,
  urgency: u,
  firstAt: firstAt,
  summary: {
    'id': id,
    'urgency': u.name.toUpperCase(),
    'size': 1,
    'bareSos': false,
    'highUncertainty': false,
    'needsReview': false,
    'firstAt': firstAt,
    'lastAt': firstAt,
    'recommendation': {'state': rec},
    'approval': {'status': approval, 'discrepancy': discrepancy, 'decisions': approval == 'pendiente' ? 0 : 1},
  },
  detail: {'id': id},
);

Map<String, Object?> pageOf(IncidentIndex ix, {String view = 'all', String? urgency, bool? pending}) =>
    (jsonDecode(ix.page(view: view, urgency: urgency, pending: pending)) as Map).cast<String, Object?>();

Map<String, Object?> countersOf(IncidentIndex ix) => (pageOf(ix, view: 'short')['counters']! as Map).cast<String, Object?>();

List<String> idsOf(Map<String, Object?> p) => [for (final i in p['items']! as List) (i as Map)['id']! as String];

void main() {
  group('«pendiente de decisión»: una propuesta que todavía espera a una persona', () {
    final ix = IncidentIndex.build([
      fakeDecision('pend', Urgency.p1, firstAt: 500),
      fakeDecision('cad', Urgency.p2, approval: 'caduca', firstAt: 300),
      fakeDecision('ok', Urgency.p1, approval: 'aprobada', firstAt: 100),
      fakeDecision('no', Urgency.p2, approval: 'denegada', firstAt: 150),
      fakeDecision('disc', Urgency.p1, approval: 'denegada', discrepancy: true, firstAt: 50),
      fakeDecision('disc2', Urgency.p2, approval: 'caduca', discrepancy: true, firstAt: 40),
      fakeDecision('info', Urgency.p3, rec: 'informacion_requerida', firstAt: 10),
      fakeDecision('desc', Urgency.p3, rec: 'descartada', firstAt: 20),
    ]);

    test('cuenta las propuestas pendientes y las caducadas; no las aprobadas, las rechazadas ni lo que no es una propuesta', () {
      expect(countersOf(ix)['pendingDecision'], 2);
    });

    test('las decisiones contradictorias van aparte: no son «pendientes», pero tampoco se esconden', () {
      expect(countersOf(ix)['discrepancies'], 2);
    });

    test('dice desde cuándo espera la más antigua (la hora, no la edad: la edad la calcula quien lee)', () {
      expect(countersOf(ix)['pendingOldestAt'], 300);
    });

    test('sin pendientes no inventa una hora', () {
      final none = IncidentIndex.build([fakeDecision('ok', Urgency.p1, approval: 'aprobada')]);
      expect(countersOf(none)['pendingDecision'], 0);
      expect(countersOf(none)['pendingOldestAt'], isNull);
    });

    test('pending=true en la vista completa trae sólo los pendientes, en el orden de siempre', () {
      expect(idsOf(pageOf(ix, pending: true)), ['pend', 'cad'], reason: 'primero el más grave (P1 antes que P2)');
    });

    test('pending=false trae todo lo demás', () {
      expect(idsOf(pageOf(ix, pending: false)).toSet(), {'ok', 'no', 'disc', 'disc2', 'info', 'desc'});
    });

    test('se combina con la urgencia', () {
      expect(idsOf(pageOf(ix, urgency: 'P2', pending: true)), ['cad']);
    });

    test('la vista corta no admite el filtro (si no, un P1 podría quedar fuera)', () {
      expect(() => ix.page(view: 'short', pending: true), throwsArgumentError);
    });

    test('un incidente sin recomendación ni aprobación en la fila no rompe nada ni cuenta como pendiente', () {
      final raw = IncidentData(id: 'x', urgency: Urgency.p3, firstAt: 1, summary: {'id': 'x', 'urgency': 'P3', 'size': 1, 'bareSos': false, 'highUncertainty': false, 'needsReview': false, 'firstAt': 1, 'lastAt': 1}, detail: {'id': 'x'});
      final r = IncidentIndex.build([raw]);
      expect(countersOf(r)['pendingDecision'], 0);
    });
  });

  group('GET /api/incidents?view=all&pending=…', () {
    late EventLog log;
    late Handler handler;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
    });
    tearDown(() => log.close());

    Future<Response> get(String path) => Future.sync(() => handler(Request('GET', Uri.parse('http://localhost$path'))));

    test('acepta pending=true y pending=false', () async {
      expect((await get('/api/incidents?view=all&pending=true')).statusCode, 200);
      expect((await get('/api/incidents?view=all&pending=false')).statusCode, 200);
    });

    test('un valor que no es true ni false es un 400, y en la vista corta también', () async {
      expect((await get('/api/incidents?view=all&pending=quizas')).statusCode, 400);
      expect((await get('/api/incidents?pending=true')).statusCode, 400);
    });
  });
}
