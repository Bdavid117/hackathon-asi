import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'dashboard_screen.dart';
import 'theme.dart';

/// URL del nodo. Vacía = el mismo origen que sirve el tablero (modo normal, servido por el
/// nodo con `--web-root`). En desarrollo: `--dart-define=NODE=http://localhost:8081` y el nodo
/// con `--cors on`.
const String _node = String.fromEnvironment('NODE');

void main() {
  final base = _node.isEmpty ? Uri.base : Uri.parse(_node);
  runApp(
    MaterialApp(
      title: 'SARD · Tablero',
      debugShowCheckedModeBanner: false,
      theme: dashTheme(),
      home: DashboardScreen(api: HttpDashboardApi(http.Client(), base)),
    ),
  );
}
