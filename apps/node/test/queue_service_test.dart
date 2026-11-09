import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
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

    QueueService svc() => QueueService(log, clock: clock.call, compute: compute, slowMs: 200, maxStaleMs: 5000);

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

    test('sólo la invalidan los eventos que alimentan la cola: la auditoría y las normalizaciones no', () async {
      final s = svc();
      rec(log, 0, Random(1));
      await s.read();
      log.append('incident.linked', {'links': <Object?>[]}, reportKey: 'd0-1', rev: 0);
      log.append('report.normalized', {'x': 1}, reportKey: 'd0-1', rev: 0);
      await s.read();
      expect(computes, 1, reason: 'nada de lo que cambió entra en la cola');
      log.append('approval.granted', {'recommendationId': 'r'}, reportKey: 'd0-1', rev: 0);
      await s.read();
      expect(computes, 2, reason: 'una aprobación sí cambia lo que se muestra');
      rec(log, 1, Random(1));
      await s.read();
      expect(computes, 3);
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

    test('hay un TOPE de antigüedad: pasados 5 s la lectura espera al dato fresco aunque el cálculo sea lento', () async {
      final s = svc();
      rec(log, 0, Random(1));
      slowMs = 1000;
      await s.read();
      rec(log, 1, Random(1));
      gate = Completer<void>();
      // dentro del tope (3 s): se sirve lo viejo sin esperar
      clock.now = clock.now.add(const Duration(seconds: 3));
      expect((await s.read().timeout(const Duration(seconds: 2))).stale, isTrue);
      // pasado el tope (6 s en total): hay que esperar al dato fresco
      clock.now = clock.now.add(const Duration(seconds: 3));
      var done = false;
      final pending = s.read().then((r) {
        done = true;
        return r;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse, reason: 'una lectura de más de 5 s de antigüedad no debe servirse sin esperar');
      gate!.complete();
      final r = await pending;
      expect(r.stale, isFalse);
      expect(jsonDecode(r.json), [
        {'n': 2},
      ]);
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

  group('la misma pasada sirve la cola y los incidentes', () {
    test('con el cálculo por omisión, read() trae la cola, el resumen de incidentes y el detalle de cada uno', () async {
      rec(log, 0, Random(1));
      rec(log, 1, Random(1));
      final got = await QueueService(log).read();
      final queue = jsonDecode(got.json) as List;
      final incidents = (jsonDecode(got.incidentsPage(view: 'all')) as Map)['items'] as List;
      expect(queue, hasLength(2));
      expect(incidents, isNotEmpty);
      final id = (incidents.first as Map)['id'] as String;
      final detail = jsonDecode(got.detailOf(id)!) as Map;
      expect(detail['id'], id);
      expect(detail['observations'], isNotEmpty);
      expect(got.detailOf('no-existe-9'), isNull);
    });

    test('también con el cálculo en otro isolate (cola grande)', () async {
      final r = Random(2);
      for (var i = 0; i < 450; i++) {
        rec(log, i, r);
      }
      final got = await QueueService(log, isolateAbove: 100).read();
      final incidents = (jsonDecode(got.incidentsPage(view: 'all', limit: 1000)) as Map)['items'] as List;
      final queue = jsonDecode(got.json) as List;
      expect(incidents.fold<int>(0, (n, i) => n + ((i as Map)['size'] as int)), queue.length, reason: 'cada reporte está en exactamente un incidente');
      for (final i in incidents.take(5)) {
        expect(jsonDecode(got.detailOf((i as Map)['id'] as String)!), isA<Map>());
      }
    });

    test('los recursos declarados llegan a las recomendaciones', () async {
      log.append(
        'report.received',
        {'device_id': 'aa', 'frame_seq': 1, 'flags': 0x40, 'incident_type': 1, 'loc_quality': 2, 'lat': 5.07, 'lon': -75.51, 'text': null, 'captured_at': 1786370851, 'received_at': 5000},
        reportKey: 'aa-1',
        rev: 0,
      );
      final res = parseResources('{"resources":[{"id":"AMB-7","kind":"ambulancia","label":"Amb 7","lat":5.07,"lon":-75.51,"available":true}]}');
      final got = await QueueService(log, resources: res).read();
      final rec0 = (((jsonDecode(got.incidentsPage(view: 'all')) as Map)['items'] as List).single as Map)['recommendation'] as Map;
      expect(rec0['resourceIds'], ['AMB-7']);
    });

    test('una aprobación nueva invalida la caché y el estado se actualiza', () async {
      log.append(
        'report.received',
        {'device_id': 'aa', 'frame_seq': 1, 'flags': 0x40, 'incident_type': 1, 'loc_quality': 2, 'lat': 5.07, 'lon': -75.51, 'text': null, 'captured_at': 1786370851, 'received_at': 5000},
        reportKey: 'aa-1',
        rev: 0,
      );
      final s = QueueService(log);
      final first = (((jsonDecode((await s.read()).incidentsPage(view: 'all')) as Map)['items'] as List).single as Map);
      expect((first['approval'] as Map)['status'], 'pendiente');
      log.append(
        'approval.granted',
        {'recommendationId': (first['recommendation'] as Map)['id'], 'incidentId': 'aa-1', 'members': ['aa-1'], 'note': '', 'who': 'Ana'},
        reportKey: 'aa-1',
      );
      final second = (((jsonDecode((await s.read()).incidentsPage(view: 'all')) as Map)['items'] as List).single as Map);
      expect((second['approval'] as Map)['status'], 'aprobada');
    });
  });

  test('lanzar una lectura PESADA (10 000 reportes) no bloquea el hilo del nodo: ceder al bucle de eventos tarda < 3 s (el cálculo en el hilo principal tardaba ≈ 8 s)', () async {
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
    expect(yielded, lessThan(3000), reason: 'el hilo tardó $yielded ms en poder atender otra cosa (lectura completa: $total ms)');
    // Documenta el coste que SÍ queda en el hilo principal: leer los eventos y copiarlos al isolate.
    // ignore: avoid_print
    print('  → control devuelto al bucle de eventos en $yielded ms; lectura completa en $total ms');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
