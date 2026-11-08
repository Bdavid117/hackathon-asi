import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support.dart';

/// Un cliente HTTP que, en vez de salir a la red, invoca el Handler real de un nodo par.
http.Client clientFor(shelf.Handler peer) => MockClient((req) async {
      final r = await peer(shelf.Request(req.method, req.url, body: req.bodyBytes));
      return http.Response.bytes([for (final c in await r.read().toList()) ...c], r.statusCode, headers: r.headers);
    });

void main() {
  late EventLog a;
  late EventLog b;
  late shelf.Handler handlerB;
  final peer = Uri.parse('http://peer-b');

  setUp(() {
    a = EventLog.open(':memory:', nodeId: 'A');
    b = EventLog.open(':memory:', nodeId: 'B');
    handlerB = buildHandler(ingest: Ingest(log: b, key: testKey), log: b);
  });
  tearDown(() {
    a.close();
    b.close();
  });

  PollingReplicator replicator({http.Client? client}) =>
      PollingReplicator(log: a, peers: [peer], client: client ?? clientFor(handlerB));

  test('tras pullOnce el log de A contiene los eventos de B con su origen y seq originales', () async {
    b.append('report.received', {'n': 1}, reportKey: 'k-1', rev: 0);
    b.append('report.received', {'n': 2}, reportKey: 'k-2', rev: 0);
    expect(await replicator().pullOnce(), 2);
    expect(a.all().map((e) => e.id), ['B:000001', 'B:000002']);
    expect(a.versionVector(), {'B': 2});
  });

  test('una segunda llamada sin novedades devuelve 0', () async {
    b.append('t', {});
    final r = replicator();
    await r.pullOnce();
    expect(await r.pullOnce(), 0);
  });

  test('los eventos nuevos se traen de forma incremental', () async {
    final r = replicator();
    b.append('t', {'n': 1});
    await r.pullOnce();
    b.append('t', {'n': 2});
    b.append('t', {'n': 3});
    expect(await r.pullOnce(), 2);
    expect(a.all().length, 3);
  });

  test('un par caído (error de red o HTTP 500) se omite sin lanzar', () async {
    expect(await replicator(client: MockClient((_) async => throw const SocketException('caído'))).pullOnce(), 0);
    expect(await replicator(client: MockClient((_) async => http.Response('boom', 500))).pullOnce(), 0);
    expect(await replicator(client: MockClient((_) async => http.Response('no es json', 200))).pullOnce(), 0);
  });

  test('un par que no responde dentro del plazo se omite', () async {
    final slow = MockClient((_) => Future<http.Response>.delayed(const Duration(seconds: 5), () => http.Response('{}', 200)));
    final r = PollingReplicator(log: a, peers: [peer], client: slow, timeout: const Duration(milliseconds: 50));
    expect(await r.pullOnce(), 0);
  });

  test('no intenta traer los eventos de su propio origen aunque el par los tenga', () async {
    a.append('t', {'n': 1});
    // B ya replicó el evento de A; A no debe fallar ni duplicarlo al sondear a B.
    b.appendReplicated(a.all().single);
    expect(await replicator().pullOnce(), 0);
    expect(a.all().length, 1);
  });

  test('trae más de una página (1 200 eventos con páginas de 500)', () async {
    for (var i = 0; i < 1200; i++) {
      b.append('t', {'i': i});
    }
    expect(await replicator().pullOnce(), 1200);
    expect(a.versionVector(), {'B': 1200});
  });

  test('dos nodos que trabajaron aislados convergen al sondearse mutuamente', () async {
    a.append('t', {'de': 'A'});
    b.append('t', {'de': 'B'});
    final handlerA = buildHandler(ingest: Ingest(log: a, key: testKey), log: a);
    await PollingReplicator(log: a, peers: [peer], client: clientFor(handlerB)).pullOnce();
    await PollingReplicator(log: b, peers: [Uri.parse('http://peer-a')], client: clientFor(handlerA)).pullOnce();
    expect(a.versionVector(), {'A': 1, 'B': 1});
    expect(b.versionVector(), {'A': 1, 'B': 1});
    expect(a.all().length, 2);
    expect(b.all().length, 2);
  });
}
