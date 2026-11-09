// Tope de consultas simultáneas al modelo. Sin tope, un modelo colgado hace que cada trama con texto
// mantenga un socket abierto hasta su plazo (8 s): a ≈ 1 000 tramas/s son miles de sockets, y con el
// límite típico de 1 024 descriptores el nodo muere («Too many open files»). Medido: 2 726 de 5 000
// tramas rechazadas y el proceso muerto.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'log_support.dart';

/// Un modelo que sólo contesta cuando se le suelta: cuenta las consultas en vuelo y el máximo simultáneo.
class GatedPort implements LlmPort {
  final Queue<Completer<LlmResult>> held = Queue();
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<LlmResult> completeJson(LlmRequest request) {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final c = Completer<LlmResult>();
    held.add(c);
    return c.future.whenComplete(() => inFlight--);
  }

  void releaseAll() {
    while (held.isNotEmpty) {
      held.removeFirst().complete(_verdict);
    }
  }

  static final LlmResult _verdict = LlmResult(
    text: jsonEncode({'urgency': 'P3', 'signals': <Object?>[], 'confidence': 0.7, 'escalate_to_human': false}),
    stopReason: 'end_turn',
  );
}

/// Un modelo que contesta tras una pequeña espera.
class SlowPort implements LlmPort {
  int inFlight = 0;
  int maxInFlight = 0;
  int calls = 0;

  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    inFlight--;
    return GatedPort._verdict;
  }
}

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  Event report(int i) => received(log, 'dev$i-1', 0, text: 'necesitamos ayuda en la casa número $i por favor', device: 'dev$i');

  group('PipelineRunner: tope de consultas al modelo', () {
    test('por omisión hay un tope razonable (16 en vuelo, 1 000 en espera)', () {
      final r = PipelineRunner(log, llm: GatedPort());
      expect(r.maxModelInFlight, 16);
      expect(r.maxModelQueued, 1000);
    });

    test('con un modelo que NUNCA contesta, jamás hay más consultas en vuelo que el tope, y el resto queda en reglas y se cuenta', () async {
      final port = GatedPort();
      final r = PipelineRunner(log, llm: port, maxModelInFlight: 4, maxModelQueued: 50, budget: DeviceBudget(capacity: 100000));
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        final events = r.run(report(i));
        expect(events.map((e) => e.type), ['report.normalized', 'triage.assessed'], reason: 'las reglas y el ACK no esperan');
      }
      expect(sw.elapsedMilliseconds, lessThan(3000));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(port.calls, 4, reason: 'sólo 4 conexiones abiertas al modelo, no 200');
      expect(port.maxInFlight, 4);
      expect(r.llmStats!.omitidas, 200 - 4 - 50, reason: 'lo que no cabe en la espera se omite (queda con reglas) y se cuenta');
      expect((r.llmStats!.toJson())['omitidas'], 146);
    });

    test('al soltarse el modelo, la espera se procesa: 4 + 50 consultas en total, nunca más de 4 a la vez', () async {
      final port = GatedPort();
      final r = PipelineRunner(log, llm: port, maxModelInFlight: 4, maxModelQueued: 50, budget: DeviceBudget(capacity: 100000));
      for (var i = 0; i < 200; i++) {
        r.run(report(i));
      }
      // soltar de a poco: cada respuesta libera un hueco para la siguiente de la espera
      for (var round = 0; round < 80 && (port.held.isNotEmpty || port.calls < 54); round++) {
        port.releaseAll();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await r.idle;
      expect(port.calls, 54);
      expect(port.maxInFlight, lessThanOrEqualTo(4));
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(54));
    });

    test('con un modelo que sí contesta (despacio) y espera suficiente, TODOS reciben su juicio y nunca se pasa del tope', () async {
      final port = SlowPort();
      final r = PipelineRunner(log, llm: port, maxModelInFlight: 5, maxModelQueued: 1000, budget: DeviceBudget(capacity: 100000));
      for (var i = 0; i < 100; i++) {
        r.run(report(i));
      }
      await r.idle;
      expect(port.calls, 100);
      expect(port.maxInFlight, lessThanOrEqualTo(5));
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(100));
      expect(r.llmStats!.omitidas, 0);
    });

    test('lo que llega por REPLICACIÓN obedece el mismo tope (un nodo que se pone al día no abre 500 conexiones)', () async {
      final port = GatedPort();
      final r = PipelineRunner(log, llm: port, maxModelInFlight: 3, maxModelQueued: 10, budget: DeviceBudget(capacity: 100000));
      for (var i = 0; i < 500; i++) {
        r.onReplicated(report(i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(port.calls, 3);
      expect(port.maxInFlight, 3);
      expect(r.llmStats!.omitidas, 500 - 3 - 10);
    });

    test('un reporte omitido por el tope puede reintentarse después (no queda vetado)', () async {
      final port = GatedPort();
      final r = PipelineRunner(log, llm: port, maxModelInFlight: 1, maxModelQueued: 0, budget: DeviceBudget(capacity: 100000));
      final first = report(1);
      final second = report(2);
      r.run(first);
      r.run(second); // no cabe: se omite
      expect(r.llmStats!.omitidas, 1);
      port.releaseAll();
      await r.idle;
      r.onReplicated(second); // ahora hay hueco: se reintenta
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(port.calls, 2);
      port.releaseAll();
      await r.idle;
    });

    test('«omitidas» sale en las estadísticas del modelo (que sirve /api/health)', () {
      final r = PipelineRunner(log, llm: GatedPort());
      expect(r.llmStats!.toJson().containsKey('omitidas'), isTrue);
    });

    test('con el reparto por rendezvous, lo que espera su turno de relevo no ocupa un hueco del tope', () async {
      final port = GatedPort();
      final r = PipelineRunner(
        log,
        llm: port,
        maxModelInFlight: 2,
        maxModelQueued: 0,
        budget: DeviceBudget(capacity: 100000),
        ownership: OwnershipPolicy(selfId: 'A', liveNodes: () => {'A', 'B'}, takeoverAfter: const Duration(seconds: 30)),
      );
      for (var i = 0; i < 40; i++) {
        r.run(report(i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // sólo consultan ya los que este nodo posee (≈ la mitad), de los cuales caben 2; los demás esperan su relevo, sin hueco
      expect(port.calls, lessThanOrEqualTo(2));
      expect(r.llmStats!.omitidas, lessThan(40), reason: 'los que esperan relevo no se contaron como omitidos todavía');
    });
  });

  group('AuditLinker.tick no derriba al nodo', () {
    test('si el cálculo falla (p. ej. «Too many open files»), tick NO lanza: lo avisa y reintenta más tarde', () async {
      final log = EventLog.open(':memory:', nodeId: 'A');
      addTearDown(log.close);
      received(log, 'aa-1', 0);
      var calls = 0;
      final errors = <Object>[];
      var now = DateTime.utc(2026, 11, 9, 12);
      final a = AuditLinker(
        log,
        clock: () => now,
        minInterval: Duration.zero,
        onError: (e, st) => errors.add(e),
        compute: (r, t) {
          calls++;
          if (calls == 1) throw const FormatException('Too many open files');
          return computeAuditLinks(r, t);
        },
      );
      expect(await a.tick(), isFalse);
      expect(errors, hasLength(1));
      expect(log.allOfType('audit.batch'), isEmpty, reason: 'un lote que falló no se da por examinado');
      now = now.add(const Duration(seconds: 1));
      expect(await a.tick(), isTrue, reason: 'se reintenta aunque no haya reportes nuevos');
      expect(log.allOfType('audit.batch'), hasLength(1));
      expect((log.allOfType('audit.batch').single.body['examined'] as List), contains('aa-1|0'));
    });
  });
}
