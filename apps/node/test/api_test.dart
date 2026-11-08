import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late EventLog log;
  late Handler handler;
  setUp(() {
    log = EventLog.open(':memory:', nodeId: 'A');
    handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
  });
  tearDown(() => log.close());

  Future<Response> post(Uint8List body) => Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: body)));
  Future<Response> get(String path) => Future.sync(() => handler(Request('GET', Uri.parse('http://localhost$path'))));
  Future<Object?> json(Response r) async => jsonDecode(await r.readAsString());

  test('POST /frame con un reporte válido responde 200 con un ACK de 22 bytes', () async {
    final r = await post(vectorBytes('sos_min'));
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], 'application/octet-stream');
    final bytes = Uint8List.fromList(await r.read().expand((c) => c).toList());
    expect(bytes.length, 22);
    expect(decodeAck(bytes, testKey).covers(17), isTrue);
  });

  test('POST /frame con basura responde 400 y no escribe nada', () async {
    final r = await post(Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(r.statusCode, 400);
    expect(log.all(), isEmpty);
  });

  test('GET /api/queue devuelve la cola priorizada', () async {
    await post(vectorBytes('sos_min'));
    final r = await get('/api/queue');
    expect(r.statusCode, 200);
    final list = (await json(r) as List).cast<Map<String, Object?>>();
    expect(list.length, 1);
    expect(list.single['reportKey'], '9a3c51e07b2d44f1-17');
    expect(list.single['urgency'], 'P1');
  });

  test('GET /api/events devuelve los eventos de un origen con seq mayor que after', () async {
    await post(vectorBytes('sos_min'));
    final r = await get('/api/events?origin=A&after=0');
    final list = (await json(r) as List).cast<Map<String, Object?>>();
    expect(list.single['type'], 'report.received');
    expect(list.single['id'], 'A:000001');
    final none = (await json(await get('/api/events?origin=A&after=1')) as List);
    expect(none, isEmpty);
  });

  test('GET /api/events sin origin responde 400', () async {
    expect((await get('/api/events')).statusCode, 400);
    expect((await get('/api/events?origin=A&after=abc')).statusCode, 400);
  });

  test('GET /api/health incluye el vector de versiones', () async {
    await post(vectorBytes('sos_min'));
    final h = (await json(await get('/api/health')))! as Map<String, Object?>;
    expect(h['node'], 'A');
    expect(h['events'], 1);
    expect(h['versionVector'], {'A': 1});
  });

  test('las rutas /api llevan CORS abierto para el tablero en desarrollo', () async {
    final r = await get('/api/queue');
    expect(r.headers['access-control-allow-origin'], '*');
  });

  test('una ruta desconocida responde 404', () async {
    expect((await get('/nope')).statusCode, 404);
  });

  test('POST /frame con un cuerpo enorme responde 413 y no escribe nada', () async {
    final r = await post(Uint8List(5000));
    expect(r.statusCode, 413);
    expect(log.all(), isEmpty);
  });

  test('GET /api/events limita la página a 1000 eventos aunque pidan más', () async {
    for (var i = 0; i < 1200; i++) {
      log.append('t', {'i': i});
    }
    final list = (await json(await get('/api/events?origin=A&after=0&limit=999999')) as List);
    expect(list.length, 1000);
  });
}
