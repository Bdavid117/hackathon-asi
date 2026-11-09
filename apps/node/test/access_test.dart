import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Códigos de acceso: lo que ve y decide el coordinador (`--coordinator-token`) y la réplica entre nodos
/// (`--peer-token`). NO es identidad: un código compartido no dice QUIÉN aprobó (eso lo declara la persona
/// en «who»). Sólo impide que cualquiera que llegue por red lea ubicaciones o lance aprobaciones.
const coordinator = 'coord-2026';
const peerCode = 'pares-2026';

void main() {
  late EventLog log;
  late Handler guarded;
  late Handler open;

  setUp(() {
    log = EventLog.open(':memory:', nodeId: 'A');
    guarded = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: coordinator, peerToken: peerCode);
    open = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
  });
  tearDown(() => log.close());

  Future<Response> get(Handler h, String path, {String? auth}) => Future.sync(() => h(Request('GET', Uri.parse('http://localhost$path'), headers: {'authorization': ?auth})));

  Map<String, Object?> okApproval() => {
    'recommendationId': 'a1b2c3d4e5f60718',
    'incidentId': 'aa-1',
    'members': ['aa-1'],
    'decision': 'granted',
    'note': '',
    'who': 'Ana Gómez',
  };

  Future<Response> postApproval(Handler h, {String? auth, Object? body}) => Future.sync(
    () => h(Request('POST', Uri.parse('http://localhost/api/approval'), body: jsonEncode(body ?? okApproval()), headers: {'content-type': 'application/json', 'authorization': ?auth})),
  );

  int approvals() => log.allOfType('approval.granted').length + log.allOfType('approval.denied').length;

  const coordinatorPaths = ['/api/queue', '/api/incidents', '/api/incidents/aa-1', '/api/nodes'];

  group('con --coordinator-token: lo del coordinador exige el código', () {
    for (final path in coordinatorPaths) {
      test('GET $path: 401 sin código, 401 con uno equivocado, y pasa con el bueno', () async {
        expect((await get(guarded, path)).statusCode, 401, reason: 'sin cabecera');
        expect((await get(guarded, path, auth: 'Bearer otro-codigo')).statusCode, 401, reason: 'código equivocado');
        final r = await get(guarded, path, auth: 'Bearer $coordinator');
        expect(r.statusCode, isNot(401), reason: 'con el código se atiende (200, o 404 si el incidente no existe)');
      });
    }

    test('POST /api/approval: sin código no se registra NADA (el log queda igual) y con código se registra', () async {
      final before = log.count();
      expect((await postApproval(guarded)).statusCode, 401);
      expect((await postApproval(guarded, auth: 'Bearer nope')).statusCode, 401);
      expect(approvals(), 0);
      expect(log.count(), before, reason: 'ni un evento por una petición no autorizada');
      final r = await postApproval(guarded, auth: 'Bearer $coordinator');
      expect(r.statusCode, 200);
      expect(approvals(), 1);
    });

    test('la autorización se comprueba ANTES que el resto: sin código, ni siquiera se distingue un cuerpo malo de uno bueno', () async {
      final bad = await Future.sync(() => guarded(Request('POST', Uri.parse('http://localhost/api/approval'), body: 'basura', headers: {'content-type': 'text/plain'})));
      expect(bad.statusCode, 401, reason: 'no 415: una petición sin código no puede sondear la validación');
    });

    test('el 401 dice cómo autenticarse y NO repite el código recibido ni el esperado', () async {
      final r = await get(guarded, '/api/queue', auth: 'Bearer intento-secreto-42');
      expect(r.statusCode, 401);
      expect(r.headers['www-authenticate'], startsWith('Bearer'));
      final body = await r.readAsString();
      expect(body, isNot(contains('intento-secreto-42')));
      expect(body, isNot(contains(coordinator)));
      expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('la comparación es exacta: prefijos, sufijos, mayúsculas, espacios y otros esquemas NO sirven', () async {
      for (final bad in [
        'Bearer ${coordinator}x',
        'Bearer ${coordinator.substring(0, coordinator.length - 1)}',
        'Bearer ${coordinator.toUpperCase()}',
        'Bearer  $coordinator',
        'Bearer $coordinator ',
        'Bearer ',
        'Bearer',
        'Basic $coordinator',
        coordinator,
        'Token $coordinator',
      ]) {
        expect((await get(guarded, '/api/queue', auth: bad)).statusCode, 401, reason: '«$bad»');
      }
    });

    test('el esquema «Bearer» no distingue mayúsculas (así lo define el estándar)', () async {
      expect((await get(guarded, '/api/queue', auth: 'bearer $coordinator')).statusCode, 200);
      expect((await get(guarded, '/api/queue', auth: 'BEARER $coordinator')).statusCode, 200);
    });

    test('el código de la RÉPLICA no abre lo del coordinador (se separan: quien copia el log no decide)', () async {
      expect((await get(guarded, '/api/queue', auth: 'Bearer $peerCode')).statusCode, 401);
      expect((await postApproval(guarded, auth: 'Bearer $peerCode')).statusCode, 401);
      expect(approvals(), 0);
    });
  });

  group('con --peer-token: la réplica (/api/events, que entrega los reportes crudos con ubicación) exige el suyo', () {
    test('401 sin código y con el del coordinador; pasa con el de pares', () async {
      expect((await get(guarded, '/api/events?origin=A&after=0')).statusCode, 401);
      expect((await get(guarded, '/api/events?origin=A&after=0', auth: 'Bearer $coordinator')).statusCode, 401);
      expect((await get(guarded, '/api/events?origin=A&after=0', auth: 'Bearer $peerCode')).statusCode, 200);
    });

    test('un nodo sólo con --coordinator-token deja /api/events ABIERTO (avisado al arrancar): no se asume una protección que no se pidió', () async {
      final soloCoordinador = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: coordinator);
      expect((await get(soloCoordinador, '/api/events?origin=A&after=0')).statusCode, 200);
      expect((await get(soloCoordinador, '/api/queue')).statusCode, 401);
    });
  });

  group('denegado por omisión', () {
    test('una ruta que no existe (o que se añada mañana) bajo /api/ también exige código: 401, no 404', () async {
      for (final path in ['/api/lo-que-sea', '/api/admin/borrar', '/api/incidents/aa-1/extra']) {
        expect((await get(guarded, path)).statusCode, 401, reason: path);
        expect((await get(guarded, path, auth: 'Bearer $coordinator')).statusCode, 404, reason: '$path con código: no existe');
      }
    });

    test('el tablero estático y lo que no es /api/ siguen abiertos', () async {
      expect((await get(guarded, '/index.html')).statusCode, isNot(401));
      expect((await get(guarded, '/')).statusCode, isNot(401));
    });
  });

  group('lo que siempre queda abierto', () {
    test('POST /frame (los ciudadanos no tienen código) y GET /api/health (sin datos de nadie)', () async {
      final r = await Future.sync(() => guarded(Request('POST', Uri.parse('http://localhost/frame'), body: sosFrame(1))));
      expect(r.statusCode, 200);
      expect((await get(guarded, '/api/health')).statusCode, 200);
    });

    test('un nodo SIN códigos se comporta exactamente como antes', () async {
      for (final p in [...coordinatorPaths, '/api/events?origin=A&after=0', '/api/health']) {
        expect((await get(open, p)).statusCode, isNot(401), reason: p);
      }
      expect((await postApproval(open)).statusCode, 200);
    });
  });

  group('la réplica entre nodos con código', () {
    late EventLog b;
    late Handler handlerB;
    setUp(() {
      b = EventLog.open(':memory:', nodeId: 'B');
      handlerB = buildHandler(ingest: Ingest(log: b, key: testKey), log: b, peerToken: peerCode);
      b.append('report.received', {'n': 1}, reportKey: 'k-1', rev: 0);
    });
    tearDown(() => b.close());

    http.Client clientFor(Handler peer) => MockClient((req) async {
      final r = await peer(Request(req.method, req.url, body: req.bodyBytes, headers: req.headers));
      return http.Response.bytes([for (final c in await r.read().toList()) ...c], r.statusCode, headers: r.headers);
    });

    test('con el código de pares trae los eventos', () async {
      final r = PollingReplicator(log: log, peers: [Uri.parse('http://peer-b')], client: clientFor(handlerB), peerToken: peerCode);
      expect(await r.pullOnce(), 1);
    });

    test('sin él (o con uno equivocado) no trae NADA y lo anota como fallo del par, sin lanzar', () async {
      final health = NodeHealth(nodeId: 'A', peers: [Uri.parse('http://peer-b')]);
      for (final tok in [null, 'equivocado']) {
        final r = PollingReplicator(log: log, peers: [Uri.parse('http://peer-b')], client: clientFor(handlerB), peerToken: tok, health: health);
        expect(await r.pullOnce(), 0, reason: 'token $tok');
      }
      expect(log.count(), 0);
      final snap = health.snapshot(log);
      expect(jsonEncode(snap), contains('401'), reason: 'el fallo se ve en /api/nodes, no se esconde');
    });
  });
}
