// T06 con el modelo REAL: el mismo triaje con reglas y con reglas + modelo, sobre los MISMOS reportes de semillas nuevas.
//
//   # 1) plan: cuántos reportes y cuánto gastaría (no llama a la API)
//   dart run packages/sim/bin/t06_model.dart --plan --seeds 601,602,603,604,605 --per-seed 150
//   # 2) medición (la clave sólo por entorno; el tope de gasto se comprueba antes de cada llamada, pero no es estrictamente duro)
//   ANTHROPIC_API_KEY=… dart run packages/sim/bin/t06_model.dart --seeds 601,602,603,604,605 --per-seed 150 --budget-usd 10
//
// Opciones: --model (claude-sonnet-5-5) · --effort (low; vacío = el de la API) · --concurrency (4) · --timeout (segundos, 90) ·
//           --out (docs/resultados/t06-modelo.md; el CSV de datos crudos queda al lado) · --price-in / --price-out (USD por
//           millón de tokens, sólo para un modelo sin precio conocido) · --base-url (sólo pruebas: un servidor falso).
//
// Reglas: semillas NUEVAS (601–605 no se han visto), código congelado, comparación pareada, fallos contados por causa,
// la clave NUNCA se imprime ni se escribe, y si el informe contuviera la clave no se escribe.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';

String _opt(List<String> a, String k, String d) {
  final i = a.indexOf('--$k');
  return i >= 0 && i + 1 < a.length ? a[i + 1] : d;
}

Future<void> main(List<String> args) async {
  final plan = args.contains('--plan');
  final base = _opt(args, 'base-url', '');
  final key = Platform.environment['ANTHROPIC_API_KEY'] ?? '';
  final model = _opt(args, 'model', 'claude-sonnet-5-5');
  final effort = _opt(args, 'effort', 'low');
  final cfg = T06ModelConfig(
    seeds: [for (final s in _opt(args, 'seeds', '601,602,603,604,605').split(',')) int.parse(s.trim())],
    perSeed: int.parse(_opt(args, 'per-seed', '150')),
    model: model,
    effort: effort.isEmpty ? null : effort,
    concurrency: int.parse(_opt(args, 'concurrency', '4')),
    budgetUsd: double.parse(_opt(args, 'budget-usd', '10')),
    timeout: Duration(seconds: int.parse(_opt(args, 'timeout', '90'))),
    inPerMTok: args.contains('--price-in') ? double.parse(_opt(args, 'price-in', '0')) : null,
    outPerMTok: args.contains('--price-out') ? double.parse(_opt(args, 'price-out', '0')) : null,
  );
  final price = priceOf(cfg.model, inPerMTok: cfg.inPerMTok, outPerMTok: cfg.outPerMTok);
  final sample = sampleReports(cfg);

  if (plan) {
    // Entre un reporte «corto» (≈ 700 de entrada y 400 de salida) y uno «largo» (≈ 900 y 2 500, con mucho razonamiento).
    final lo = sample.length * price.costOf(700, 400), hi = sample.length * price.costOf(900, 2500);
    stdout.writeln('Plan: ${sample.length} reportes con texto de las semillas ${cfg.seeds.join(', ')} · ${cfg.model} · effort ${cfg.effort ?? '(el de la API)'}');
    stdout.writeln('Coste estimado: \$${lo.toStringAsFixed(2)} – \$${hi.toStringAsFixed(2)} (precio ${price.inPerMTok}/${price.outPerMTok} USD por millón de tokens, entrada/salida). Tope duro: \$${cfg.budgetUsd.toStringAsFixed(2)}.');
    stdout.writeln('No se ha llamado a la API.');
    return;
  }
  if (key.isEmpty && base.isEmpty) {
    stderr.writeln('Falta la variable de entorno ANTHROPIC_API_KEY (la clave sólo se lee del entorno, nunca se pide ni se imprime).');
    exit(2);
  }

  final client = http.Client();
  final port = ClaudeHttpPort(
    client: client,
    apiKey: key.isEmpty ? 'sin-clave' : key,
    baseUrl: base.isEmpty ? null : Uri.parse(base),
    model: cfg.model,
    effort: cfg.effort,
  );
  stderr.writeln('midiendo ${sample.length} reportes con ${cfg.model} (tope \$${cfg.budgetUsd.toStringAsFixed(2)})…');
  final res = await runT06Model(cfg, port);
  client.close();

  final out = _opt(args, 'out', 'docs/resultados/t06-modelo.md');
  final md = renderT06Model(cfg, res);
  final csv = renderT06ModelCsv(res);
  if (key.isNotEmpty && (md.contains(key) || csv.contains(key))) {
    stderr.writeln('El informe contiene la clave: NO se escribe.');
    exit(3);
  }
  File(out).writeAsStringSync(md);
  File('${out.replaceFirst(RegExp(r'\.md$'), '')}-datos.csv').writeAsStringSync(csv);
  stdout.writeln('Hecho: ${res.records.length} llamadas, gasto \$${res.spentUsd.toStringAsFixed(4)}${res.stoppedByBudget ? ' (CORTADA por el tope)' : ''}. Informe: $out');
  if (res.fallbacks.isNotEmpty) stdout.writeln('Fallos por causa: ${res.fallbacks}');
}
