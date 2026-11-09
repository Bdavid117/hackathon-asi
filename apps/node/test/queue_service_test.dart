import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

Event rec(EventLog log, int i, Random r) {
  const texts = ['puente colapsado calle veinte carros abajo', 'hay heridos en el edificio de la esquina', null, null];
  final lat = r.nextInt(10) == 0 ? null : 5.07 + r.nextDouble() * 0.18;
  return log.append(
    'report.received',
    {
      'device_id': 'd${i % 900}',
      'frame_seq': 1,
      'flags': r.nextInt(4) == 0 ? 0x80 : 0,
      'incident_type': 1,
      'loc_quality': lat == null ? 0 : 2,
      'lat': lat,
      'lon': lat == null ? null : -75.52 + r.nextDouble() * 0.18,
      'text': texts[r.nextInt(texts.length)],
      'captured_at': 1786370851 + r.nextInt(7200),
      'received_at': 5000,
    },
    reportKey: 'd$i-1',
    rev: 0,
  );
}

/// Un reloj que sólo avanza cuando se le dice.
class FakeClock {
  DateTime now = DateTime.utc(2026, 8, 10, 14);
  DateTime call() => now;
}

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('contenido', () {
    test('lo que devuelve es EXACTAMENTE la cola de buildQueue (cálculo en línea, cola pequeña)', () async {
      final r = Random(1);
      for (var i = 0; i < 40; i++) {
        rec(log, i, r);
      }
      final got = await QueueService(log).read();
      expect(jsonDecode(got.json), jsonDecode(jsonEncode([for (final i in buildQueue(log)) i.toJson()])));
      expect(got.stale, isFalse);
    });

    test('y también con el cálculo en otro isolate (cola grande)', () async {
      final r = Random(2);
      for (var i = 0; i < 450; i++) {
        rec(log, i, r);
      }
      final got = await QueueService(log, isolateAbove: 100).read();
      expect(jsonDecode(got.json), jsonDecode(jsonEncode([for (final i in buildQueue(log)) i.toJson()])));
    });
  });

  group('caché y lecturas simultáneas', () {
    late int computes;
    late FakeClock clock;
    Completer<void>? gate;
    int slowMs = 0;

    Future<String> compute(List<Event> received, List<Event> triage) async {
      computes++;
      clock.now = clock.now.add(Duration(milliseconds: slowMs));
      if (gate != null) await gate!.future;
      return jsonEncode([
        {'n': received.length},
      ]);
    }

    QueueService svc() => QueueService(log, clock: clock.call, compute: compute, slowMs: 200);

    setUp(() {
      computes = 0;
      clock = FakeClock();
      gate = null;
      slowMs = 0;
    });

    test('la primera lectura siempre espera al cálculo', () async {
      rec(log, 0, Random(1));
      final got = await svc().read();
      expect(jsonDecode(got.json), [
        {'n': 1},
      ]);
      expect(got.stale, isFalse);
      expect(computes, 1);
    });

    test('si el log no cambió no se recalcula', () async {
      rec(log, 0, Random(1));
      final s = svc();
      await s.read();
      await s.read();
      await s.read();
      expect(computes, 1);
    });

    test('si cambió y el cálculo es rápido, la lectura espera y devuelve lo fresco', () async {
      final s = svc();
      rec(log, 0, Random(1));
      await s.read();
      rec(log, 1, Random(1));
      final got = await s.read();
      expect(jsonDecode(got.json), [
        {'n': 2},
      ]);
      expect(got.stale, isFalse);
      expect(computes, 2);
    });

    test('si cambió y el cálculo anterior fue LENTO, se devuelve el viejo marcado «stale» sin esperar', () async {
      final s = svc();
      rec(log, 0, Random(1));
      slowMs = 1000; // el cálculo tarda «1 s» según el reloj
      await s.read();
      rec(log, 1, Random(1));
      gate = Completer<void>();
      final got = await s.read().timeout(const Duration(seconds: 2)); // no debe quedarse esperando a la puerta
      expect(got.stale, isTrue);
      expect(jsonDecode(got.json), [
        {'n': 1},
      ]);
      gate!.complete();
      await s.idle;
      final later = await s.read();
      expect(later.stale, isFalse);
      expect(jsonDecode(later.json), [
        {'n': 2},
      ], reason: 'el cálculo en segundo plano terminó');
    });

    test('dos lecturas simultáneas con cambios comparten UN solo cálculo', () async {
      final s = svc();
      rec(log, 0, Random(1));
      await s.read();
      rec(log, 1, Random(1));
      gate = Completer<void>();
      final a = s.read(), b = s.read();
      gate!.complete();
      await Future.wait([a, b]);
      expect(computes, 2);
    });

    test('un cálculo que falla no deja colgado el servicio: la siguiente lectura reintenta', () async {
      var fail = true;
      final s = QueueService(
        log,
        clock: clock.call,
        compute: (r, t) async {
          computes++;
          if (fail) throw StateError('boom');
          return '[]';
        },
      );
      rec(log, 0, Random(1));
      await expectLater(s.read(), throwsStateError);
      fail = false;
      expect((await s.read()).json, '[]');
    });

    test('la edad del dato crece con el reloj', () async {
      final s = svc();
      rec(log, 0, Random(1));
      slowMs = 500;
      await s.read();
      rec(log, 1, Random(1));
      gate = Completer<void>();
      clock.now = clock.now.add(const Duration(seconds: 3));
      final got = await s.read();
      expect(got.stale, isTrue);
      expect(got.ageMs, greaterThanOrEqualTo(3000));
      gate!.complete();
      await s.idle;
    });
  });

  test('lanzar una lectura PESADA (10 000 reportes) no bloquea el hilo del nodo: ceder al bucle de eventos tarda < 1 s', () async {
    final r = Random(3);
    for (var i = 0; i < 10000; i++) {
      rec(log, i, r);
    }
    final s = QueueService(log, isolateAbove: 100);
    // El cronómetro arranca ANTES de lanzar la lectura y se mide cuánto tarda en volver el control
    // al bucle de eventos (lo que tardaría en atenderse un ACK que llegara en ese momento). Si el
    // cálculo corriera en este hilo, aquí se verían varios segundos.
    final sw = Stopwatch()..start();
    final pending = s.read();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final yielded = sw.elapsedMilliseconds;
    final got = await pending;
    final total = sw.elapsedMilliseconds;
    expect(jsonDecode(got.json), isA<List<Object?>>());
    expect(yielded, lessThan(1000), reason: 'el hilo tardó $yielded ms en poder atender otra cosa (lectura completa: $total ms)');
    // Documenta el coste que SÍ queda en el hilo principal: leer los eventos y copiarlos al isolate.
    // ignore: avoid_print
    print('  → control devuelto al bucle de eventos en $yielded ms; lectura completa en $total ms');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
