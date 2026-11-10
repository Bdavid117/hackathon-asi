import 'package:http/http.dart' as http;
import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

void main() {
  late FakeClaudeServer server;
  tearDown(() => server.close());

  Future<TriageResult> ask(String text, {Duration timeout = const Duration(seconds: 2), List<String>? reasons}) {
    final port = ClaudeHttpPort(client: http.Client(), apiKey: 'falsa', baseUrl: server.url);
    return triageWithModel(port, 0, text, timeout: timeout, onFallback: reasons?.add);
  }

  test('ok: un texto que dice «encerrados» da un P1 con la cita exacta, y lo valida el propio nodo', () async {
    server = await FakeClaudeServer.start();
    final t = await ask('quedamos encerrados en el segundo piso');
    expect(t.mode, 'rules+llm');
    expect(t.urgency, Urgency.p1);
    expect(t.evidence.any((e) => e.quote == 'encerrados'), isTrue);
    expect(server.requests, 1);
  });

  test('cautious: aunque el texto diga «encerrados» no sube la urgencia (otro modelo que contesta DISTINTO que ok)', () async {
    server = await FakeClaudeServer.start(mode: FakeLlmMode.cautious);
    final t = await ask('quedamos encerrados en el segundo piso');
    expect(t.mode, 'rules+llm', reason: 'el juicio es válido: sólo que no ve nada que subir');
    expect(t.signals, isEmpty);
    expect(t.urgency, isNot(Urgency.p1));
    expect(server.requests, 1);
  });

  test('ok: un texto sin pistas da P3 sin señales', () async {
    server = await FakeClaudeServer.start();
    final t = await ask('necesitamos ayuda por favor');
    expect(t.mode, 'rules+llm');
    expect(t.signals, isEmpty);
  });

  test('hang: nunca contesta; el cliente cae al respaldo por reglas dentro de su plazo', () async {
    server = await FakeClaudeServer.start(mode: FakeLlmMode.hang);
    final reasons = <String>[];
    final sw = Stopwatch()..start();
    final t = await ask('quedamos encerrados', timeout: const Duration(milliseconds: 300), reasons: reasons);
    expect(t.mode, 'rules');
    expect(reasons, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('error 500 y respuesta basura: respaldo por reglas con su motivo', () async {
    server = await FakeClaudeServer.start(mode: FakeLlmMode.error);
    final r1 = <String>[];
    expect((await ask('quedamos encerrados', reasons: r1)).mode, 'rules');
    expect(r1.single, contains('500'));
    server.mode = FakeLlmMode.garbage;
    final r2 = <String>[];
    expect((await ask('quedamos encerrados', reasons: r2)).mode, 'rules');
    expect(r2, isNotEmpty);
  });

  test('slow: contesta bien pero tarde: dentro del plazo sirve, fuera no', () async {
    server = await FakeClaudeServer.start(mode: FakeLlmMode.slow, delay: const Duration(milliseconds: 400));
    expect((await ask('quedamos encerrados', timeout: const Duration(seconds: 3))).mode, 'rules+llm');
    expect((await ask('quedamos encerrados', timeout: const Duration(milliseconds: 100))).mode, 'rules');
  });

  test('cerrar el servidor libera las peticiones retenidas (no deja procesos colgados)', () async {
    server = await FakeClaudeServer.start(mode: FakeLlmMode.hang);
    final pending = ask('x y z', timeout: const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.close();
    await pending; // el cliente no se queda esperando 5 s
    server = await FakeClaudeServer.start(); // para el tearDown
  });
}
