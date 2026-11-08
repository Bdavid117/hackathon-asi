import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);

NewReport sos({int flags = SituationFlags.atrapado}) => NewReport(
      incidentType: 3, flags: flags, peopleBucket: 1, batteryQ: 3,
      locQuality: LocQuality.within50m, lat: 5.07, lon: -75.51,
    );

/// Un canal programable.
class _Fn implements Channel {
  _Fn(this.fn);
  final Future<Uint8List?> Function(Uint8List frame) fn;
  int calls = 0;
  @override
  Future<Uint8List?> send(Uint8List frame) {
    calls++;
    return fn(frame);
  }
}

/// Un nodo mínimo: guarda la trama y devuelve un ACK real de lo que guarda.
class _Node {
  final tracker = AckTracker();
  Future<Uint8List?> handle(Uint8List frame) async {
    final f = decodeReportFrame(frame, key);
    tracker.record(f.seq);
    return encodeAck(tracker.build(f.deviceId, f.seq), key);
  }
}

void main() {
  late Outbox outbox;
  DateTime now = t0;
  setUp(() {
    outbox = Outbox.open(':memory:', key: key);
    now = t0;
  });
  tearDown(() => outbox.close());

  SendScheduler scheduler(Channel ch, {int seed = 1}) =>
      SendScheduler(outbox: outbox, channel: ch, key: key, rng: Random(seed), clock: () => now);

  test('sin respuesta: la entrada vuelve a queued con 1 intento y un reintento en ≤ 2 s', () async {
    outbox.enqueueSos(sos(), now: t0);
    final acked = await scheduler(_Fn((_) async => null)).pump();
    expect(acked, 0);
    final e = outbox.all().single;
    expect(e.state, OutboxState.queued);
    expect(e.attempts, 1);
    expect(e.nextTryAt!.isAfter(now.subtract(const Duration(milliseconds: 1))), isTrue);
    expect(e.nextTryAt!.difference(now).inMilliseconds, lessThanOrEqualTo(2000));
  });

  test('la espera es configurable: con base 10 ms y tope 20 ms nunca pasa de 20 ms', () async {
    outbox.enqueueSos(sos(), now: t0);
    final s = SendScheduler(
      outbox: outbox, channel: _Fn((_) async => null), key: key, rng: Random(1), clock: () => now,
      backoffBase: const Duration(milliseconds: 10), backoffCap: const Duration(milliseconds: 20),
    );
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(seconds: 1));
      await s.pump();
      expect(outbox.all().single.nextTryAt!.difference(now).inMilliseconds, lessThanOrEqualTo(20));
    }
    expect(outbox.all().single.attempts, 6);
  });

  test('backoff: uniforme en [0, min(300 s, 2 s·2^intentos)] y nunca excede el tope', () {
    final rng = Random(3);
    for (var attempts = 0; attempts <= 40; attempts++) {
      final cap = min(300000, 2000 * (1 << min(attempts, 20)));
      for (var i = 0; i < 50; i++) {
        final d = SendScheduler.backoff(attempts, rng);
        expect(d.inMilliseconds, inInclusiveRange(0, cap), reason: 'intentos=$attempts');
        expect(d.inMilliseconds, lessThanOrEqualTo(300000));
      }
    }
  });

  test('con una respuesta válida la entrada pasa a sent y pump devuelve 1', () async {
    outbox.enqueueSos(sos(), now: t0);
    final node = _Node();
    expect(await scheduler(_Fn(node.handle)).pump(), 1);
    expect(outbox.all().single.state, OutboxState.sent);
  });

  test('un ACK con la etiqueta alterada es un fallo', () async {
    outbox.enqueueSos(sos(), now: t0);
    final node = _Node();
    final ch = _Fn((f) async => (await node.handle(f))!..[20] ^= 0xFF);
    expect(await scheduler(ch).pump(), 0);
    expect(outbox.all().single.state, OutboxState.queued);
    expect(outbox.all().single.attempts, 1);
  });

  test('un ACK válido que no cubre la trama enviada es un fallo', () async {
    outbox.enqueueSos(sos(), now: t0);
    final other = AckTracker()..record(99);
    final ch = _Fn((f) async => encodeAck(other.build(outbox.deviceId, 99), key));
    expect(await scheduler(ch).pump(), 0);
    expect(outbox.all().single.state, OutboxState.queued);
  });

  test('un canal que lanza una excepción se trata como un fallo', () async {
    outbox.enqueueSos(sos(), now: t0);
    expect(await scheduler(_Fn((_) async => throw Exception('boom'))).pump(), 0);
    expect(outbox.all().single.attempts, 1);
  });

  test('con FailoverChannel([caído, válido]) se acusa', () async {
    outbox.enqueueSos(sos(), now: t0);
    final node = _Node();
    final ch = FailoverChannel([_Fn((_) async => null), _Fn(node.handle)]);
    expect(await scheduler(ch).pump(), 1);
  });

  test('12 entradas vencidas: un pump envía 8; el siguiente envía el resto', () async {
    for (var i = 0; i < 12; i++) {
      outbox.enqueueSos(sos(), now: t0);
    }
    final node = _Node();
    final ch = _Fn(node.handle);
    final s = scheduler(ch);
    expect(await s.pump(), 8);
    expect(ch.calls, 8);
    expect(await s.pump(), 4);
  });

  test('una entrada fallida se reintenta cuando vence su espera', () async {
    outbox.enqueueSos(sos(), now: t0);
    final node = _Node();
    var up = false;
    final s = scheduler(_Fn((f) async => up ? node.handle(f) : null));
    await s.pump();
    expect(await s.pump(), 0); // aún no vence la espera
    up = true;
    now = now.add(const Duration(seconds: 3));
    expect(await s.pump(), 1);
    expect(outbox.all().single.state, OutboxState.sent);
  });

  group('HttpChannel', () {
    final node = Uri.parse('http://nodo:8081');
    final bytes = Uint8List.fromList([1, 2, 3]);

    test('200 devuelve el cuerpo y envía la trama por POST /frame', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes([9, 9], 200);
      });
      expect(await HttpChannel(node, client).send(bytes), [9, 9]);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/frame');
      expect(seen.bodyBytes, bytes);
    });

    test('un estado distinto de 200 o una excepción devuelven null', () async {
      expect(await HttpChannel(node, MockClient((_) async => http.Response('', 400))).send(bytes), isNull);
      expect(await HttpChannel(node, MockClient((_) async => throw http.ClientException('x'))).send(bytes), isNull);
    });

    test('un nodo que nunca responde devuelve null dentro del plazo', () async {
      final never = MockClient((_) => Future<http.Response>.delayed(const Duration(seconds: 30), () => http.Response('', 200)));
      final ch = HttpChannel(node, never, timeout: const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      expect(await ch.send(bytes), isNull);
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });
}
