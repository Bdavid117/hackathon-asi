import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_agents/sard_agents.dart';
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

  test('GET /api/queue expone grupo, fuentes, confianza, incertidumbre, escalado y sugerencias', () async {
    await post(vectorBytes('sos_min'));
    final q = (await json(await get('/api/queue')))! as List<Object?>;
    final item = q.single! as Map<String, Object?>;
    for (final k in ['group', 'groupSize', 'groupUrgency', 'sources', 'confidence', 'uncertainty', 'escalate', 'similar']) {
      expect(item.containsKey(k), isTrue, reason: k);
    }
  });

  test('GET /api/health incluye las estadísticas del modelo sólo si hay modelo configurado', () async {
    expect(((await json(await get('/api/health')))! as Map).containsKey('llm'), isFalse);
    final h2 = buildHandler(
      ingest: Ingest(log: log, key: testKey),
      log: log,
      pipeline: PipelineRunner(log, llm: _NullPort()),
    );
    final r = await Future.sync(() => h2(Request('GET', Uri.parse('http://localhost/api/health'))));
    final body = jsonDecode(await r.readAsString()) as Map<String, Object?>;
    expect(body['llm'], {'consultas': 0, 'usadas': 0, 'omitidas': 0, 'fallos': <String, int>{}});
  });

  test('GET /api/queue dice la frescura: x-queue-stale y x-queue-age-ms', () async {
    await post(vectorBytes('sos_min'));
    final r = await get('/api/queue');
    expect(r.headers['x-queue-stale'], 'false');
    expect(int.tryParse(r.headers['x-queue-age-ms'] ?? ''), isNotNull);
  });

  group('GET /api/incidents y /api/incidents/<id>', () {
    test('la lista trae un resumen por incidente, con las cabeceras de frescura', () async {
      await post(vectorBytes('sos_min'));
      final r = await get('/api/incidents');
      expect(r.statusCode, 200);
      expect(r.headers['x-queue-stale'], 'false');
      expect(r.headers['x-queue-age-ms'], isNotNull);
      final env = (await json(r))! as Map<String, Object?>;
      expect(env['view'], 'short');
      expect((env['counters']! as Map)['incidents'], 1);
      final i = (env['items']! as List).single! as Map<String, Object?>;
      for (final k in ['id', 'urgency', 'size', 'members', 'signals', 'people', 'peopleLabel', 'sources', 'uncertainty', 'needsReview', 'bareSos', 'recommendation', 'approval', 'sharedResources']) {
        expect(i.containsKey(k), isTrue, reason: k);
      }
    });

    test('el detalle de un incidente trae las observaciones originales, la recomendación y la aprobación', () async {
      await post(vectorBytes('sos_min'));
      final id = ((((await json(await get('/api/incidents?view=all')))! as Map)['items'] as List).single as Map)['id'] as String;
      final r = await get('/api/incidents/$id');
      expect(r.statusCode, 200);
      expect(r.headers['x-queue-stale'], isNotNull);
      final d = (await json(r))! as Map<String, Object?>;
      expect(d['id'], id);
      expect((d['observations']! as List), isNotEmpty);
      expect((d['members']! as List).first, isA<String>(), reason: 'members son las claves; las observaciones van aparte');
      expect(d.containsKey('recommendation'), isTrue);
      expect((d['approval']! as Map)['status'], 'pendiente');
    });

    test('parámetros inválidos responden 400 y no rompen: vista, urgencia, límite, desplazamiento, bare', () async {
      for (final q in ['view=todo', 'view=all&urgency=P9', 'view=all&limit=0', 'view=all&limit=abc', 'view=all&offset=-1', 'view=all&bare=quizas', 'urgency=P1', 'bare=true']) {
        expect((await get('/api/incidents?$q')).statusCode, 400, reason: q);
      }
      expect((await get('/api/health')).statusCode, 200);
    });

    test('la vista completa admite páginas y filtros', () async {
      await post(vectorBytes('sos_min'));
      final p = (await json(await get('/api/incidents?view=all&limit=1&offset=0&urgency=P1')))! as Map<String, Object?>;
      expect(p['view'], 'all');
      expect(p['limit'], 1);
      final none = (await json(await get('/api/incidents?view=all&offset=99')))! as Map<String, Object?>;
      expect(none['items'], isEmpty);
    });

    test('un incidente desconocido responde 404 (también con ids raros) y no rompe el nodo', () async {
      await post(vectorBytes('sos_min'));
      for (final id in ['no-existe-1', '..%2F..%2Fetc', '%00', 'a%20b', 'x' * 500]) {
        expect((await get('/api/incidents/$id')).statusCode, 404, reason: id);
      }
      expect((await get('/api/health')).statusCode, 200);
    });

    test('sin la bandera --cors no llevan access-control-allow-origin', () async {
      await post(vectorBytes('sos_min'));
      final id = ((((await json(await get('/api/incidents?view=all')))! as Map)['items'] as List).single as Map)['id'] as String;
      for (final p in ['/api/incidents', '/api/incidents/$id', '/api/nodes']) {
        expect((await get(p)).headers.containsKey('access-control-allow-origin'), isFalse, reason: p);
      }
    });
  });

  group('ETag: un tablero que sondea sin cambios no vuelve a descargar nada', () {
    Future<Response> getWith(String path, {String? ifNoneMatch}) => Future.sync(
      () => handler(Request('GET', Uri.parse('http://localhost$path'), headers: {'if-none-match': ?ifNoneMatch})),
    );

    for (final path in ['/api/queue', '/api/incidents', '/api/incidents?view=all&limit=5']) {
      test('$path: la segunda lectura con el mismo ETag responde 304 sin cuerpo, y sigue declarando su frescura', () async {
        await post(vectorBytes('sos_min'));
        final first = await get(path);
        final tag = first.headers['etag'];
        expect(tag, isNotNull);
        final again = await getWith(path, ifNoneMatch: tag);
        expect(again.statusCode, 304);
        expect(await again.readAsString(), isEmpty);
        expect(again.headers['x-queue-stale'], isNotNull);
        expect(again.headers['x-queue-age-ms'], isNotNull);
        expect(again.headers['etag'], tag);
      });
    }

    test('si llega un reporte, el ETag cambia y la lectura vuelve a traer el cuerpo', () async {
      await post(vectorBytes('sos_min'));
      final tag = (await get('/api/incidents')).headers['etag'];
      await post(sosFrame(2, deviceHex: 'aaaaaaaaaaaaaaaa'));
      final r = await getWith('/api/incidents', ifNoneMatch: tag);
      expect(r.statusCode, 200);
      expect(r.headers['etag'], isNot(tag));
    });

    test('tras REINICIAR el nodo el ETag no se repite: un tablero con un ETag viejo no recibe un 304 falso', () async {
      await post(vectorBytes('sos_min'));
      final oldTag = (await get('/api/incidents')).headers['etag'];
      // «reinicio»: otro proceso con el mismo log (misma versión calculada, datos que pueden diferir)
      final restarted = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
      final r = await Future.sync(() => restarted(Request('GET', Uri.parse('http://localhost/api/incidents'), headers: {'if-none-match': oldTag!})));
      expect(r.statusCode, 200);
      expect(r.headers['etag'], isNot(oldTag));
    });

    test('un ETag de otra consulta no vale: cada página tiene el suyo', () async {
      await post(vectorBytes('sos_min'));
      final shortTag = (await get('/api/incidents')).headers['etag'];
      final r = await getWith('/api/incidents?view=all', ifNoneMatch: shortTag);
      expect(r.statusCode, 200);
    });

    test('un ETag que no es el vigente (basura incluida) se ignora y se sirve el cuerpo', () async {
      await post(vectorBytes('sos_min'));
      for (final bad in ['W/"0:"', '*', '""', 'basura', 'x' * 500]) {
        expect((await getWith('/api/queue', ifNoneMatch: bad)).statusCode, 200, reason: bad);
      }
    });
  });

  group('CORS: por omisión una página ajena NO puede leer la cola ni la salud del nodo', () {
    test('sin la bandera no se envía access-control-allow-origin en ninguna ruta de lectura', () async {
      await post(vectorBytes('sos_min'));
      for (final path in ['/api/queue', '/api/health', '/api/events?origin=A&after=0']) {
        final r = await get(path);
        expect(r.headers.containsKey('access-control-allow-origin'), isFalse, reason: path);
      }
    });

    test('con cors: true (sólo desarrollo) sí se permite', () async {
      final h = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, cors: true);
      for (final path in ['/api/queue', '/api/health']) {
        final r = await Future.sync(() => h(Request('GET', Uri.parse('http://localhost$path'))));
        expect(r.headers['access-control-allow-origin'], '*', reason: path);
      }
    });

    test('una petición previa (OPTIONS) de otro origen no se contesta con permisos', () async {
      final r = await Future.sync(() => handler(Request('OPTIONS', Uri.parse('http://localhost/api/queue'), headers: {'origin': 'http://malo.example', 'access-control-request-method': 'POST'})));
      expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(r.headers.containsKey('access-control-allow-methods'), isFalse);
    });
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

class _NullPort implements LlmPort {
  @override
  Future<LlmResult> completeJson(LlmRequest request) async => const LlmResult(error: 'no usado');
}
