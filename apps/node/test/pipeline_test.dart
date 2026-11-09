import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  Event received({int flags = SituationFlags.atrapado | SituationFlags.herido, double? lat = 5.07, String? text}) => log.append(
        'report.received',
        {'flags': flags, 'lat': lat, 'lon': lat == null ? null : -75.5, 'text': text, 'loc_quality': lat == null ? 0 : 2},
        reportKey: 'aa-1',
        rev: 0,
      );

  test('run añade report.normalized y luego triage.assessed, encadenados por inputs', () {
    final r = received();
    final out = PipelineRunner(log).run(r);
    expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed']);
    expect(log.all().map((e) => e.type), ['report.received', 'report.normalized', 'triage.assessed']);
    expect(out[0].inputs, [r.id]);
    expect(out[1].inputs, [out[0].id]);
    expect(out.every((e) => e.reportKey == 'aa-1' && e.rev == 0), isTrue);
  });

  test('el triaje deja urgencia, señales y modo «rules»', () {
    final out = PipelineRunner(log).run(received());
    expect(out[1].body['urgency'], 'P1');
    expect(out[1].body['signals'], ['atrapado', 'herido']);
    expect(out[1].body['mode'], 'rules');
  });

  test('la normalización marca lo que falta y no inventa nada', () {
    final out = PipelineRunner(log).run(received(lat: null));
    expect(out[0].body['missing'], ['ubicacion', 'texto']);
    expect(out[0].body['lat'], isNull);
  });

  Event rec2(String key, {String? device, int flags = 0, double? lat = 5.07, String? text}) => log.append(
    'report.received',
    {
      'device_id': device ?? key.split('-').first,
      'frame_seq': 1,
      'flags': flags,
      'incident_type': 1,
      'loc_quality': lat == null ? 0 : 2,
      'lat': lat,
      'lon': lat == null ? null : -75.51,
      'text': text,
      'captured_at': 1786370851,
      'received_at': 5000,
    },
    reportKey: key,
    rev: 0,
  );

  group('agente 2 v2: el evento de triaje lleva evidencia', () {
    test('trae evidencia, confianza, incertidumbre y si pide revisión humana', () {
      final out = PipelineRunner(log).run(rec2('aa-1', flags: SituationFlags.atrapado, text: 'estoy atrapado bajo la losa'));
      final b = out[1].body;
      expect(b['urgency'], 'P2');
      expect(b['escalate_to_human'], isFalse);
      expect(b['confidence'], isA<num>());
      expect(b['uncertainty'], isA<List<Object?>>());
      final ev = (b['evidence']! as List).cast<Map<String, Object?>>();
      expect(ev.any((e) => e['field'] == 'flags.atrapado'), isTrue);
      expect(ev.any((e) => e['quote'] == 'atrapado'), isTrue);
    });

    test('un SOS sin banderas ni texto: P3, sin_detalle y revisión humana (sin datos nunca baja la urgencia)', () {
      final out = PipelineRunner(log).run(rec2('aa-1', lat: null));
      expect(out[1].body['urgency'], 'P3');
      expect(out[1].body['escalate_to_human'], isTrue);
      expect(out[1].body['uncertainty'], containsAll(['sin_detalle', 'ubicacion_ausente']));
    });
  });

  group('agente 3: rastro de auditoría `incident.linked`', () {
    const t = 'puente colapsado calle veinte carros abajo';

    test('un reporte solo no deja ningún incident.linked', () {
      final out = PipelineRunner(log).run(rec2('aa-1', text: t));
      expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed']);
    });

    test('un segundo reporte casi idéntico de otro dispositivo deja UN incident.linked con el primero', () {
      PipelineRunner(log).run(rec2('aa-1', text: t));
      final out = PipelineRunner(log).run(rec2('bb-1', lat: 5.0701, text: t));
      expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed', 'incident.linked']);
      final linked = out.last;
      final links = (linked.body['links']! as List).cast<Map<String, Object?>>();
      expect(links.single['other'], 'aa-1');
      expect(links.single['state'], 'same');
      expect(linked.reportKey, 'bb-1');
      expect(linked.inputs, [out[1].id]);
    });

    test('uno lejano o con otro texto no deja vínculo', () {
      PipelineRunner(log).run(rec2('aa-1', text: t));
      final out = PipelineRunner(log).run(rec2('bb-1', lat: 5.5, text: t));
      expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed']);
    });

    test('la pareja `possible` también deja rastro, marcada como tal', () {
      PipelineRunner(log).run(rec2('aa-1'));
      final out = PipelineRunner(log).run(rec2('bb-1', lat: 5.0701));
      final links = (out.last.body['links']! as List).cast<Map<String, Object?>>();
      expect(links.single['state'], 'possible');
    });
  });

  group('integrado en la API', () {
    late Handler handler;
    setUp(() => handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, pipeline: PipelineRunner(log)));
    Future<Response> post(List<int> body) => Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: body)));

    test('un reporte nuevo deja 3 eventos; un duplicado o basura, ninguno más', () async {
      await post(vectorBytes('sos_min'));
      expect(log.all().map((e) => e.type), ['report.received', 'report.normalized', 'triage.assessed']);
      await post(vectorBytes('sos_min'));
      await post([1, 2, 3]);
      expect(log.all().length, 3);
    });
  });
}
