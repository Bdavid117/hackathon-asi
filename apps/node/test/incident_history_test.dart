import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'log_support.dart';
import 'support.dart';

/// Un evento escrito a mano, con su origen, su número y su hora (la parte física del `hlc` es en milisegundos).
Event ev(String type, {String origin = 'A', int seq = 1, int ms = 1000, String? key, int rev = 0, Map<String, Object?> body = const {}, List<String> inputs = const []}) => Event(
  id: '$origin:${seq.toString().padLeft(6, '0')}',
  origin: origin,
  seq: seq,
  type: type,
  reportKey: key,
  rev: rev,
  hlc: '$ms-$seq-$origin',
  body: body,
  inputs: inputs,
);

/// Lo mínimo del detalle que la historia lee: identificador, miembros y recomendación.
Map<String, Object?> detailOf({List<String> members = const ['aa-1'], String id = 'aa-1', String recId = 'rec-1', List<String> resourceIds = const ['AMB-01'], int sources = 1, int contradictions = 0}) => {
  'id': id,
  'members': members,
  'membersTotal': members.length,
  'sources': sources,
  'contradictions': [for (var i = 0; i < contradictions; i++) {'kind': 'negacion'}],
  'recommendation': {'state': 'propuesta', 'id': recId, 'actions': ['enviar_rescate'], 'pending': ['confirmar_segunda_fuente'], 'resourceIds': resourceIds},
};

Event recv(String key, {String origin = 'A', int seq = 1, int ms = 1000, int rev = 0}) => ev('report.received', origin: origin, seq: seq, ms: ms, key: key, rev: rev, body: {'text': 'TEXTO-SECRETO-DEL-CIUDADANO', 'channel': 'app', 'lat': 5.07, 'lon': -75.51});
Event normalized(String key, {String origin = 'A', int seq = 2, int ms = 1100}) => ev('report.normalized', origin: origin, seq: seq, ms: ms, key: key, body: {'missing': <String>[], 'text': 'TEXTO-SECRETO-DEL-CIUDADANO'});
Event triage(String key, {String origin = 'A', int seq = 3, int ms = 1200, String mode = 'rules', String version = 'rules-1', String urgency = 'P1'}) =>
    ev('triage.assessed', origin: origin, seq: seq, ms: ms, key: key, body: {'urgency': urgency, 'mode': mode, 'agent_version': version, 'analyzed_text': 'TEXTO-SECRETO-DEL-CIUDADANO'});
Event approval(String who, {String rec = 'rec-1', bool granted = true, String origin = 'A', int seq = 10, int ms = 5000, List<String> supersedes = const [], String note = ''}) =>
    ev(granted ? 'approval.granted' : 'approval.denied', origin: origin, seq: seq, ms: ms, key: 'aa-1', body: {'recommendationId': rec, 'incidentId': 'aa-1', 'members': ['aa-1'], 'who': who, 'note': note}, inputs: supersedes);
Event unitDeclared(String unit, {bool available = false, String who = 'Ana', int seq = 20, int ms = 6000, String origin = 'A'}) =>
    ev('resource.declared', origin: origin, seq: seq, ms: ms, key: 'res-$unit', body: {'resource': {'id': unit, 'kind': 'ambulancia', 'label': 'x', 'lat': 5.0, 'lon': -75.0, 'available': available}, 'declared_by': who});

IncidentHistory build(Map<String, Object?> detail, {List<Event> member = const [], List<Event> approvals = const [], List<Event> units = const [], int maxSteps = 60}) =>
    buildIncidentHistory(detail: detail, memberEvents: member, approvalEvents: approvals, resourceEvents: units, maxSteps: maxSteps);

void main() {
  group('buildIncidentHistory (función pura)', () {
    test('un paso respaldado por un evento lleva su nodo y su hora; uno derivado no lleva hora', () {
      final h = build(detailOf(), member: [recv('aa-1', origin: 'B', seq: 7, ms: 4242), triage('aa-1')]);
      final r = h.steps.firstWhere((s) => s.kind == 'recibido');
      expect((r.agent, r.nodeId, r.atMs, r.derived), ('1 · Recepción', 'B', 4242, false));
      expect(r.eventIds, ['B:000007']);
      final derived = h.steps.where((s) => s.derived).toList();
      expect(derived, isNotEmpty, reason: 'el agrupamiento y la recomendación se calculan al leer y salen rotulados');
      for (final d in derived) {
        expect(d.atMs, isNull, reason: d.summary);
        expect(d.nodeId, isNull);
        expect(d.eventIds, isEmpty);
      }
      expect(derived.map((d) => d.agent), containsAll(['3 · Correlación', '6 · Coordinación']));
    });

    test('el triaje del modelo se distingue del de reglas (mode rules+llm) y nombra agent_version', () {
      final h = build(detailOf(), member: [triage('aa-1', seq: 3), triage('aa-1', seq: 4, ms: 1300, mode: 'rules+llm', version: 'llm-1')]);
      final tri = h.steps.where((s) => s.agent == '2 · Triaje').toList();
      expect(tri, hasLength(2));
      expect(tri.first.summary, contains('reglas'));
      expect(tri.first.summary, isNot(contains('modelo')));
      expect(tri.last.summary, contains('modelo'));
      expect(tri.last.summary, contains('llm-1'));
      expect(tri.first.summary, contains('rules-1'));
    });

    test('un evento replicado desde otro nodo muestra ese nodo de origen, no el que sirve el detalle', () {
      final h = build(detailOf(), member: [recv('aa-1', origin: 'B', seq: 3), normalized('aa-1', origin: 'C', seq: 4)]);
      expect({for (final s in h.steps) if (!s.derived) s.kind: s.nodeId}, {'recibido': 'B', 'normalizado': 'C'});
    });

    test('la auditoría dice quién, cuándo, estado y qué decisión sustituyó; vigente, caduca y sustituida se distinguen', () {
      final first = approval('Ana', seq: 10, ms: 5000);
      final second = approval('Luis', seq: 11, ms: 5100, granted: false, supersedes: [first.id], note: 'Falta confirmar');
      final old = approval('Marta', seq: 12, ms: 4000, rec: 'rec-0');
      final h = build(detailOf(), approvals: [first, second, old]);
      final byWho = {for (final a in h.audit) a.who: a};
      expect(byWho['Ana']!.status, 'sustituida');
      expect(byWho['Luis']!.status, 'vigente');
      expect(byWho['Luis']!.decision, 'denied');
      expect(byWho['Luis']!.supersedes, [first.id]);
      expect(byWho['Luis']!.note, 'Falta confirmar');
      expect(byWho['Marta']!.status, 'caduca');
      expect(byWho['Ana']!.atMs, 5000);
      expect(h.audit.map((a) => a.who), ['Marta', 'Ana', 'Luis'], reason: 'por hora');
    });

    test('las decisiones de otro incidente no entran en la auditoría', () {
      final other = ev('approval.granted', seq: 30, key: 'zz-9', body: {'recommendationId': 'rec-1', 'incidentId': 'zz-9', 'members': ['zz-9'], 'who': 'Otra', 'note': ''});
      final h = build(detailOf(), approvals: [other, approval('Ana')]);
      expect(h.audit.map((a) => a.who), ['Ana']);
    });

    test('una declaración de recurso de una unidad propuesta aparece; la de una unidad que no se propone no', () {
      final h = build(detailOf(resourceIds: ['AMB-01']), units: [unitDeclared('AMB-01', seq: 20), unitDeclared('BOM-09', seq: 21)]);
      final s = h.steps.where((x) => x.kind == 'recurso').toList();
      expect(s, hasLength(1));
      expect(s.single.summary, contains('AMB-01'));
      expect(s.single.summary, contains('no disponible'));
      expect(s.single.summary, contains('Ana'));
    });

    test('un incidente de 500 miembros devuelve a lo sumo 60 pasos y stepsTotal con el total real', () {
      final keys = [for (var i = 0; i < 500; i++) 'm$i-1'];
      final events = <Event>[
        for (var i = 0; i < 500; i++) ...[recv(keys[i], seq: i * 3 + 1, ms: 1000 + i), normalized(keys[i], seq: i * 3 + 2, ms: 1000 + i), triage(keys[i], seq: i * 3 + 3, ms: 1000 + i)],
      ];
      final h = build(detailOf(members: keys, id: keys.first), member: events);
      expect(h.steps.length, lessThanOrEqualTo(60));
      expect(h.stepsTotal, greaterThanOrEqualTo(1500));
      expect(h.steps.where((s) => !s.derived).last.atMs, 1499, reason: 'se conservan los MÁS RECIENTES');
      expect(h.steps.where((s) => s.derived), isNotEmpty, reason: 'los derivados no se pierden por el tope');
    });

    test('la historia no contiene el texto de ningún reporte', () {
      final h = build(detailOf(), member: [recv('aa-1'), normalized('aa-1'), triage('aa-1', mode: 'rules+llm')], approvals: [approval('Ana')]);
      expect(jsonEncode(h.toJson()), isNot(contains('TEXTO-SECRETO')));
    });

    test('los pasos salen ordenados por hora y, a igual hora, por agente; el resultado no depende del orden de entrada', () {
      final events = [triage('aa-1', seq: 3, ms: 1000), recv('aa-1', seq: 1, ms: 1000), normalized('aa-1', seq: 2, ms: 1000), recv('aa-1', seq: 9, ms: 900, rev: 1)];
      final a = jsonEncode(build(detailOf(), member: events).toJson());
      final b = jsonEncode(build(detailOf(), member: events.reversed.toList()).toJson());
      expect(a, b);
      final times = build(detailOf(), member: events).steps.where((s) => !s.derived).map((s) => s.atMs).toList();
      expect(times, [900, 1000, 1000, 1000]);
      final agents = build(detailOf(), member: events).steps.where((s) => s.atMs == 1000).map((s) => s.agent).toList();
      expect(agents, ['1 · Recepción', '1 · Recepción', '2 · Triaje']);
    });

    test('los eventos de un reporte que no es miembro del incidente no entran', () {
      final h = build(detailOf(), member: [recv('aa-1'), recv('zz-9', seq: 5, origin: 'B')]);
      expect([for (final s in h.steps) if (!s.derived) s.eventIds].expand((x) => x), ['A:000001']);
    });

    test('sin eventos ni decisiones sólo quedan los pasos derivados y la auditoría vacía', () {
      final h = build(detailOf());
      expect(h.audit, isEmpty);
      expect(h.steps.every((s) => s.derived), isTrue);
      expect(h.toJson().keys, containsAll(['steps', 'stepsTotal', 'audit', 'auditTotal']));
    });
  });

  group('en el nodo: sólo el DETALLE lleva la historia', () {
    late EventLog log;
    late QueueService queue;
    late Handler h;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      queue = QueueService(log, resources: testResources());
      h = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, queue: queue);
    });
    tearDown(() => log.close());

    Future<Response> get(String path) => Future.sync(() => h(Request('GET', Uri.parse('http://localhost$path'))));
    Future<Map<String, Object?>> json(String path) async => (jsonDecode(await (await get(path)).readAsString()) as Map).cast<String, Object?>();

    test('el detalle trae history; la cola, la lista y el resumen NO (la huella T15 no puede cambiar)', () async {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada');
      log.append('triage.assessed', {'urgency': 'P1', 'mode': 'rules+llm', 'agent_version': 'llm-1'}, reportKey: 'aa-1', rev: 0);
      final queueBefore = (await queue.read()).json;
      final detail = await json('/api/incidents/aa-1');
      expect(detail['history'], isA<Map>());
      final steps = ((detail['history']! as Map)['steps']! as List).cast<Map>();
      expect(steps.any((s) => s['kind'] == 'recibido' && s['nodeId'] == 'A'), isTrue);
      expect(steps.any((s) => (s['summary']! as String).contains('modelo')), isTrue);
      final page = await json('/api/incidents?view=all');
      for (final i in (page['items']! as List).cast<Map>()) {
        expect(i.containsKey('history'), isFalse);
      }
      for (final row in (jsonDecode((await queue.read()).json) as List).cast<Map>()) {
        expect(row.containsKey('history'), isFalse);
      }
      expect((await queue.read()).json, queueBefore, reason: 'pedir el detalle no toca la proyección');
    });

    test('una decisión registrada aparece en la auditoría del detalle, a nombre de quien la tomó', () async {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado, text: 'atrapado');
      final detail0 = await json('/api/incidents/aa-1');
      final rec = (detail0['recommendation']! as Map)['id'];
      final r = await Future.sync(
        () => h(Request('POST', Uri.parse('http://localhost/api/approval'), body: jsonEncode({'recommendationId': rec, 'incidentId': 'aa-1', 'members': ['aa-1'], 'decision': 'granted', 'note': '', 'who': 'Ana Gómez'}), headers: {'content-type': 'application/json'})),
      );
      expect(r.statusCode, 200);
      final detail = await json('/api/incidents/aa-1');
      final audit = ((detail['history']! as Map)['audit']! as List).cast<Map>();
      expect((audit.single['who'], audit.single['status'], audit.single['decision']), ('Ana Gómez', 'vigente', 'granted'));
    });

    test('un detalle nuevo no se sirve con la etiqueta vieja: llegar un evento del incidente cambia el ETag', () async {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado, text: 'atrapado');
      final first = await get('/api/incidents/aa-1');
      final etag = first.headers['etag']!;
      log.append('incident.linked', {'links': <Object>[]}, reportKey: 'aa-1', rev: 0);
      final second = await get('/api/incidents/aa-1');
      expect(second.headers['etag'], isNot(etag));
      final again = await Future.sync(() => h(Request('GET', Uri.parse('http://localhost/api/incidents/aa-1'), headers: {'if-none-match': second.headers['etag']!})));
      expect(again.statusCode, 304);
    });
  });
}
