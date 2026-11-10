import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'log_support.dart';
import 'support.dart';

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  Map<String, IncidentData> byId() => {for (final i in buildIncidents(buildQueue(log), approvals: const [], resources: testResources())) i.id: i};
  List<String> pending(IncidentData i) => ((i.summary['recommendation']! as Map)['pending']! as List).cast<String>();

  // El incidente grave: gente atrapada en (5.0703, -75.5138). La ambulancia AMB-01 está a ≈ 80 m.
  void trapped() => received(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada en el edificio');

  group('«confirmar ruta»: una vía bloqueada reportada por OTRO incidente, cerca', () {
    test('sin ninguna vía bloqueada, no se pide', () {
      trapped();
      expect(pending(byId()['aa-1']!), isNot(contains('confirmar_ruta')));
    });

    test('con un reporte de vía bloqueada a ≈ 300 m, la propuesta del grave pide confirmar la ruta', () {
      trapped();
      received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada, text: 'derrumbe tapa el camino', lat: 5.0730, lon: -75.5138, locQuality: 1);
      final all = byId();
      expect(all.keys.toSet(), {'aa-1', 'bb-1'}, reason: 'el montaje: son dos incidentes distintos');
      expect(pending(all['aa-1']!), contains('confirmar_ruta'));
    });

    test('la propia vía bloqueada no se pide a sí misma', () {
      trapped();
      received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada, text: 'derrumbe tapa el camino', lat: 5.0730, lon: -75.5138, locQuality: 1);
      expect(pending(byId()['bb-1']!), isNot(contains('confirmar_ruta')));
    });

    test('una vía bloqueada lejos (≈ 5 km) no cuenta', () {
      trapped();
      received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada, text: 'derrumbe tapa el camino', lat: 5.115, lon: -75.5138, locQuality: 1);
      expect(pending(byId()['aa-1']!), isNot(contains('confirmar_ruta')));
    });

    test('sólo cuentan los reportes que dicen «vía bloqueada» (otro incidente cercano cualquiera no)', () {
      trapped();
      received(log, 'bb-1', 0, flags: SituationFlags.incendio, text: 'humo en la esquina', lat: 5.0730, lon: -75.5138, locQuality: 1);
      expect(pending(byId()['aa-1']!), isNot(contains('confirmar_ruta')));
    });

    test('un reporte de vía bloqueada SIN ubicación no se puede situar: no cuenta (ni rompe)', () {
      trapped();
      received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada, text: 'derrumbe tapa el camino', lat: null, lon: null, locQuality: 0);
      expect(pending(byId()['aa-1']!), isNot(contains('confirmar_ruta')));
    });

    test('NO cambia la urgencia ni la identidad de la recomendación: una aprobación vigente NO caduca porque aparezca un bloqueo', () async {
      trapped();
      final queue = QueueService(log, resources: testResources());
      final handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, queue: queue);
      Future<Response> post(Object body) => Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/api/approval'), body: jsonEncode(body), headers: {'content-type': 'application/json'})));
      Future<Map<String, Object?>> grave() async => (jsonDecode((await queue.read()).incidentsPage(view: 'all'))['items']! as List).cast<Map>().firstWhere((i) => i['id'] == 'aa-1').cast<String, Object?>();

      final before = await grave();
      final rec = (before['recommendation']! as Map).cast<String, Object?>();
      final ok = await post({'recommendationId': rec['id'], 'incidentId': 'aa-1', 'members': before['members'], 'decision': 'granted', 'note': '', 'who': 'Ana Gómez'});
      expect(ok.statusCode, 200);
      expect((await grave())['approval'], containsPair('status', 'aprobada'));

      received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada, text: 'derrumbe tapa el camino', lat: 5.0730, lon: -75.5138, locQuality: 1);
      final after = await grave();
      expect(((after['recommendation']! as Map)['pending']! as List), contains('confirmar_ruta'), reason: 'ahora sí avisa');
      expect((after['recommendation']! as Map)['id'], rec['id'], reason: 'pero es la MISMA recomendación');
      expect(after['urgency'], before['urgency']);
      expect((after['approval']! as Map)['status'], 'aprobada', reason: 'y la aprobación sigue vigente');
    });
  });
}
