import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'log_support.dart';
import 'support.dart';

const int now = 1800000000000;
int ago(Duration d) => now - d.inMilliseconds;

CoverageReport rep(double lat, double lon, Duration age, {bool urgent = false}) => CoverageReport(lat: lat, lon: lon, receivedAtMs: ago(age), urgent: urgent);

Map<String, Object?> cov(List<CoverageReport> r, {int withoutLocation = 0, int maxCells = kCoverageMaxCells}) => buildCoverage(r, nowMs: now, withoutLocation: withoutLocation, maxCells: maxCells);
List<Map<String, Object?>> cells(Map<String, Object?> c) => (c['cells']! as List).cast<Map<String, Object?>>();

void main() {
  group('buildCoverage: zonas que reportaron y callaron (el silencio NO es seguridad)', () {
    test('una celda con reportes hace 2 h y ninguno en los últimos 30 min es silenciosa', () {
      final c = cov([rep(5.0703, -75.5138, const Duration(hours: 2)), rep(5.0704, -75.5139, const Duration(hours: 3))]);
      expect(cells(c), hasLength(1));
      final cell = cells(c).single;
      expect((cell['total'], cell['urgent']), (2, 0));
      expect(cell['lastAtMs'], ago(const Duration(hours: 2)));
      expect((c['silentTotal'], c['activeCells']), (1, 0));
    });

    test('con UN reporte reciente en la celda ya no es silenciosa (y cuenta como celda activa)', () {
      final c = cov([rep(5.0703, -75.5138, const Duration(hours: 2)), rep(5.0704, -75.5139, const Duration(minutes: 5))]);
      expect(cells(c), isEmpty);
      expect((c['silentTotal'], c['activeCells']), (0, 1));
    });

    test('los reportes de hace más de 6 h no cuentan: una celda sin nada en la ventana no existe', () {
      final c = cov([rep(5.0703, -75.5138, const Duration(hours: 7))]);
      expect(cells(c), isEmpty);
      expect((c['silentTotal'], c['activeCells'], c['reportsInWindow']), (0, 0, 0));
    });

    test('los extremos exactos: 6 h cuenta; 6 h y 1 ms no; 30 min ya es silencio (menos de 30 min es reciente)', () {
      expect(cells(cov([rep(5.07, -75.51, const Duration(hours: 6))])), hasLength(1));
      expect(cells(cov([CoverageReport(lat: 5.07, lon: -75.51, receivedAtMs: now - const Duration(hours: 6).inMilliseconds - 1)])), isEmpty);
      expect(cells(cov([rep(5.07, -75.51, const Duration(minutes: 30))])), hasLength(1), reason: 'exactamente 30 min: ya no es reciente');
      expect(cells(cov([CoverageReport(lat: 5.07, lon: -75.51, receivedAtMs: now - const Duration(minutes: 30).inMilliseconds + 1)])), isEmpty, reason: '29 min 59,999 s: todavía reciente');
    });

    test('dos reportes a ~100 m caen en la MISMA celda; a ~2 km, en otra', () {
      final c = cov([rep(5.0700, -75.5100, const Duration(hours: 1)), rep(5.0708, -75.5100, const Duration(hours: 1)), rep(5.0900, -75.5100, const Duration(hours: 1))]);
      expect(cells(c).map((e) => e['total']).toList()..sort(), [1, 2]);
    });

    test('el borde de la rejilla es estable: 5.004999 y 5.0 comparten celda; 5.005 empieza la siguiente', () {
      final same = cells(cov([rep(5.0, -75.0, const Duration(hours: 1)), rep(5.004999, -75.0, const Duration(hours: 1))]));
      expect(same, hasLength(1));
      final next = cells(cov([rep(5.004999, -75.0, const Duration(hours: 1)), rep(5.005, -75.0, const Duration(hours: 1))]));
      expect(next, hasLength(2));
    });

    test('los límites exactos de la rejilla caen siempre en la celda que EMPIEZA ahí (la coma flotante no los corre a la vecina)', () {
      for (final k in [1, 2, 3, 7, 8, 9, 14, ...List.generate(201, (i) => 20800 + i)]) { // 1, 2, 3, 7… son fronteras donde SIN tolerancia (lon + 180) / 0,005 da k − 1e-12
        final lon = k * 0.005 - 180;
        final id = cells(cov([rep(5.07, lon, const Duration(hours: 1))])).single['id']! as String;
        expect(id.split(':').last, '$k', reason: 'lon $lon');
      }
    });

    test('a ambos lados del ecuador y del meridiano de Greenwich son celdas distintas (−0.001 y 0.001)', () {
      final c = cells(cov([rep(-0.001, -0.001, const Duration(hours: 1)), rep(0.001, 0.001, const Duration(hours: 1))]));
      expect(c, hasLength(2));
      final center = cells(cov([rep(-33.4501, -70.6501, const Duration(hours: 1))])).single;
      expect((center['lat']! as double), closeTo(-33.4501, 0.0026), reason: 'el centro de la celda cae a media celda del punto');
      expect((center['lon']! as double), closeTo(-70.6501, 0.0026));
    });

    test('el centro de la celda queda dentro de la propia celda', () {
      final p = rep(5.0703, -75.5138, const Duration(hours: 2));
      final cell = cells(cov([p])).single;
      expect(((cell['lat']! as double) - p.lat).abs(), lessThanOrEqualTo(kCoverageCellDeg / 2 + 1e-9));
      expect(((cell['lon']! as double) - p.lon).abs(), lessThanOrEqualTo(kCoverageCellDeg / 2 + 1e-9));
    });

    test('no depende del orden de entrada', () {
      final r = [for (var i = 0; i < 40; i++) rep(5.0 + (i % 7) * 0.006, -75.5 + (i % 5) * 0.006, Duration(minutes: 40 + i * 7), urgent: i % 9 == 0)];
      final a = jsonEncode(cov(r)), b = jsonEncode(cov(r.reversed.toList())), c = jsonEncode(cov([...r.skip(13), ...r.take(13)]));
      expect(a, b);
      expect(a, c);
    });

    test('lo urgente (P1 o P2) se cuenta aparte y ordena primero: una zona silenciosa que tuvo un P1 pesa más que otra con más reportes', () {
      final c = cov([
        for (var i = 0; i < 5; i++) rep(5.10, -75.50, Duration(hours: 1, minutes: i)),
        rep(5.30, -75.50, const Duration(hours: 2), urgent: true),
      ]);
      expect(cells(c).map((e) => (e['total'], e['urgent'])), [(1, 1), (5, 0)]);
    });

    test('un reporte con la recepción en el FUTURO (reloj del nodo atrasado) cuenta como ahora: la celda es activa, no silenciosa', () {
      final c = cov([CoverageReport(lat: 5.07, lon: -75.51, receivedAtMs: now + const Duration(hours: 1).inMilliseconds)]);
      expect(cells(c), isEmpty);
      expect(c['activeCells'], 1);
    });

    test('los reportes sin ubicación utilizable NO entran, y se dicen', () {
      final c = cov([rep(5.07, -75.51, const Duration(hours: 1))], withoutLocation: 4);
      expect(c['withoutLocation'], 4);
      expect(c['reportsInWindow'], 1);
    });

    test('con más de 400 celdas devuelve 400 y el total real; las que se quedan fuera son las de menos peso', () {
      final r = [
        for (var i = 0; i < 450; i++) rep(1.0 + (i ~/ 30) * 0.01, -70.0 + (i % 30) * 0.01, const Duration(hours: 1), urgent: i == 449),
      ];
      final c = cov(r);
      expect(cells(c), hasLength(kCoverageMaxCells));
      expect(c['silentTotal'], 450);
      expect(cells(c).first['urgent'], 1, reason: 'la celda urgente sale primera aunque sea la última en llegar');
      expect(cov(r, maxCells: 10)['cells'], hasLength(10));
    });

    test('sin reportes en la ventana: nada que marcar, y se dice que no hay actividad (no «todo en calma»)', () {
      final c = cov(const []);
      expect(cells(c), isEmpty);
      expect((c['silentTotal'], c['activeCells'], c['reportsInWindow']), (0, 0, 0));
      expect((c['activityMs'], c['silenceMs'], c['cellDeg']), (const Duration(hours: 6).inMilliseconds, const Duration(minutes: 30).inMilliseconds, kCoverageCellDeg));
    });

    test('un reporte con coordenadas no finitas se descarta sin romper', () {
      final c = cov([CoverageReport(lat: double.nan, lon: -75.5, receivedAtMs: ago(const Duration(hours: 1))), rep(5.07, -75.51, const Duration(hours: 1))]);
      expect(cells(c), hasLength(1));
    });
  });

  group('countInWindow (cuántos reportes sin ubicación entran en la ventana)', () {
    test('cuenta los de las últimas 6 h (inclusive) y no los más viejos; el futuro cuenta', () {
      final at = [ago(const Duration(hours: 1)), ago(const Duration(hours: 6)), now - const Duration(hours: 6).inMilliseconds - 1, now + 5000];
      expect(countInWindow(at, nowMs: now), 3);
      expect(countInWindow(const [], nowMs: now), 0);
    });
  });

  group('GET /api/coverage', () {
    late EventLog log;
    late Handler open, guarded;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      open = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, queue: QueueService(log, resources: testResources(), clock: () => DateTime.fromMillisecondsSinceEpoch(now)));
      guarded = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: 'coord-2026', queue: QueueService(log, resources: testResources(), clock: () => DateTime.fromMillisecondsSinceEpoch(now)));
    });
    tearDown(() => log.close());

    Future<Response> get(Handler h, {String? auth}) => Future.sync(() => h(Request('GET', Uri.parse('http://localhost/api/coverage'), headers: {'authorization': ?auth})));

    test('devuelve las zonas silenciosas de lo que el nodo tiene, con sus ventanas', () async {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado, text: 'atrapado', receivedAt: ago(const Duration(hours: 2)));
      received(log, 'bb-1', 0, text: 'sin ubicación', lat: null, lon: null, locQuality: 0, receivedAt: ago(const Duration(hours: 1)));
      final r = await get(open);
      expect(r.statusCode, 200);
      final body = (jsonDecode(await r.readAsString()) as Map).cast<String, Object?>();
      expect((body['cells'] as List), hasLength(1));
      expect(((body['cells'] as List).single as Map)['urgent'], 1, reason: 'un atrapado es P1');
      expect(body['withoutLocation'], 1, reason: 'el reporte sin ubicación no entra y se dice');
      expect(body['silenceMs'], const Duration(minutes: 30).inMilliseconds);
    });

    test('pide el código de acceso como todo /api/ y no aparece en la cola ni en la lista (la huella no puede cambiar)', () async {
      received(log, 'aa-1', 0, text: 'algo', receivedAt: ago(const Duration(hours: 2)));
      expect((await get(guarded)).statusCode, 401);
      expect((await get(guarded, auth: 'Bearer nope-nope')).statusCode, 401);
      expect((await get(guarded, auth: 'Bearer coord-2026')).statusCode, 200);
      final queue = jsonDecode(await (await Future.sync(() => open(Request('GET', Uri.parse('http://localhost/api/queue'))))).readAsString()) as List;
      for (final row in queue.cast<Map>()) {
        expect(row.containsKey('coverage'), isFalse);
      }
      final page = jsonDecode(await (await Future.sync(() => open(Request('GET', Uri.parse('http://localhost/api/incidents?view=all'))))).readAsString()) as Map;
      expect(page.containsKey('coverage'), isFalse);
    });

    test('una celda con un reporte reciente NO aparece; sin datos, la respuesta es válida y vacía', () async {
      var body = (jsonDecode(await (await get(open)).readAsString()) as Map).cast<String, Object?>();
      expect((body['cells'] as List), isEmpty);
      received(log, 'aa-1', 0, text: 'algo', receivedAt: ago(const Duration(minutes: 3)));
      body = (jsonDecode(await (await get(open)).readAsString()) as Map).cast<String, Object?>();
      expect((body['cells'] as List), isEmpty);
      expect(body['activeCells'], 1);
    });
  });
}
