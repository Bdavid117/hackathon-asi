import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_protocol/sard_protocol.dart';

/// Envía tramas a un nodo por `POST <nodo>/frame`.
///
/// Devuelve el cuerpo de la respuesta en un 200 y `null` en cualquier otro caso: error de
/// red, estado distinto de 200 o plazo vencido (un nodo que nunca responde no puede dejar
/// colgado al planificador).
class HttpChannel implements Channel {
  HttpChannel(this.node, this._client, {this.timeout = const Duration(seconds: 5)});

  final Uri node;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<Uint8List?> send(Uint8List frame) async {
    try {
      final r = await _client
          .post(node.resolve('/frame'), headers: {'content-type': 'application/octet-stream'}, body: frame)
          .timeout(timeout);
      return r.statusCode == 200 ? r.bodyBytes : null;
    } on Exception {
      return null;
    }
  }
}

/// Prueba los canales en orden y devuelve la primera respuesta no nula.
class FailoverChannel implements Channel {
  FailoverChannel(this._channels);

  final List<Channel> _channels;

  @override
  Future<Uint8List?> send(Uint8List frame) async {
    for (final ch in _channels) {
      try {
        final r = await ch.send(frame);
        if (r != null) return r;
      } on Exception {
        continue;
      }
    }
    return null;
  }
}
