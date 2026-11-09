import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'support.dart';
import 'package:shelf/shelf.dart';

class CountingPort implements LlmPort {
  int calls = 0;
  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    calls++;
    return const LlmResult(error: 'no usado');
  }
}

Event rec(EventLog log, String device, int i, {String? text = 'estamos atrapados bajo la losa del edificio'}) => log.append(
  'report.received',
  {
    'device_id': device,
    'frame_seq': i,
    'flags': 0,
    'incident_type': 1,
    'loc_quality': 2,
    'lat': 5.07,
    'lon': -75.51,
    'text': text,
    'captured_at': 1786370851,
    'received_at': 5000,
  },
  reportKey: '$device-$i',
  rev: 0,
);

void main() {
  group('DeviceBudget: cubeta de fichas por dispositivo', () {
    test('un dispositivo normal (incluso con atraso: 160 tramas por minuto) nunca se pasa', () {
      var now = DateTime.utc(2026, 1, 1);
      final b = DeviceBudget(clock: () => now);
      // un teléfono con atraso envía 8 tramas cada 3 s = 160 por minuto, durante 10 minutos
      for (var t = 0; t < 200; t++) {
        for (var k = 0; k < 8; k++) {
          expect(b.take('d1'), isTrue, reason: 't=$t k=$k');
        }
        now = now.add(const Duration(seconds: 3));
      }
    });

    test('una ráfaga muy por encima de lo humano se pasa del presupuesto, y se recupera al esperar', () {
      var now = DateTime.utc(2026, 1, 1);
      final b = DeviceBudget(clock: () => now);
      var ok = 0;
      for (var i = 0; i < 1000; i++) {
        if (b.take('d1')) ok++;
      }
      expect(ok, 300, reason: 'la capacidad de la cubeta');
      expect(b.take('d1'), isFalse);
      now = now.add(const Duration(seconds: 10)); // 5 fichas por segundo
      expect(b.take('d1'), isTrue);
    });

    test('cada dispositivo tiene su cubeta: el abuso de uno no gasta las fichas de otro', () {
      final b = DeviceBudget();
      for (var i = 0; i < 1000; i++) {
        b.take('abusivo');
      }
      expect(b.take('abusivo'), isFalse);
      expect(b.take('legitimo'), isTrue);
    });

    test('un reloj que retrocede no regala ni quita fichas', () {
      var now = DateTime.utc(2026, 1, 1);
      final b = DeviceBudget(clock: () => now);
      for (var i = 0; i < 300; i++) {
        b.take('d1');
      }
      now = now.subtract(const Duration(hours: 1));
      expect(b.take('d1'), isFalse);
    });

    test('lleva la cuenta de lo degradado', () {
      final b = DeviceBudget();
      for (var i = 0; i < 305; i++) {
        b.take('d1');
      }
      expect(b.degraded, 5);
      expect(b.devicesOverBudget, 1);
    });
  });

  group('degradar, no rechazar: el presupuesto sólo quita lo caro (el modelo)', () {
    late EventLog log;
    setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
    tearDown(() => log.close());

    test('pasado el presupuesto la trama SE GUARDA y se procesa por reglas, pero no se consulta al modelo', () async {
      final port = CountingPort();
      final runner = PipelineRunner(log, llm: port, budget: DeviceBudget(capacity: 3, refillPerSecond: 0));
      for (var i = 1; i <= 6; i++) {
        final out = runner.run(rec(log, 'dev', i));
        expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed'], reason: 'las reglas corren siempre');
      }
      await runner.idle;
      expect(port.calls, 3, reason: 'sólo las 3 primeras llegaron al modelo');
      expect(runner.budget.degraded, 3);
      expect(log.allOfType('report.received'), hasLength(6), reason: 'nada se descarta');
    });

    test('un dispositivo abusivo no le quita el modelo a otro dispositivo', () async {
      final port = CountingPort();
      final runner = PipelineRunner(log, llm: port, budget: DeviceBudget(capacity: 2, refillPerSecond: 0));
      for (var i = 1; i <= 10; i++) {
        runner.run(rec(log, 'abusivo', i, text: 'texto distinto numero $i del abusivo con varias palabras'));
      }
      runner.run(rec(log, 'victima', 1));
      await runner.idle;
      expect(port.calls, 3, reason: '2 del abusivo + 1 de la víctima');
    });

    test('el rev 0 de un dispositivo pasado de presupuesto se guarda y se acusa igual', () async {
      final log2 = EventLog.open(':memory:', nodeId: 'B');
      addTearDown(log2.close);
      final handler = buildHandler(
        ingest: Ingest(log: log2, key: testKey),
        log: log2,
        pipeline: PipelineRunner(log2, budget: DeviceBudget(capacity: 0, refillPerSecond: 0)),
      );
      final r = await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: sosFrame(1))));
      expect(r.statusCode, 200);
      expect(log2.allOfType('report.received'), hasLength(1));
      expect(log2.allOfType('triage.assessed'), hasLength(1));
    });

    test('los reintentos de lo ya guardado NO gastan fichas (sólo cuentan las tramas nuevas)', () async {
      final log2 = EventLog.open(':memory:', nodeId: 'C');
      addTearDown(log2.close);
      final budget = DeviceBudget();
      final handler = buildHandler(
        ingest: Ingest(log: log2, key: testKey),
        log: log2,
        pipeline: PipelineRunner(log2, budget: budget),
      );
      for (var i = 0; i < 50; i++) {
        await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: sosFrame(1))));
      }
      expect(budget.takenTotal, 1, reason: 'una sola trama nueva; 49 reintentos');
    });

    test('/api/health informa del presupuesto', () async {
      final log2 = EventLog.open(':memory:', nodeId: 'D');
      addTearDown(log2.close);
      final handler = buildHandler(
        ingest: Ingest(log: log2, key: testKey),
        log: log2,
        pipeline: PipelineRunner(log2, budget: DeviceBudget(capacity: 1, refillPerSecond: 0)),
      );
      await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: sosFrame(1))));
      await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: sosFrame(2))));
      final r = await Future.sync(() => handler(Request('GET', Uri.parse('http://localhost/api/health'))));
      expect(await r.readAsString(), contains('"budget":{"degraded":1,"devicesOverBudget":1}'));
    });
  });
}
