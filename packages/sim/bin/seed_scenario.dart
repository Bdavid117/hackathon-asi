// Puebla un nodo en marcha con el escenario fijo del tablero (8 incidentes):
//   dart run packages/sim/bin/seed_scenario.dart [--node http://localhost:8081] [--now] [--extended [--code CÓDIGO] [--who NOMBRE]]
// Con --now los reportes llevan la hora actual (para ver «hace 3 min» en el tablero); sin ella, las horas fijas
// de siempre (los fixtures de pruebas). Con --extended se añade una contradicción entre dos reportes, una vía bloqueada
// en la ruta del P1 y la ambulancia 2 declarada no disponible (con --code si el nodo exige código de coordinador).
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

Future<void> main(List<String> args) async {
  final i = args.indexOf('--node');
  final node = Uri.parse(i >= 0 && i + 1 < args.length ? args[i + 1] : 'http://localhost:8081');
  final client = http.Client();
  try {
    final now = args.contains('--now');
    final t0 = now ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600 : 1786370851;
    await postScenario(node, client, t0: t0);
    if (args.contains('--extended')) {
      String? option(String name) {
        final k = args.indexOf(name);
        return k >= 0 && k + 1 < args.length ? args[k + 1] : null;
      }

      await postExtendedScenario(node, client, t0: t0, code: option('--code'), who: option('--who') ?? 'Ana Gómez');
    }
    stdout.writeln('Escenario enviado a $node${args.contains('--extended') ? ' (con contradicción, vía bloqueada y ambulancia 2 no disponible)' : ''}');
  } finally {
    client.close();
  }
}
