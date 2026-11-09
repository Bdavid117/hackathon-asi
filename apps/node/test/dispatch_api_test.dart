import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// `POST /api/dispatch`: el canal por el que un despachador registra lo que oyó por radio, teléfono o en persona.
/// Se prueba el nodo ENTERO (ruta, agentes, cola, réplica), no funciones sueltas.
const String coordinator = 'coord-2026';
const String peerCode = 'pares-2026';

class _FakePort implements LlmPort {
  int calls = 0;
  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    calls++;
    return const LlmResult(text: '{"urgency":"P1","signals":[],"confidence":0.8,"escalate_to_human":false}', stopReason: 'end_turn');
  }
}

Map<String, Object?> informe([Map<String, Object?> over = const {}]) => {
  'id': 'a1b2c3d4e5f6',
  'text': 'hay gente atrapada en el segundo piso',
  'medium': 'radio',
  'origin': 'Estación 3',
  'who': 'Ana Gómez',
  ...over,
};

void main() {
  late EventLog log;
  late PipelineRunner pipeline;
  late QueueService queue;
  late Handler api;
  late Handler guarded;

  Handler build(EventLog l, {String? coordinatorToken, String? peerToken, PipelineRunner? p, QueueService? q}) => buildHandler(
    ingest: Ingest(log: l, key: _key),
    log: l,
    pipeline: p,
    queue: q,
    dispatch: Dispatch(l, clock: () => DateTime.fromMillisecondsSinceEpoch(1786370851000)),
    coordinatorToken: coordinatorToken,
    peerToken: peerToken,
  );

  setUp(() {
    log = EventLog.open(':memory:', nodeId: 'A');
    pipeline = PipelineRunner(log);
    queue = QueueService(log);
    api = build(log, p: pipeline, q: queue);
    guarded = build(log, p: pipeline, q: queue, coordinatorToken: coordinator, peerToken: peerCode);
  });
  tearDown(() => log.close());

  Future<Response> post(Handler h, Object? body, {Map<String, String>? headers, Stream<List<int>>? stream}) => Future.sync(
    () => h(Request('POST', Uri.parse('http://localhost/api/dispatch'), body: stream ?? (body is String ? body : jsonEncode(body)), headers: {'content-type': 'application/json', ...?headers})),
  );
  Future<Response> get(Handler h, String path, {Map<String, String>? headers}) => Future.sync(() => h(Request('GET', Uri.parse('http://localhost$path'), headers: headers)));
  Future<Map<String, Object?>> json(Response r) async => jsonDecode(await r.readAsString()) as Map<String, Object?>;
  int count() => log.allOfType('report.received').length;

  group('registrar un informe', () {
    test('responde 200 con el id del evento y la clave estable; escribe UN report.received', () async {
      final r = await post(api, informe());
      expect(r.statusCode, 200);
      final b = await json(r);
      expect(b['reportKey'], 'desp-a1b2c3d4e5f6');
      expect(b['duplicate'], false);
      expect(b['id'], log.allOfType('report.received').single.id);
    });

    test('el informe pasa por los agentes: queda su normalización y su triaje, y aparece en la cola con su fuente', () async {
      await post(api, informe());
      expect(log.allOfType('report.normalized').length, 1);
      expect(log.allOfType('triage.assessed').length, 1);
      final list = await json(await get(api, '/api/incidents'));
      final items = (list['items']! as List).cast<Map<String, Object?>>();
      expect(items.length, 1);
      final detail = await json(await get(api, '/api/incidents/${Uri.encodeComponent(items.single['id']! as String)}'));
      final obs = (detail['observations']! as List).cast<Map<String, Object?>>().single;
      expect(obs['source'], 'radio');
      expect(obs['origin'], 'Estación 3');
      expect(obs['registeredBy'], 'Ana Gómez');
      expect(obs['text'], 'hay gente atrapada en el segundo piso');
    });

    test('un reintento (mismo id, mismo contenido) responde 200 «duplicate» con el MISMO id y no vuelve a escribir ni a correr agentes', () async {
      final a = await json(await post(api, informe()));
      final before = log.count();
      final r = await post(api, informe());
      expect(r.statusCode, 200);
      final b = await json(r);
      expect(b['duplicate'], true);
      expect(b['id'], a['id']);
      expect(log.count(), before);
    });

    test('el mismo id con OTRO contenido responde 409, explica qué hacer y NO escribe nada', () async {
      await post(api, informe());
      final before = log.count();
      final r = await post(api, informe({'text': 'otra cosa'}));
      expect(r.statusCode, 409);
      expect(await r.readAsString(), contains('id'));
      expect(log.count(), before);
    });

    test('un informe registrado SE VE: tras el POST, un GET con el ETag anterior responde 200 con el incidente nuevo, no 304', () async {
      final first = await get(api, '/api/incidents');
      final etag = first.headers['etag']!;
      expect((await json(first))['total'], 0);
      await post(api, informe());
      final stale = await get(api, '/api/incidents', headers: {'if-none-match': etag});
      expect(stale.statusCode, 200, reason: 'un 304 aquí escondería al coordinador un informe ya registrado');
      expect((await json(stale))['total'], 1);
      expect(stale.headers['etag'], isNot(etag));
      final q = await get(api, '/api/queue');
      expect(await q.readAsString(), contains('desp-a1b2c3d4e5f6'));
    });

    test('lo mismo SIN agentes: el propio report.received invalida la caché (no depende de que el triaje escriba algo después)', () async {
      final l = EventLog.open(':memory:', nodeId: 'S');
      final h = build(l, q: QueueService(l)); // sin pipeline
      final etag = (await get(h, '/api/incidents')).headers['etag']!;
      await post(h, informe());
      final r = await get(h, '/api/incidents', headers: {'if-none-match': etag});
      expect(r.statusCode, 200);
      expect((await json(r))['total'], 1);
      l.close();
    });

    test('dos informes distintos son dos reportes; y el segundo no se confunde con el primero', () async {
      await post(api, informe());
      await post(api, informe({'id': 'zzzzzzzz1111', 'text': 'incendio en una bodega', 'origin': 'Estación 4'}));
      expect(count(), 2);
    });
  });

  group('lo que se rechaza NO escribe nada', () {
    test('415 si no es JSON (texto, formulario, sin tipo): un formulario de otra página no puede registrar informes', () async {
      for (final ct in ['text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data', 'application/jsonx', 'text/json']) {
        final r = await post(api, jsonEncode(informe()), headers: {'content-type': ct});
        expect(r.statusCode, 415, reason: 'content-type «$ct»');
      }
      // Sin cabecera de tipo: shelf pone «text/plain» a un cuerpo de texto, que tampoco es JSON.
      final sinTipo = await Future.sync(() => api(Request('POST', Uri.parse('http://localhost/api/dispatch'), body: jsonEncode(informe()))));
      expect(sinTipo.statusCode, 415);
      expect(log.count(), 0);
    });

    test('413 si el cuerpo declara o trae más de lo permitido (con o sin content-length)', () async {
      final pequeno = Stream<List<int>>.value(utf8.encode(jsonEncode(informe())));
      expect((await post(api, null, stream: pequeno, headers: {'content-length': '${kMaxDispatchBytes + 1}'})).statusCode, 413, reason: 'declarado');
      final big = Stream<List<int>>.fromIterable([List.filled(5000, 65), List.filled(5000, 65)]);
      expect((await post(api, null, stream: big)).statusCode, 413);
      expect(log.count(), 0);
    });

    test('400 con el motivo si el JSON está roto, no es UTF-8 o un campo no vale', () async {
      expect((await post(api, '{no es json')).statusCode, 400);
      expect((await post(api, null, stream: Stream.value([0xff, 0xfe, 0xfd]))).statusCode, 400);
      final r = await post(api, informe({'text': ''}));
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('text'));
      expect((await post(api, informe({'lat': 5.0}))).statusCode, 400);
      expect((await post(api, [1, 2, 3])).statusCode, 400);
      expect(log.count(), 0);
    });
  });

  group('con --coordinator-token', () {
    test('sin código o con el de la RÉPLICA: 401 y NADA escrito; con el del coordinador: 200', () async {
      expect((await post(guarded, informe())).statusCode, 401);
      expect((await post(guarded, informe(), headers: {'authorization': 'Bearer $peerCode'})).statusCode, 401);
      expect((await post(guarded, informe(), headers: {'authorization': 'Bearer otro'})).statusCode, 401);
      expect(log.count(), 0);
      expect((await post(guarded, informe(), headers: {'authorization': 'Bearer $coordinator'})).statusCode, 200);
      expect(count(), 1);
    });

    test('la autorización se comprueba ANTES que el cuerpo: sin código ni siquiera se distingue un cuerpo malo de uno bueno', () async {
      expect((await post(guarded, 'basura', headers: {'content-type': 'text/plain'})).statusCode, 401);
    });
  });

  group('el modelo de lenguaje NO ve el texto de este canal (sin redacción de datos personales)', () {
    test('con modelo configurado: un informe de despachador no genera consultas; una trama de la app, sí (el control)', () async {
      final port = _FakePort();
      final p = PipelineRunner(log, llm: port);
      final h = build(log, p: p, q: queue);
      await post(h, informe());
      await p.idle;
      expect(port.calls, 0);
      expect(p.llmStats!.consultas, 0);
      // El control: el mismo texto como trama de la app sí se consulta (si no, la prueba no probaría nada).
      final app = log.append(
        'report.received',
        {'device_id': 'abc', 'frame_seq': 1, 'flags': 0, 'text': 'hay gente atrapada en el segundo piso', 'received_at': 1, 'captured_at': 1},
        reportKey: 'abc-1',
        rev: 0,
      );
      p.run(app);
      await p.idle;
      expect(port.calls, 1);
    });

    test('y no ocupa un hueco de consulta: una ráfaga de informes no deja sin hueco a los reportes de la app (tope de 1, sin espera)', () async {
      final port = _FakePort();
      final p = PipelineRunner(log, llm: port, maxModelInFlight: 1, maxModelQueued: 0);
      final h = build(log, p: p, q: queue);
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        ids.add((await json(await post(h, informe({'id': 'rafaga-$i-abcdef'}))))['id']! as String);
      }
      // Los tres eventos llegan «de golpe» por réplica a otro runner con el mismo tope.
      final p2 = PipelineRunner(log, llm: port, maxModelInFlight: 1, maxModelQueued: 0);
      for (final id in ids) {
        p2.onReplicated(log.eventById(id)!);
      }
      await p2.idle;
      expect(p2.llmStats!.omitidas, 0, reason: 'un informe de despachador no debe gastar ni intentar gastar un hueco del modelo');
      expect(port.calls, 0);
    });

    test('enrich() tampoco lo consulta aunque se lo llamen directo; ni cuando el informe llega por réplica', () async {
      final port = _FakePort();
      final p = PipelineRunner(log, llm: port);
      final e = (await json(await post(build(log, p: p, q: queue), informe())))['id'];
      final ev = log.eventById(e! as String)!;
      expect(await p.enrich(ev), isNull);
      p.onReplicated(ev);
      await p.idle;
      expect(port.calls, 0);
    });
  });

  group('réplica y reinicio', () {
    test('el informe viaja a otro nodo como cualquier evento y allí aparece en la cola con su fuente', () async {
      await post(api, informe());
      final b = EventLog.open(':memory:', nodeId: 'B');
      for (final e in log.all()) {
        b.appendReplicated(e);
      }
      final apiB = build(b, p: PipelineRunner(b), q: QueueService(b));
      final list = await json(await get(apiB, '/api/incidents'));
      expect(list['total'], 1);
      final q = await get(apiB, '/api/queue');
      expect(await q.readAsString(), contains('"source":"radio"'));
      b.close();
    });

    test('REINICIO: un nodo con el log en disco se cierra y se reabre con el informe dentro: arranca y lo sigue mostrando', () async {
      final dir = Directory.systemTemp.createTempSync('sard-dispatch-api-');
      try {
        final path = '${dir.path}/log.db';
        var l = EventLog.open(path, nodeId: 'A');
        await post(build(l, p: PipelineRunner(l), q: QueueService(l)), informe());
        l.close();

        l = EventLog.open(path, nodeId: 'A');
        final h = build(l, p: PipelineRunner(l), q: QueueService(l)); // construir el nodo reconstruye Ingest: no puede lanzar
        expect((await json(await get(h, '/api/incidents')))['total'], 1);
        // Y el reintento tras el reinicio sigue siendo un reintento, no un informe nuevo.
        expect((await json(await post(h, informe())))['duplicate'], true);
        expect(l.allOfType('report.received').length, 1);
        l.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

final _key = _testKey();
Uint8List _testKey() => Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
