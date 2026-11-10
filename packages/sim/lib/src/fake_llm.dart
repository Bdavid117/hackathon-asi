import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cómo se porta el modelo falso.
enum FakeLlmMode {
  /// Responde un juicio válido (P1 «atrapado» si el texto dice «encerrados», P3 sin señales si no).
  ok,

  /// Responde un juicio válido pero CAUTO: nunca ve nada que subir (P3 sin señales aunque el texto diga «encerrados»). Sirve para
  /// que dos modelos contesten DISTINTO (uno `ok` y otro `cautious`) y comprobar que los nodos convergen aunque sus juicios difieran.
  cautious,

  /// Acepta la petición y NUNCA contesta (un modelo colgado).
  hang,

  /// Responde 500.
  error,

  /// Responde 200 con algo que no es JSON.
  garbage,

  /// Contesta bien, pero tras [FakeClaudeServer.delay].
  slow,
}

/// Un servidor HTTP que imita `POST /v1/messages` de la API del modelo, **sólo para pruebas y la
/// demostración**: permite probar al nodo cuando el modelo responde, se cuelga o falla, sin red ni clave
/// real. No es la API real: la respuesta se ajusta a lo que el nodo lee (`content[].text`, `stop_reason`).
class FakeClaudeServer {
  FakeClaudeServer._(this._server, this.mode, this.delay);

  final HttpServer _server;
  FakeLlmMode mode;
  Duration delay;
  int requests = 0;
  final List<Completer<void>> _held = [];

  Uri get url => Uri.parse('http://localhost:${_server.port}');
  int get port => _server.port;

  static Future<FakeClaudeServer> start({int port = 0, FakeLlmMode mode = FakeLlmMode.ok, Duration delay = const Duration(seconds: 3)}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeClaudeServer._(server, mode, delay);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    requests++;
    try {
      switch (mode) {
        case FakeLlmMode.hang:
          final held = Completer<void>();
          _held.add(held);
          await held.future; // hasta que se cierre el servidor
          return;
        case FakeLlmMode.error:
          req.response
            ..statusCode = 500
            ..write('{"type":"error"}');
        case FakeLlmMode.garbage:
          req.response
            ..statusCode = 200
            ..write('esto no es json');
        case FakeLlmMode.slow:
          await Future<void>.delayed(delay);
          _ok(req, body);
        case FakeLlmMode.ok:
          _ok(req, body);
        case FakeLlmMode.cautious:
          _ok(req, body, trapsAreRaised: false);
      }
    } finally {
      try {
        await req.response.close();
      } on Object {
        // el cliente se fue (plazo vencido): nada que hacer
      }
    }
  }

  void _ok(HttpRequest req, String body, {bool trapsAreRaised = true}) {
    final user = (((jsonDecode(body) as Map)['messages'] as List).first as Map)['content'] as String;
    final trapped = trapsAreRaised && user.contains('encerrados');
    final verdict = {
      'urgency': trapped ? 'P1' : 'P3',
      'signals': [if (trapped) {'code': 'atrapado', 'quote': 'encerrados'}],
      'confidence': 0.8,
      'escalate_to_human': false,
    };
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'content': [{'type': 'text', 'text': jsonEncode(verdict)}], 'stop_reason': 'end_turn'}));
  }

  Future<void> close() async {
    for (final h in _held) {
      if (!h.isCompleted) h.complete();
    }
    await _server.close(force: true);
  }
}
