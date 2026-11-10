import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// Un destino de eco: dice qué recibió y cuenta las peticiones. `/status/<n>` responde con ese estado.
class Echo {
  Echo._(this.server);
  final HttpServer server;
  int received = 0;
  Uri get url => Uri.parse('http://localhost:${server.port}');

  static Future<Echo> start() async {
    final e = Echo._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    e.server.listen((req) async {
      e.received++;
      final body = await utf8.decoder.bind(req).join();
      final m = RegExp(r'^/status/(\d+)$').firstMatch(req.uri.path);
      req.response
        ..statusCode = m == null ? 200 : int.parse(m.group(1)!)
        ..headers.contentType = ContentType.json
        ..headers.set('x-eco', 'si')
        ..write(jsonEncode({'method': req.method, 'target': req.uri.toString(), 'x-test': req.headers.value('x-test'), 'body': body}));
      await req.response.close();
    });
    return e;
  }
}

void main() {
  late Echo echo;
  late PartitionProxy proxy;
  late http.Client client;
  setUp(() async {
    echo = await Echo.start();
    proxy = await PartitionProxy.start(target: echo.url);
    client = http.Client();
  });
  tearDown(() async {
    client.close();
    await proxy.close();
    await echo.server.close(force: true);
  });

  test('con el enlace cerrado reenvía método, ruta con consulta, cabeceras y cuerpo, y devuelve lo que contesta el destino', () async {
    final r = await client.post(proxy.url.resolve('/api/events?origin=A&after=3'), headers: {'x-test': 'hola'}, body: 'cuerpo de prueba');
    expect(r.statusCode, 200);
    expect(r.headers['x-eco'], 'si');
    expect(jsonDecode(utf8.decode(r.bodyBytes)), {'method': 'POST', 'target': '/api/events?origin=A&after=3', 'x-test': 'hola', 'body': 'cuerpo de prueba'});
  });

  test('el estado del destino se transmite tal cual (404, 500)', () async {
    expect((await client.get(proxy.url.resolve('/status/404'))).statusCode, 404);
    expect((await client.get(proxy.url.resolve('/status/500'))).statusCode, 500);
  });

  test('cortado: la conexión se rompe y el destino NO recibe nada', () async {
    proxy.cut();
    expect(proxy.isCut, isTrue);
    await expectLater(client.get(proxy.url.resolve('/x')).timeout(const Duration(seconds: 5)), throwsA(anyOf(isA<http.ClientException>(), isA<SocketException>(), isA<TimeoutException>())));
    expect(echo.received, 0);
  });

  test('heal restablece el paso', () async {
    proxy.cut();
    await client.get(proxy.url.resolve('/x')).then<void>((_) {}, onError: (Object _) {});
    proxy.heal();
    expect(proxy.isCut, isFalse);
    expect((await client.get(proxy.url.resolve('/x'))).statusCode, 200);
    expect(echo.received, 1);
  });

  test('cuenta lo reenviado y lo rechazado', () async {
    await client.get(proxy.url.resolve('/a'));
    await client.get(proxy.url.resolve('/b'));
    proxy.cut();
    await client.get(proxy.url.resolve('/c')).then<void>((_) {}, onError: (Object _) {});
    expect((proxy.forwarded, proxy.refused), (2, 1));
  });

  test('un destino caído da 502 (no cuelga ni lanza)', () async {
    await echo.server.close(force: true);
    final r = await client.get(proxy.url.resolve('/x')).timeout(const Duration(seconds: 10));
    expect(r.statusCode, 502);
  });

  test('close libera el puerto', () async {
    final port = proxy.url.port;
    await proxy.close();
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
  });
}
