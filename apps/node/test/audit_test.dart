import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

const String t = 'puente colapsado calle veinte carros abajo';

Event rec(EventLog log, String key, int rev, {double? lat = 5.07, String? text = t}) => log.append(
  'report.received',
  {
    'device_id': key.split('-').first,
    'frame_seq': rev + 1,
    'flags': 0,
    'incident_type': 1,
    'loc_quality': lat == null ? 0 : 2,
    'lat': lat,
    'lon': lat == null ? null : -75.51,
    'text': text,
    'captured_at': 1786370851,
    'received_at': 5000,
  },
  reportKey: key,
  rev: rev,
);

List<Event> linked(EventLog log) => log.allOfType('incident.linked');

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('la auditoría de vínculos va por LOTES, fuera de la ruta del ACK', () {
    test('un reporte solo no deja ningún incident.linked', () async {
      rec(log, 'aa-1', 0);
      expect(await AuditLinker(log).runOnce(), 0);
      expect(linked(log), isEmpty);
    });

    test('un segundo reporte casi idéntico de otro dispositivo deja UN incident.linked con el primero', () async {
      rec(log, 'aa-1', 0);
      final r = rec(log, 'bb-1', 0, lat: 5.0701);
      await AuditLinker(log).runOnce();
      final e = linked(log).single;
      final links = (e.body['links']! as List).cast<Map<String, Object?>>();
      expect(e.reportKey, anyOf('aa-1', 'bb-1'));
      expect(links.single['state'], 'same');
      expect({e.reportKey, links.single['other']}, {'aa-1', 'bb-1'});
      expect(e.inputs, hasLength(1));
      expect(r.id, isNotEmpty);
    });

    test('uno lejano o con otro texto no deja vínculo; uno parecido sin texto deja uno `possible`', () async {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.5);
      await AuditLinker(log).runOnce();
      expect(linked(log), isEmpty);
      final l2 = EventLog.open(':memory:', nodeId: 'B');
      addTearDown(l2.close);
      rec(l2, 'aa-1', 0, text: null);
      rec(l2, 'bb-1', 0, lat: 5.0701, text: null);
      await AuditLinker(l2).runOnce();
      final links = (linked(l2).single.body['links']! as List).cast<Map<String, Object?>>();
      expect(links.single['state'], 'possible');
    });

    test('es idempotente: volver a correr no escribe nada nuevo', () async {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      final a = AuditLinker(log);
      expect(await a.runOnce(), greaterThan(0));
      final n = log.count();
      expect(await a.runOnce(), 0);
      expect(log.count(), n);
    });

    test('es idempotente ENTRE REINICIOS: un linker nuevo sobre el mismo log no repite lo ya escrito', () async {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      await AuditLinker(log).runOnce();
      final n = log.count();
      expect(await AuditLinker(log).runOnce(), 0);
      expect(log.count(), n);
    });

    test('sólo examina lo nuevo: un tercer reporte añade su vínculo y no repite los anteriores', () async {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      final a = AuditLinker(log);
      await a.runOnce();
      final before = linked(log).length;
      rec(log, 'cc-1', 0, lat: 5.0702);
      await a.runOnce();
      expect(linked(log).length, before + 1);
      expect(linked(log).last.reportKey, 'cc-1');
    });

    test('una revisión nueva de un reporte ya auditado se vuelve a examinar (ahora trae ubicación y texto)', () async {
      rec(log, 'aa-1', 0, lat: 5.0701);
      rec(log, 'bb-1', 0, lat: null, text: null);
      final a = AuditLinker(log);
      await a.runOnce();
      expect(linked(log).where((e) => e.reportKey == 'bb-1'), isEmpty);
      rec(log, 'bb-1', 1, lat: 5.0702); // llega la revisión con ubicación y texto
      await a.runOnce();
      expect(linked(log).where((e) => e.reportKey == 'bb-1' && e.rev == 1), hasLength(1));
    });

    test('sólo se examina lo nuevo: el cálculo recibe como objetivos únicamente los reportes aún no auditados', () async {
      final seen = <Set<String>>[];
      final a = AuditLinker(log, compute: (received, targets) {
        seen.add({...targets});
        return computeAuditLinks(received, targets);
      });
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      await a.runOnce();
      await a.runOnce(); // nada nuevo: ni siquiera se calcula
      rec(log, 'cc-1', 0, lat: 5.0702);
      await a.runOnce();
      expect(seen, [
        {'aa-1', 'bb-1'},
        {'cc-1'},
      ]);
    });

    test('con muchos reportes el cálculo corre en otro isolate y da lo mismo', () async {
      for (var i = 0; i < 400; i++) {
        rec(log, 'd$i-1', 0, lat: 5.07 + (i % 40) * 0.0001, text: i.isEven ? t : null);
      }
      final inline = EventLog.open(':memory:', nodeId: 'I');
      addTearDown(inline.close);
      for (final e in log.allOfType('report.received')) {
        inline.append('report.received', e.body, reportKey: e.reportKey, rev: e.rev);
      }
      await AuditLinker(log, isolateAbove: 100).runOnce();
      await AuditLinker(inline, isolateAbove: 100000).runOnce();
      String sig(EventLog l) => (l.allOfType('incident.linked').map((e) => '${e.reportKey}/${e.rev}:${(e.body['links'] as List).length}').toList()..sort()).join('|');
      expect(sig(log), sig(inline));
      expect(linked(log), isNotEmpty);
    });
  });

  group('tick: a lo sumo cada cierto tiempo y sin solaparse', () {
    test('no corre si no hay reportes nuevos; corre si los hay; respeta el intervalo mínimo', () async {
      var now = DateTime.utc(2026, 1, 1);
      final a = AuditLinker(log, clock: () => now, minInterval: const Duration(seconds: 5));
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      expect(await a.tick(), isTrue);
      expect(linked(log), hasLength(1));
      rec(log, 'cc-1', 0, lat: 5.0702);
      expect(await a.tick(), isFalse, reason: 'aún no pasaron 5 s');
      now = now.add(const Duration(seconds: 6));
      expect(await a.tick(), isTrue);
      expect(await a.tick(), isFalse, reason: 'sin reportes nuevos no hay nada que hacer');
    });
  });
}
