// T07 y T08 con el juez semántico REAL (Reto 4): agrupar reportes que cuentan lo mismo con otras palabras.
//
//   # 1) plan: cuántas consultas y cuánto gastaría (no llama a la API)
//   dart run packages/sim/bin/t07_modelo.dart --plan --seeds 701,702,703,704,705
//   # 2) medición (la clave sólo por entorno; el tope de gasto es DURO)
//   ANTHROPIC_API_KEY=… dart run packages/sim/bin/t07_modelo.dart --seeds 701,702,703,704,705 --budget-usd 8
//
// Opciones: --model (claude-sonnet-5-5) · --effort (low; vacío = el de la API) · --concurrency (4) · --timeout (segundos, 90) ·
//           --incidents (24) · --reports (300) · --adversarial (6) · --k (candidatos por reporte, 6) · --min-confidence (0.8) ·
//           --criterion (1: el de la ronda 1; 2: el de la ronda 2, reescrito tras ver la ronda 1) ·
//           --ledger (docs/resultados/gasto-api.json: el registro de gasto; se niega a lanzar si lo gastado + el tope de la corrida pasa de
//           50 − 10 USD; sólo con la API real, no con --base-url) ·
//           --out (docs/resultados/t07-modelo.md; el CSV de datos crudos queda al lado) · --price-in / --price-out (USD por
//           millón de tokens, sólo para un modelo sin precio conocido) · --base-url (sólo pruebas: un servidor falso).
//
// Reglas: semillas NUEVAS, código y criterio de adopción congelados ANTES de correr (el informe anota el commit y si el árbol
// estaba limpio), comparación pareada, fallos contados por causa, la clave NUNCA se imprime ni se escribe, y si el informe
// contuviera la clave no se escribe. El tope de gasto se comprueba antes de cada llamada, pero no es estrictamente duro.
// Se debe lanzar desde la raíz del repositorio.
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
  final effort = _opt(args, 'effort', 'low');
  final cfg = T07ModelConfig(
    seeds: [for (final s in _opt(args, 'seeds', '701,702,703,704,705').split(',')) int.parse(s.trim())],
    incidents: int.parse(_opt(args, 'incidents', '24')),
    reports: int.parse(_opt(args, 'reports', '300')),
    adversarialPairs: int.parse(_opt(args, 'adversarial', '6')),
    k: int.parse(_opt(args, 'k', '$kJudgeCandidates')),
    minConfidence: double.parse(_opt(args, 'min-confidence', '$kJudgeMinConfidence')),
    model: _opt(args, 'model', 'claude-sonnet-5-5'),
    effort: effort.isEmpty ? null : effort,
    concurrency: int.parse(_opt(args, 'concurrency', '4')),
    budgetUsd: double.parse(_opt(args, 'budget-usd', '8')),
    criterion: int.parse(_opt(args, 'criterion', '1')),
    timeout: Duration(seconds: int.parse(_opt(args, 'timeout', '90'))),
    inPerMTok: args.contains('--price-in') ? double.parse(_opt(args, 'price-in', '0')) : null,
    outPerMTok: args.contains('--price-out') ? double.parse(_opt(args, 'price-out', '0')) : null,
  );
  final price = priceOf(cfg.model, inPerMTok: cfg.inPerMTok, outPerMTok: cfg.outPerMTok);
  final datasets = t07Datasets(cfg);
  final jobs = planJudgeJobs(datasets, k: cfg.k);

  if (plan) {
    final cands = jobs.fold<int>(0, (a, j) => a + j.candidates.length);
    // Entre una consulta «corta» (≈ 700 de entrada y 400 de salida) y una «larga» (≈ 1 000 y 1 800, con razonamiento).
    final lo = jobs.length * price.costOf(700, 400), hi = jobs.length * price.costOf(1000, 1800);
    stdout.writeln('Plan: ${datasets.length} conjuntos de las semillas ${cfg.seeds.join(', ')} · ${jobs.length} consultas '
        '(${(cands / (jobs.isEmpty ? 1 : jobs.length)).toStringAsFixed(1)} candidatos de media) · ${cfg.model} · effort ${cfg.effort ?? '(el de la API)'}');
    stdout.writeln('Coste estimado: \$${lo.toStringAsFixed(2)} – \$${hi.toStringAsFixed(2)} (precio ${price.inPerMTok}/${price.outPerMTok} USD por millón de tokens, entrada/salida). Tope duro: \$${cfg.budgetUsd.toStringAsFixed(2)}.');
    stdout.writeln('No se ha llamado a la API.');
    return;
  }
  if (key.isEmpty && base.isEmpty) {
    stderr.writeln('Falta la variable de entorno ANTHROPIC_API_KEY (la clave sólo se lee del entorno, nunca se pide ni se imprime).');
    exit(2);
  }

  // La versión del código que se mide: el commit y si había cambios sin confirmar en el código.
  String codeVersion() {
    try {
      final head = Process.runSync('git', ['rev-parse', '--short', 'HEAD']);
      final dirty = Process.runSync('git', ['status', '--porcelain', '--', 'packages', 'apps', 'config']);
      if (head.exitCode != 0 || dirty.exitCode != 0) return 'desconocido (git no respondió)';
      return '${(head.stdout as String).trim()} (${(dirty.stdout as String).trim().isEmpty ? 'árbol limpio' : 'CON cambios sin confirmar'})';
    } on Object {
      return 'desconocido (sin git)';
    }
  }

  final version = codeVersion();
  stderr.writeln('código: $version');
  final client = http.Client();
  final port = ClaudeHttpPort(
    client: client,
    apiKey: key.isEmpty ? 'sin-clave' : key,
    baseUrl: base.isEmpty ? null : Uri.parse(base),
    model: cfg.model,
    effort: cfg.effort,
  );
  stderr.writeln('juzgando ${jobs.length} consultas con ${cfg.model} (tope \$${cfg.budgetUsd.toStringAsFixed(2)})…');
  final ledgerPath = _opt(args, 'ledger', 'docs/resultados/gasto-api.json');
  final T07ModelResult res;
  if (base.isEmpty) {
    // La API REAL cuesta: la corrida va BAJO el registro de gasto (se niega a lanzar si pasa del límite; anota el gasto real al terminar
    // o el tope entero si falla).
    try {
      res = await ApiLedger.load(ledgerPath).spend<T07ModelResult>(
        run: 'T07 semillas ${cfg.seeds.join(',')}',
        capUsd: cfg.budgetUsd,
        body: () => runT07Model(cfg, port, datasets: datasets),
        costOf: (r) => r.spentUsd,
        noteOf: (r) => '${r.records.length} llamadas, ${cfg.model}, confianza mínima ${cfg.minConfidence}',
      );
    } on StateError catch (e) {
      stderr.writeln(e.message);
      client.close();
      exit(4);
    }
  } else {
    res = await runT07Model(cfg, port, datasets: datasets); // un servidor falso: no hay gasto real que registrar
  }
  client.close();

  final out = _opt(args, 'out', 'docs/resultados/t07-modelo.md');
  final md = renderT07Model(cfg, res, datasets, codeVersion: version);
  final csv = renderT07ModelCsv(datasets, res.records);
  if (key.isNotEmpty && (md.contains(key) || csv.contains(key))) {
    stderr.writeln('El informe contiene la clave: NO se escribe.');
    exit(3);
  }
  File(out).writeAsStringSync(md);
  File('${out.replaceFirst(RegExp(r'\.md$'), '')}-datos.csv').writeAsStringSync(csv);
  stdout.writeln('Hecho: ${res.records.length} llamadas, gasto \$${res.spentUsd.toStringAsFixed(4)}${res.stoppedByBudget ? ' (CORTADA por el tope)' : ''}. Informe: $out');
  if (res.fallbacks.isNotEmpty) stdout.writeln('Fallos por causa: ${res.fallbacks}');
}
