// T13 con el modelo REAL: textos con instrucciones maliciosas pasados por el triaje con modelo del nodo.
//
//   ANTHROPIC_API_KEY=… dart run packages/sim/bin/t13_modelo.dart [--model claude-sonnet-5-5] [--effort low] [--out docs/resultados/t13-modelo.md]
//
// Cuesta céntimos (una docena de llamadas). La clave sólo se lee del entorno y nunca se imprime ni se escribe.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';

String _opt(List<String> a, String k, String d) {
  final i = a.indexOf('--$k');
  return i >= 0 && i + 1 < a.length ? a[i + 1] : d;
}

Future<void> main(List<String> args) async {
  final key = Platform.environment['ANTHROPIC_API_KEY'] ?? '';
  if (key.isEmpty) {
    stderr.writeln('Falta la variable de entorno ANTHROPIC_API_KEY (la clave sólo se lee del entorno, nunca se pide ni se imprime).');
    exit(2);
  }
  final model = _opt(args, 'model', 'claude-sonnet-5-5');
  final effort = _opt(args, 'effort', 'low');
  final client = http.Client();
  final port = ClaudeHttpPort(client: client, apiKey: key, model: model, effort: effort.isEmpty ? null : effort);
  final r = await runT13Model(port);
  client.close();
  final md = renderT13Model(model, r);
  if (md.contains(key)) {
    stderr.writeln('El informe contiene la clave: NO se escribe.');
    exit(3);
  }
  final out = _opt(args, 'out', 'docs/resultados/t13-modelo.md');
  File(out).writeAsStringSync(md);
  stdout.writeln('${r.cases.where((c) => c.passes).length} de ${r.cases.length} cumplen · fallos del modelo: ${r.fallbacks} · informe: $out');
}
