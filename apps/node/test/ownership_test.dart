import 'dart:async';
import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'log_support.dart';

const String paraphrase = 'quedamos encerrados y se prendió todo';

/// Una clave que, entre {A, B, C}, tiene como dueño a B y como siguiente a A (valores de oro del rendezvous).
const String keyOwnedByB = 'a1b2c3d4e5f60718-1';

class CountingPort implements LlmPort {
  int calls = 0;
  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    calls++;
    return LlmResult(
      text: jsonEncode({
        'urgency': 'P1',
        'signals': [
          {'code': 'atrapado', 'quote': 'quedamos encerrados'},
        ],
        'confidence': 0.8,
        'escalate_to_human': false,
      }),
      stopReason: 'end_turn',
    );
  }
}

/// Un modelo que falla o responde bien según el intento.
class _FlakyPort implements LlmPort {
  _FlakyPort(this.failOn);
  final LlmResult? Function() failOn;
  int calls = 0;
  final CountingPort _ok = CountingPort();

  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    calls++;
    return failOn() ?? await _ok.completeJson(request);
  }
}

class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 8, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('OwnershipPolicy: quién hace el trabajo caro de cada reporte', () {
    OwnershipPolicy policy(String self, Set<String> live, {Duration takeover = const Duration(seconds: 10)}) => OwnershipPolicy(selfId: self, liveNodes: () => live, takeoverAfter: takeover);

    test('un nodo solo es siempre el dueño y no espera', () {
      final p = policy('A', {});
      expect(p.isOwner(keyOwnedByB), isTrue);
      expect(p.delayFor(keyOwnedByB), Duration.zero);
    });

    test('con A, B y C: B es dueño, A espera un plazo y C dos', () {
      expect(policy('B', {'A', 'B', 'C'}).delayFor(keyOwnedByB), Duration.zero);
      expect(policy('A', {'A', 'B', 'C'}).delayFor(keyOwnedByB), const Duration(seconds: 10));
      expect(policy('C', {'A', 'B', 'C'}).delayFor(keyOwnedByB), const Duration(seconds: 20));
    });

    test('este nodo siempre cuenta aunque la lista de vivos no lo incluya', () {
      expect(policy('A', {'B'}).delayFor(keyOwnedByB), const Duration(seconds: 10));
    });

    test('si el dueño deja de estar vivo, el siguiente pasa a ser dueño SIN esperar', () {
      expect(policy('A', {'A', 'B', 'C'}).isOwner(keyOwnedByB), isFalse);
      expect(policy('A', {'A', 'C'}).isOwner(keyOwnedByB), isTrue, reason: 'B cayó (kill -9): A toma sus reportes');
    });

    test('due: un reporte tocó a este nodo si es el dueño o si ya pasó su plazo desde que se recibió', () {
      final p = policy('A', {'A', 'B'});
      final received = DateTime.utc(2026, 11, 8, 12);
      expect(p.due(keyOwnedByB, received, received), isFalse);
      expect(p.due(keyOwnedByB, received, received.add(const Duration(seconds: 9))), isFalse);
      expect(p.due(keyOwnedByB, received, received.add(const Duration(seconds: 10))), isTrue);
      expect(policy('B', {'A', 'B'}).due(keyOwnedByB, received, received), isTrue);
    });
  });

  group('el modelo sólo lo consulta el dueño; el relevo, si el dueño no cumplió', () {
    late EventLog log;
    setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
    tearDown(() => log.close());

    PipelineRunner runner(CountingPort port, String self, Set<String> live, {Duration takeover = const Duration(milliseconds: 80)}) =>
        PipelineRunner(log, llm: port, ownership: OwnershipPolicy(selfId: self, liveNodes: () => live, takeoverAfter: takeover));

    Event report() => received(log, keyOwnedByB, 0, text: paraphrase, device: 'a1b2c3d4e5f60718');

    test('el DUEÑO consulta al modelo enseguida', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B', 'C'});
      r.run(report());
      await r.idle;
      expect(port.calls, 1);
    });

    test('quien NO es dueño no lo consulta al recibir: sólo las reglas, y el ACK/reglas no esperan', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'B', 'C'}, takeover: const Duration(seconds: 30));
      final sw = Stopwatch()..start();
      final events = r.run(report());
      expect(sw.elapsedMilliseconds, lessThan(500), reason: 'las reglas no esperan al relevo');
      expect(events.map((e) => e.type), ['report.normalized', 'triage.assessed']);
      expect(port.calls, 0);
    });

    test('RELEVO: si el dueño no produjo el evento pasado el plazo, el siguiente consulta al modelo', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'B', 'C'});
      r.run(report());
      await r.idle;
      expect(port.calls, 1);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('si el evento del dueño LLEGA replicado antes del plazo, el relevo no consulta (no duplica)', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'B', 'C'}, takeover: const Duration(milliseconds: 200));
      final rec = report();
      r.run(rec);
      // el dueño B respondió y su evento llega por replicación
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log.append(
        'triage.assessed',
        {'urgency': 'P1', 'signals': ['atrapado'], 'mode': 'rules+llm', 'evidence': [{'code': 'atrapado', 'quote': 'quedamos encerrados'}], 'confidence': 0.8, 'uncertainty': <String>[], 'escalate_to_human': false, 'analyzed_text': paraphrase},
        reportKey: keyOwnedByB,
        rev: 0,
        inputs: [rec.id],
      );
      await r.idle;
      expect(port.calls, 0);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('FALSA ALARMA: si el dueño sí estaba vivo pero lento y ambos consultan, sólo cuesta cómputo (un único juicio por texto)', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'B', 'C'});
      final rec = report();
      r.run(rec);
      await r.idle;
      await runner(port, 'B', {'A', 'B', 'C'}).enrich(rec); // el dueño llega tarde
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1), reason: 'idempotente por texto analizado');
    });

    test('sin política (un nodo solo, o sin configurar) todo sigue igual que antes', () async {
      final port = CountingPort();
      final r = PipelineRunner(log, llm: port);
      r.run(report());
      await r.idle;
      expect(port.calls, 1);
    });

    test('el dueño que cae (kill -9): el siguiente pasa a ser dueño y consulta sin esperar el plazo', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'C'}, takeover: const Duration(seconds: 30)); // B ya no está vivo
      r.run(report());
      await r.idle;
      expect(port.calls, 1);
    });
  });

  group('lo que llega por REPLICACIÓN: el dueño también lo procesa', () {
    late EventLog log;
    setUp(() => log = EventLog.open(':memory:', nodeId: 'B'));
    tearDown(() => log.close());

    PipelineRunner runner(CountingPort port, String self, Set<String> live, {Duration takeover = const Duration(milliseconds: 80)}) =>
        PipelineRunner(log, llm: port, ownership: OwnershipPolicy(selfId: self, liveNodes: () => live, takeoverAfter: takeover));

    // El reporte entró por OTRO nodo (A): aquí sólo existe porque se replicó.
    Event replicated() => received(log, keyOwnedByB, 0, text: paraphrase, device: 'a1b2c3d4e5f60718');

    test('si este nodo es el dueño, consulta al modelo de un reporte que le llegó replicado, sin esperar', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B'}, takeover: const Duration(seconds: 30));
      r.onReplicated(replicated());
      await r.idle;
      expect(port.calls, 1);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('si NO es el dueño, espera su plazo de relevo (y si el dueño responde antes, no consulta)', () async {
      final port = CountingPort();
      final r = runner(port, 'A', {'A', 'B'}, takeover: const Duration(milliseconds: 200));
      final rec = replicated();
      r.onReplicated(rec);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log.append(
        'triage.assessed',
        {'urgency': 'P1', 'signals': ['atrapado'], 'mode': 'rules+llm', 'evidence': [{'code': 'atrapado', 'quote': 'quedamos encerrados'}], 'confidence': 0.8, 'uncertainty': <String>[], 'escalate_to_human': false, 'analyzed_text': paraphrase},
        reportKey: keyOwnedByB,
        rev: 0,
        inputs: [rec.id],
      );
      await r.idle;
      expect(port.calls, 0);
    });

    test('los eventos que no son reportes recibidos se ignoran', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B'});
      r.onReplicated(log.append('triage.assessed', {'urgency': 'P3', 'signals': <String>[], 'mode': 'rules'}, reportKey: keyOwnedByB, rev: 0));
      r.onReplicated(log.append('approval.granted', {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'x', 'who': 'Ana'}));
      await r.idle;
      expect(port.calls, 0);
    });

    test('un evento de OTRO tipo de un reporte que ya existe no dispara una consulta', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B'});
      replicated(); // el reporte ya está aquí, pero no se ofreció al modelo
      r.onReplicated(log.append('triage.assessed', {'urgency': 'P3', 'signals': <String>[], 'mode': 'rules'}, reportKey: keyOwnedByB, rev: 0));
      await r.idle;
      expect(port.calls, 0);
    });

    test('si la consulta falló (sin evento), una nueva oferta del mismo reporte SÍ reintenta: no queda vetado', () async {
      var attempt = 0;
      final port = _FlakyPort(() => ++attempt == 1 ? const LlmResult(error: 'HTTP 500') : null);
      final r = PipelineRunner(log, llm: port, ownership: OwnershipPolicy(selfId: 'B', liveNodes: () => {'A', 'B'}));
      final rec = replicated();
      r.onReplicated(rec);
      await r.idle;
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), isEmpty);
      r.onReplicated(rec);
      await r.idle;
      expect(port.calls, 2);
      expect(log.allOfType('triage.assessed').where((e) => e.body['mode'] == 'rules+llm'), hasLength(1));
    });

    test('sin modelo configurado no hace nada', () async {
      final r = PipelineRunner(log, ownership: OwnershipPolicy(selfId: 'B', liveNodes: () => {'A', 'B'}));
      r.onReplicated(replicated());
      await r.idle;
      expect(log.allOfType('triage.assessed'), isEmpty);
    });

    test('el mismo reporte que llega por la trama Y por replicación se consulta UNA vez', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B'});
      final rec = replicated();
      r.run(rec); // llegó la trama aquí
      r.onReplicated(rec); // y además se replicó desde el otro nodo
      await r.idle;
      expect(port.calls, 1);
    });

    test('un reporte sin texto no consulta al modelo', () async {
      final port = CountingPort();
      final r = runner(port, 'B', {'A', 'B'});
      r.onReplicated(received(log, keyOwnedByB, 0, device: 'a1b2c3d4e5f60718'));
      await r.idle;
      expect(port.calls, 0);
    });
  });

  group('auditoría: el dueño la hace; el relevo, si no quedó marca de que se hizo', () {
    late EventLog log;
    late FakeClock clock;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      clock = FakeClock();
    });
    tearDown(() => log.close());

    AuditLinker linker(String self, Set<String> live) => AuditLinker(
      log,
      clock: clock.call,
      minInterval: Duration.zero,
      ownership: OwnershipPolicy(selfId: self, liveNodes: () => live, takeoverAfter: const Duration(seconds: 10)),
    );

    Event twoLinked() {
      final first = received(log, keyOwnedByB, 0, device: 'a1b2c3d4e5f60718', receivedAt: clock.now.millisecondsSinceEpoch);
      received(log, 'ccdd-1', 0, lat: 5.0704, device: 'ccdd', receivedAt: clock.now.millisecondsSinceEpoch);
      return first;
    }

    test('el dueño examina enseguida y deja UN evento marcador del lote con lo examinado', () async {
      twoLinked();
      await linker('B', {'A', 'B', 'C'}).runOnce();
      final batches = log.allOfType('audit.batch');
      expect(batches, hasLength(1), reason: 'un marcador por lote, no uno por reporte');
      expect((batches.single.body['examined']! as List), contains('$keyOwnedByB|0'));
    });

    test('quien no es dueño NO examina antes de su plazo', () async {
      twoLinked();
      final a = linker('A', {'A', 'B', 'C'});
      expect(await a.runOnce(), 0);
      expect(log.allOfType('audit.batch'), isEmpty);
    });

    test('pasado el plazo y sin marca del dueño, el relevo examina', () async {
      twoLinked();
      final a = linker('A', {'A', 'B', 'C'});
      await a.runOnce();
      clock.advance(const Duration(seconds: 11));
      await a.runOnce();
      expect((log.allOfType('audit.batch').single.body['examined']! as List), contains('$keyOwnedByB|0'));
    });

    test('si la marca del dueño llega replicada, el relevo NO repite el trabajo', () async {
      twoLinked();
      log.append('audit.batch', {'examined': ['$keyOwnedByB|0', 'ccdd-1|0'], 'agent_version': kAgentVersion});
      clock.advance(const Duration(seconds: 11));
      final a = linker('A', {'A', 'B', 'C'});
      var computed = 0;
      final b = AuditLinker(log, clock: clock.call, minInterval: Duration.zero, compute: (r, t) {
        computed++;
        return computeAuditLinks(r, t);
      }, ownership: OwnershipPolicy(selfId: 'A', liveNodes: () => {'A', 'B', 'C'}, takeoverAfter: const Duration(seconds: 10)));
      await a.runOnce();
      await b.runOnce();
      expect(computed, 0);
    });

    test('lo diferido NO queda dado por hecho: tick vuelve a mirar aunque no haya reportes nuevos', () async {
      twoLinked();
      final a = linker('A', {'A', 'B', 'C'});
      expect(await a.tick(), isTrue, reason: 'primer lote: nada le toca todavía');
      expect(await a.tick(), isFalse, reason: 'sin novedades y sin nada vencido, no hace nada');
      clock.advance(const Duration(seconds: 11));
      expect(await a.tick(), isTrue, reason: 'venció el plazo de lo diferido');
      expect(log.allOfType('audit.batch'), hasLength(1));
    });

    test('un nodo solo (sin política) audita como siempre', () async {
      twoLinked();
      final solo = AuditLinker(log, clock: clock.call, minInterval: Duration.zero);
      await solo.runOnce();
      expect(log.allOfType('audit.batch'), hasLength(1));
    });

    test('un reporte ya marcado como examinado no se examina de nuevo tras reiniciar el proceso', () async {
      twoLinked();
      await linker('B', {'A', 'B', 'C'}).runOnce();
      final again = await linker('B', {'A', 'B', 'C'}).runOnce();
      expect(again, 0);
      expect(log.allOfType('audit.batch'), hasLength(1));
    });
  });
}
