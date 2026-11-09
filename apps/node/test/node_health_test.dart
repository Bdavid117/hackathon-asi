import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support.dart';

http.Client clientFor(shelf.Handler peer) => MockClient((req) async {
  final r = await peer(shelf.Request(req.method, req.url, body: req.bodyBytes));
  return http.Response.bytes([for (final c in await r.read().toList()) ...c], r.statusCode, headers: r.headers);
});

class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 8, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late EventLog a;
  late FakeClock clock;
  final peerB = Uri.parse('http://peer-b'), peerC = Uri.parse('http://peer-c');
  setUp(() {
    a = EventLog.open(':memory:', nodeId: 'A');
    clock = FakeClock();
  });
  tearDown(() => a.close());

  NodeHealth health(List<Uri> peers) => NodeHealth(nodeId: 'A', peers: peers, period: const Duration(seconds: 3), clock: clock.call);
  Map<String, Object?> peerOf(Map<String, Object?> j, Uri u) => ((j['peers']! as List).cast<Map<String, Object?>>()).firstWhere((p) => p['url'] == u.toString());

  group('NodeHealth: estado de los pares, en memoria', () {
    test('un nodo sin pares: su propia información y SIN «vista parcial»', () {
      a.append('x.y', {});
      final j = health([]).snapshot(a);
      expect((j['self']! as Map)['id'], 'A');
      expect((j['self']! as Map)['events'], 1);
      expect(j['peers'], isEmpty);
      expect(j['partialView'], isFalse);
    });

    test('tras un REINICIO un par es «desconocido» hasta hablar con él, y la vista es parcial (no se afirma «sincronizado»)', () {
      final j = health([peerB]).snapshot(a);
      expect(peerOf(j, peerB)['state'], 'desconocido');
      expect(peerOf(j, peerB)['lastSeenAgoMs'], isNull);
      expect(j['partialView'], isTrue);
      expect(j['reasons'], contains('par_desconocido'));
    });

    test('tras un contacto sin eventos pendientes: sincronizado, con cuándo', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 5, missingAfter: 0);
      clock.advance(const Duration(seconds: 2));
      final j = h.snapshot(a);
      final p = peerOf(j, peerB);
      expect(p['state'], 'sincronizado');
      expect(p['lastSeenAgoMs'], 2000);
      expect(p['missingEvents'], 0);
      expect(j['partialView'], isFalse);
    });

    test('un contacto que dejó eventos sin traer: atrasado y vista parcial', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 900, missingAfter: 400);
      final j = h.snapshot(a);
      expect(peerOf(j, peerB)['state'], 'atrasado');
      expect(peerOf(j, peerB)['missingEvents'], 400);
      expect(j['partialView'], isTrue);
      expect(j['reasons'], contains('faltan_eventos'));
    });

    test('un par que deja de responder: pasados 3 periodos sin verlo, «sin respuesta» y vista parcial', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      clock.advance(const Duration(seconds: 8)); // < 3 periodos (9 s)
      expect(peerOf(h.snapshot(a), peerB)['state'], 'sincronizado');
      clock.advance(const Duration(seconds: 2)); // 10 s > 9 s
      final j = h.snapshot(a);
      expect(peerOf(j, peerB)['state'], 'sin_respuesta');
      expect(j['partialView'], isTrue);
      expect(j['reasons'], contains('par_sin_respuesta'));
    });

    test('«última sincronización» sólo avanza cuando quedó al día: un contacto con faltantes no la mueve', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      clock.advance(const Duration(seconds: 2));
      h.recordContact(peerB, missingBefore: 50, missingAfter: 10);
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['lastSeenAgoMs'], 0, reason: 'se le vio ahora');
      expect(p['lastSyncAgoMs'], 2000, reason: 'pero la última vez que quedó al día fue hace 2 s');
      final fresh = health([peerB])..recordContact(peerB, missingBefore: 5, missingAfter: 5);
      expect(peerOf(fresh.snapshot(a), peerB)['lastSyncAgoMs'], isNull, reason: 'nunca estuvo al día');
    });

    test('un fallo registra el motivo pero no cambia el estado hasta pasar 3 periodos', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      clock.advance(const Duration(seconds: 3));
      h.recordFailure(peerB, 'tiempo agotado');
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['state'], 'sincronizado');
      expect(p['lastError'], 'tiempo agotado');
    });

    test('un contacto posterior borra el error y recupera el estado', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      clock.advance(const Duration(seconds: 20));
      h.recordFailure(peerB, 'caído');
      expect(peerOf(h.snapshot(a), peerB)['state'], 'sin_respuesta');
      h.recordContact(peerB, missingBefore: 3, missingAfter: 0);
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['state'], 'sincronizado');
      expect(p['lastError'], isNull);
    });

    test('con varios pares, basta uno que no esté al día para que la vista sea parcial, y se nombra cuál', () {
      final h = health([peerB, peerC]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      final j = h.snapshot(a);
      expect(peerOf(j, peerB)['state'], 'sincronizado');
      expect(peerOf(j, peerC)['state'], 'desconocido');
      expect(j['partialView'], isTrue);
    });

    test('un contacto de un par que no es de la configuración se ignora (no se crea un par)', () {
      final h = health([peerB]);
      h.recordContact(Uri.parse('http://intruso'), missingBefore: 0, missingAfter: 0);
      expect((h.snapshot(a)['peers']! as List), hasLength(1));
    });

    test('liveNodeIds: este nodo y los pares con identificador conocido que están sincronizados o atrasados', () {
      final h = health([peerB, peerC]);
      expect(h.liveNodeIds(), {'A'}, reason: 'nadie contactado todavía: sólo este nodo');
      h.recordContact(peerB, nodeId: 'B', missingBefore: 0, missingAfter: 0);
      expect(h.liveNodeIds(), {'A', 'B'});
      h.recordContact(peerC, nodeId: 'C', missingBefore: 9, missingAfter: 4);
      expect(h.liveNodeIds(), {'A', 'B', 'C'}, reason: 'un par atrasado sigue vivo');
      clock.advance(const Duration(seconds: 10));
      expect(h.liveNodeIds(), {'A'}, reason: 'pasados 3 periodos sin verlos ya no cuentan como vivos');
    });

    test('un contacto sin identificador del par no lo hace «vivo» para el reparto (no se sabe quién es)', () {
      final h = health([peerB]);
      h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
      expect(h.liveNodeIds(), {'A'});
    });

    test('el identificador del par se publica en /api/nodes', () {
      final h = health([peerB]);
      h.recordContact(peerB, nodeId: 'B', missingBefore: 0, missingAfter: 0);
      expect(peerOf(h.snapshot(a), peerB)['nodeId'], 'B');
    });

    test('NO escribe nada en el log: ni por latido ni por cambio de estado', () {
      final h = health([peerB]);
      final before = a.count();
      for (var i = 0; i < 50; i++) {
        h.recordContact(peerB, missingBefore: 0, missingAfter: 0);
        clock.advance(const Duration(seconds: 3));
        h.snapshot(a);
      }
      expect(a.count(), before);
    });
  });

  group('el replicador informa a NodeHealth', () {
    late EventLog b;
    late shelf.Handler handlerB;
    setUp(() {
      b = EventLog.open(':memory:', nodeId: 'B');
      handlerB = buildHandler(ingest: Ingest(log: b, key: testKey), log: b);
    });
    tearDown(() => b.close());

    test('un contacto bueno: sincronizado y con los eventos que faltaban antes', () async {
      b.append('report.received', {'n': 1}, reportKey: 'k-1', rev: 0);
      b.append('report.received', {'n': 2}, reportKey: 'k-2', rev: 0);
      final h = health([peerB]);
      await PollingReplicator(log: a, peers: [peerB], client: clientFor(handlerB), health: h).pullOnce();
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['state'], 'sincronizado');
      expect(p['missingEvents'], 0);
    });

    test('el replicador toma el identificador del par de su /api/health', () async {
      final h = health([peerB]);
      await PollingReplicator(log: a, peers: [peerB], client: clientFor(handlerB), health: h).pullOnce();
      expect(h.liveNodeIds(), {'A', 'B'});
    });

    test('un par caído: se registra el fallo y el estado sigue «desconocido»', () async {
      final h = health([peerB]);
      final down = MockClient((req) async => throw http.ClientException('conexión rechazada'));
      await PollingReplicator(log: a, peers: [peerB], client: down, health: h).pullOnce();
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['state'], 'desconocido');
      expect(p['lastError'], isNotNull);
    });

    test('un par que anuncia eventos que no entrega NO se da por al día: atrasado y con los faltantes', () async {
      final h = health([peerB]);
      final liar = MockClient((req) async {
        if (req.url.path == '/api/health') return http.Response('{"node":"C","events":5,"versionVector":{"C":5}}', 200);
        return http.Response('[]', 200); // promete 5 eventos de C y no entrega ninguno
      });
      await PollingReplicator(log: a, peers: [peerB], client: liar, health: h).pullOnce();
      final p = peerOf(h.snapshot(a), peerB);
      expect(p['state'], 'atrasado');
      expect(p['missingEvents'], 5);
      expect(p['lastSyncAgoMs'], isNull);
    });

    test('un par con respuestas inválidas no cuenta como contacto bueno', () async {
      final h = health([peerB]);
      final junk = MockClient((req) async => http.Response('no es json', 200));
      await PollingReplicator(log: a, peers: [peerB], client: junk, health: h).pullOnce();
      expect(peerOf(h.snapshot(a), peerB)['state'], 'desconocido');
    });
  });

  group('GET /api/nodes', () {
    test('sirve el estado de este nodo y sus pares, sin tocar el log', () async {
      final h = health([peerB]);
      final handler = buildHandler(ingest: Ingest(log: a, key: testKey), log: a, health: h);
      final before = a.count();
      final r = await Future.sync(() => handler(shelf.Request('GET', Uri.parse('http://localhost/api/nodes'))));
      expect(r.statusCode, 200);
      final body = await r.readAsString();
      expect(body, contains('"partialView":true'));
      expect(a.count(), before);
    });

    test('sin NodeHealth configurado, responde con un nodo solo y sin vista parcial', () async {
      final handler = buildHandler(ingest: Ingest(log: a, key: testKey), log: a);
      final r = await Future.sync(() => handler(shelf.Request('GET', Uri.parse('http://localhost/api/nodes'))));
      final body = await r.readAsString();
      expect(body, contains('"partialView":false'));
      expect(body, contains('"peers":[]'));
    });
  });
}
