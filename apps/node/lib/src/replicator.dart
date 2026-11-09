import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'event_log.dart';
import 'node_health.dart';

/// Replicación por sondeo (B1): pide a cada par los eventos que este nodo no tiene.
///
/// Es la versión simple de la anti-entropía del diseño: compara el vector de versiones del
/// par con el propio y trae por páginas lo que falta. Un par caído, lento o con respuestas
/// inválidas se omite sin lanzar.
class PollingReplicator {
  PollingReplicator({
    required EventLog log,
    required List<Uri> peers,
    required http.Client client,
    this.timeout = const Duration(seconds: 3),
    this.pageSize = 500,
    NodeHealth? health,
  })  : _log = log,
        _peers = peers,
        _client = client,
        _health = health;

  final EventLog _log;
  final List<Uri> _peers;
  final http.Client _client;
  final NodeHealth? _health;
  final Duration timeout;
  final int pageSize;

  /// Sondea a todos los pares una vez. Devuelve cuántos eventos nuevos se añadieron.
  Future<int> pullOnce() async {
    var added = 0;
    for (final peer in _peers) {
      try {
        added += await _pullFrom(peer);
      } on Exception catch (e) {
        // Par caído, lento o con una respuesta inválida: se reintenta en el siguiente sondeo.
        _health?.recordFailure(peer, e is TimeoutException ? 'tiempo agotado' : '$e');
        continue;
      }
    }
    return added;
  }

  Future<Map<String, Object?>> _getJson(Uri uri) async {
    final r = await _client.get(uri).timeout(timeout);
    if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}', uri);
    return {'body': jsonDecode(utf8.decode(r.bodyBytes))};
  }

  Future<int> _pullFrom(Uri peer) async {
    final health = (await _getJson(peer.resolve('/api/health')))['body']! as Map<String, Object?>;
    final remote = (health['versionVector']! as Map).cast<String, int>();
    int missing() {
      final local = _log.versionVector();
      var n = 0;
      for (final e in remote.entries) {
        if (e.key == _log.nodeId) continue;
        final d = e.value - (local[e.key] ?? 0);
        if (d > 0) n += d;
      }
      return n;
    }

    final missingBefore = missing();
    var added = 0;
    for (final entry in remote.entries) {
      final origin = entry.key;
      if (origin == _log.nodeId) continue; // lo propio nunca se trae de fuera
      var local = _log.versionVector()[origin] ?? 0;
      while (local < entry.value) {
        final uri = peer.resolve('/api/events?origin=$origin&after=$local&limit=$pageSize');
        final page = ((await _getJson(uri))['body']! as List).cast<Map<String, Object?>>();
        if (page.isEmpty) break;
        for (final j in page) {
          if (_log.appendReplicated(Event.fromJson(j))) added++;
        }
        final next = _log.versionVector()[origin] ?? 0;
        if (next <= local) break; // sin avance: evita un bucle si el par devuelve huecos
        local = next;
      }
    }
    _health?.recordContact(peer, missingBefore: missingBefore, missingAfter: missing());
    return added;
  }
}
