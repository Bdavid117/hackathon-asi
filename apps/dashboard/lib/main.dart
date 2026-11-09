import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'queue_screen.dart';

/// URL del nodo. Vacía = el mismo origen que sirve el tablero (modo normal, servido por el
/// nodo con `--web-root`). En desarrollo: `--dart-define=NODE=http://localhost:8081`.
const String _node = String.fromEnvironment('NODE');

Future<QueueSnapshot> _fetchQueue() async {
  final base = _node.isEmpty ? Uri.base : Uri.parse(_node);
  final r = await http.get(base.resolve('/api/queue')).timeout(const Duration(seconds: 3));
  if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}');
  // El nodo avisa si sirve una versión anterior de la cola (cabeceras x-queue-stale / x-queue-age-ms).
  return QueueSnapshot(
    (jsonDecode(utf8.decode(r.bodyBytes)) as List).cast<Map<String, Object?>>(),
    stale: r.headers['x-queue-stale'] == 'true',
    ageMs: int.tryParse(r.headers['x-queue-age-ms'] ?? '') ?? 0,
  );
}

void main() => runApp(
      MaterialApp(
        title: 'SARD · Tablero',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF1F3A68)),
        home: QueueScreen(fetch: _fetchQueue),
      ),
    );
