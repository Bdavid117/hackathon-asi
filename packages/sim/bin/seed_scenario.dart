// Puebla un nodo en marcha con el escenario fijo del tablero (8 incidentes):
//   dart run packages/sim/bin/seed_scenario.dart [--node http://localhost:8081]
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

Future<void> main(List<String> args) async {
  final i = args.indexOf('--node');
  final node = Uri.parse(i >= 0 && i + 1 < args.length ? args[i + 1] : 'http://localhost:8081');
  final client = http.Client();
  try {
    await postScenario(node, client);
    stdout.writeln('Escenario enviado a $node');
  } finally {
    client.close();
  }
}
