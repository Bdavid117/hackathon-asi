import 'dart:async';
import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

const String paraphrase = 'quedamos encerrados y se prendió todo';

class FakePort implements LlmPort {
  FakePort(this.respond);
  final Future<LlmResult> Function(LlmRequest) respond;
  int calls = 0;

  @override
  Future<LlmResult> completeJson(LlmRequest request) {
    calls++;
    return respond(request);
  }
}

LlmResult verdict(String urgency, {List<Map<String, String>> signals = const [], bool escalate = false}) => LlmResult(
  text: jsonEncode({'urgency': urgency, 'signals': signals, 'confidence': 0.8, 'escalate_to_human': escalate}),
  stopReason: 'end_turn',
);

final LlmResult p1Atrapado = verdict('P1', signals: [{'code': 'atrapado', 'quote': 'quedamos encerrados'}]);

Event rec(EventLog log, String key, int rev, {int flags = 0, String? text = paraphrase, double? lat = 5.07}) => log.append(
  'report.received',
  {
    'device_id': key.split('-').first,
    'frame_seq': rev + 1,
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
  rev: rev,
);

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('enrich: el modelo se consulta DESPUÉS y deja su propio evento', () {
    test('un juicio válido escribe un triage.assessed con mode «rules+llm», evidencia citada y su entrada', () async {
      final r = rec(log, 'aa-1', 0);
      final runner = PipelineRunner(log, llm: FakePort((_) async => p1Atrapado));
      final ev = await runner.enrich(r);
      expect(ev, isNotNull);
      expect(ev!.type, 'triage.assessed');
      expect(ev.body['mode'], 'rules+llm');
      expect(ev.body['urgency'], 'P1');
      expect((ev.body['evidence']! as List).cast<Map<String, Object?>>().any((e) => e['quote'] == 'quedamos encerrados'), isTrue);
      expect(ev.body['analyzed_text'], paraphrase);
      expect(ev.inputs, [r.id]);
      expect(ev.reportKey, 'aa-1');
    });

    test('es idempotente: la misma consulta no se repite ni duplica el evento', () async {
      final port = FakePort((_) async => p1Atrapado);
      final runner = PipelineRunner(log, llm: port);
      final r = rec(log, 'aa-1', 0);
      await runner.enrich(r);
      expect(await runner.enrich(r), isNull);
      expect(port.calls, 1);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('una revisión que sólo trae la ubicación (mismo texto) NO vuelve a consultar al modelo', () async {
      final port = FakePort((_) async => p1Atrapado);
      final runner = PipelineRunner(log, llm: port);
      await runner.enrich(rec(log, 'aa-1', 0, lat: null));
      await runner.enrich(rec(log, 'aa-1', 1, text: null)); // la revisión con GPS no lleva texto propio
      expect(port.calls, 1);
    });

    test('si el texto cambia en una revisión, se consulta de nuevo', () async {
      final port = FakePort((_) async => p1Atrapado);
      final runner = PipelineRunner(log, llm: port);
      await runner.enrich(rec(log, 'aa-1', 0));
      await runner.enrich(rec(log, 'aa-1', 1, text: 'quedamos encerrados, otra vez'));
      expect(port.calls, 2);
    });

    test('sin texto no hay consulta; sin puerto no hay modelo', () async {
      final port = FakePort((_) async => p1Atrapado);
      expect(await PipelineRunner(log, llm: port).enrich(rec(log, 'aa-1', 0, text: null)), isNull);
      expect(port.calls, 0);
      expect(await PipelineRunner(log).enrich(rec(log, 'bb-1', 0)), isNull);
    });

    test('cualquier fallo del modelo no escribe nada y no lanza (las reglas siguen mandando)', () async {
      for (final res in [
        const LlmResult(timedOut: true),
        const LlmResult(text: null, stopReason: 'refusal'),
        const LlmResult(error: 'HTTP 500'),
        const LlmResult(text: '{no json', stopReason: 'end_turn'),
      ]) {
        final l = EventLog.open(':memory:', nodeId: 'Z');
        addTearDown(l.close);
        final runner = PipelineRunner(l, llm: FakePort((_) async => res));
        expect(await runner.enrich(rec(l, 'aa-1', 0)), isNull);
        expect(l.allOfType('triage.assessed'), isEmpty);
      }
      final l2 = EventLog.open(':memory:', nodeId: 'Y');
      addTearDown(l2.close);
      expect(await PipelineRunner(l2, llm: FakePort((_) async => throw StateError('boom'))).enrich(rec(l2, 'aa-1', 0)), isNull);
    });

    test('dos consultas SIMULTÁNEAS por el mismo texto escriben UN solo evento (el SOS y su revisión llegan casi juntos)', () async {
      final gate = Completer<LlmResult>();
      final runner = PipelineRunner(log, llm: FakePort((_) => gate.future));
      final r = rec(log, 'aa-1', 0);
      final f1 = runner.enrich(r);
      final f2 = runner.enrich(r);
      gate.complete(p1Atrapado);
      await Future.wait([f1, f2]);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('idle espera de verdad a un modelo lento (50 ms)', () async {
      final runner = PipelineRunner(log, llm: FakePort((_) => Future.delayed(const Duration(milliseconds: 50), () => p1Atrapado)));
      runner.run(rec(log, 'aa-1', 0));
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), isEmpty);
      await runner.idle;
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('run() no espera al modelo: devuelve sus eventos ya y el del modelo llega después', () async {
      final gate = Completer<LlmResult>();
      final runner = PipelineRunner(log, llm: FakePort((_) => gate.future));
      final out = runner.run(rec(log, 'aa-1', 0));
      expect(out.map((e) => e.type), ['report.normalized', 'triage.assessed']);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), isEmpty, reason: 'el modelo aún no respondió');
      gate.complete(p1Atrapado);
      await runner.idle;
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });
  });

  group('la cola toma lo más grave entre las reglas y el modelo', () {
    test('una paráfrasis que las reglas no entienden (P3) sube a P1 con el juicio del modelo', () async {
      rec(log, 'aa-1', 0);
      expect(buildQueue(log).single.urgency, Urgency.p3);
      await PipelineRunner(log, llm: FakePort((_) async => p1Atrapado)).enrich(log.all().first);
      final it = buildQueue(log).single;
      expect(it.urgency, Urgency.p1);
      expect(it.signals, contains('atrapado'));
      expect(it.escalate, isFalse, reason: 'el modelo interpretó el texto');
      expect(it.uncertainty, contains('juicios_discrepantes'));
    });

    test('un juicio del modelo más bajo que las reglas no baja nada', () async {
      final r = rec(log, 'aa-1', 0, flags: 0x80, text: 'estoy atrapado'); // atrapado ⇒ P2 por reglas
      await PipelineRunner(log, llm: FakePort((_) async => verdict('P4'))).enrich(r);
      expect(buildQueue(log).single.urgency, Urgency.p2);
    });

    test('un juicio sobre un texto que ya no es el vigente no se aplica', () async {
      final r0 = rec(log, 'aa-1', 0);
      await PipelineRunner(log, llm: FakePort((_) async => p1Atrapado)).enrich(r0);
      expect(buildQueue(log).single.urgency, Urgency.p1);
      rec(log, 'aa-1', 1, text: 'ya estamos a salvo, gracias'); // el texto vigente cambió
      expect(buildQueue(log).single.urgency, isNot(Urgency.p1), reason: 'el juicio era sobre el texto anterior');
    });

    test('dos nodos con juicios distintos: manda el más alto y se marca la discrepancia', () async {
      final a = EventLog.open(':memory:', nodeId: 'A');
      final b = EventLog.open(':memory:', nodeId: 'B');
      addTearDown(() {
        a.close();
        b.close();
      });
      final ra = rec(a, 'aa-1', 0);
      for (final e in a.all()) {
        b.appendReplicated(e);
      }
      await PipelineRunner(a, llm: FakePort((_) async => p1Atrapado)).enrich(ra);
      await PipelineRunner(b, llm: FakePort((_) async => verdict('P2', signals: [{'code': 'incendio', 'quote': 'se prendió todo'}]))).enrich(b.all().first);
      for (final e in a.all()) {
        b.appendReplicated(e);
      }
      for (final e in b.all()) {
        a.appendReplicated(e);
      }
      for (final l in [a, b]) {
        final it = buildQueue(l).single;
        expect(it.urgency, Urgency.p1);
        expect(it.signals, containsAll(['atrapado', 'incendio']));
        expect(it.uncertainty, contains('juicios_discrepantes'));
      }
      expect(buildQueue(a).single.toJson(), buildQueue(b).single.toJson(), reason: 'los dos nodos convergen');
    });

    test('sin ningún evento del modelo, la cola es la de siempre (el modelo no es requisito)', () {
      rec(log, 'aa-1', 0);
      final it = buildQueue(log).single;
      expect(it.urgency, Urgency.p3);
      expect(it.escalate, isTrue);
    });
  });
}
