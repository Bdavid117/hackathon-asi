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
