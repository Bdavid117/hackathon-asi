// Puebla un nodo en marcha con el escenario fijo del tablero (8 incidentes):
//   dart run packages/sim/bin/seed_scenario.dart [--node http://localhost:8081] [--now]
// Con --now los reportes llevan la hora actual (para ver «hace 3 min» en el tablero); sin ella, las horas fijas
// de siempre (los fixtures de pruebas).
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

Future<void> main(List<String> args) async {
  final i = args.indexOf('--node');
  final node = Uri.parse(i >= 0 && i + 1 < args.length ? args[i + 1] : 'http://localhost:8081');
  final client = http.Client();
  try {
    final now = args.contains('--now');
    await postScenario(node, client, t0: now ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600 : 1786370851);
    stdout.writeln('Escenario enviado a $node');
  } finally {
    client.close();
  }
}
