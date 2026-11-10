import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Un proxy HTTP con INTERRUPTOR para cortar el enlace entre dos nodos de verdad (no «sin pares»): el nodo origen sigue creyendo que
/// el par existe, intenta replicar y recibe errores de conexión, que es lo que pasa en una partición real.
///
/// `cut()` rompe la conexión de cada petición nueva SIN que llegue al destino (como un cable cortado: el cliente ve un error de
/// conexión, no una respuesta). `heal()` la restablece. Si el destino cae, el proxy contesta 502.
class PartitionProxy {
  PartitionProxy._(this._server, this._target, this._client);

  final HttpServer _server;
  final Uri _target;
  final http.Client _client;
  bool _cut = false;
  int _forwarded = 0, _refused = 0;

  /// Arranca el proxy en [port] (0 = uno libre) reenviando a [target].
  static Future<PartitionProxy> start({required Uri target, int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final proxy = PartitionProxy._(server, target, http.Client());
    server.listen(proxy._handle, onError: (Object _) {});
    return proxy;
  }

  /// Por dónde se llega al destino a través del proxy.
  Uri get url => Uri.parse('http://localhost:${_server.port}');
  bool get isCut => _cut;

  /// Peticiones que pasaron al destino y peticiones cuya conexión se rompió por el corte.
  int get forwarded => _forwarded;
  int get refused => _refused;

  void cut() => _cut = true;
  void heal() => _cut = false;

  Future<void> close() async {
    await _server.close(force: true);
    _client.close();
  }

  static const _hopByHop = {'host', 'connection', 'content-length', 'transfer-encoding', 'keep-alive', 'upgrade', 'proxy-connection', 'te', 'trailer'};

  Future<void> _handle(HttpRequest req) async {
    if (_cut) {
      _refused++;
      try {
        (await req.response.detachSocket(writeHeaders: false)).destroy();
      } on Object {
        // la conexión ya estaba rota: es lo que se quería
      }
      return;
    }
    try {
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final out = http.Request(req.method, _target.replace(path: req.uri.path, query: req.uri.hasQuery ? req.uri.query : null))..bodyBytes = body;
      req.headers.forEach((name, values) {
        if (!_hopByHop.contains(name.toLowerCase())) out.headers[name] = values.join(', ');
      });
      final res = await _client.send(out);
      final bytes = await res.stream.toBytes();
      req.response.statusCode = res.statusCode;
      res.headers.forEach((name, value) {
        if (!_hopByHop.contains(name.toLowerCase())) req.response.headers.set(name, value);
      });
      req.response.add(bytes);
      _forwarded++;
      await req.response.close();
    } on Object {
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } on Object {
        // el cliente ya se fue
      }
    }
  }
}
