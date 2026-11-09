import 'dart:async';
import 'dart:collection';

import 'package:sard_agents/sard_agents.dart';

import 'b3_metrics.dart';
import 'synth.dart';

/// Precio por millón de tokens. Los de los modelos conocidos salen de la guía de la API (caché del 6 oct 2026): hay que
/// contrastarlos con la consola antes de fiarse de un tope de gasto.
class ModelPrice {
  const ModelPrice(this.inPerMTok, this.outPerMTok);
  final double inPerMTok;
  final double outPerMTok;

  double costOf(int inputTokens, int outputTokens) => inputTokens * inPerMTok / 1e6 + outputTokens * outPerMTok / 1e6;
}

const Map<String, ModelPrice> _knownPrices = {
  'claude-sonnet-5-5': ModelPrice(2, 10),
  'claude-opus-5-5': ModelPrice(4, 20),
  'claude-haiku-5-5': ModelPrice(0.10, 0.50),
};

/// El precio de [model]. Un modelo sin precio conocido **no se mide** salvo que se den los dos precios: sin ellos el tope
/// de gasto no valdría nada.
ModelPrice priceOf(String model, {double? inPerMTok, double? outPerMTok}) {
  if (inPerMTok != null && outPerMTok != null) return ModelPrice(inPerMTok, outPerMTok);
  final p = _knownPrices[model];
  if (p == null) throw ArgumentError('no se conoce el precio de «$model»: da --price-in y --price-out (USD por millón de tokens)');
  return p;
}

class T06ModelConfig {
  const T06ModelConfig({
    required this.seeds,
    required this.perSeed,
    required this.model,
    required this.effort,
    required this.concurrency,
    required this.budgetUsd,
    this.timeout = const Duration(seconds: 90),
    this.inPerMTok,
    this.outPerMTok,
  });

  /// Semillas del generador sintético; deben ser **nuevas** (ver `docs/resultados/b3.md`).
  final List<int> seeds;

  /// Cuántos reportes CON texto se consultan por semilla (repartidos por todo el conjunto).
  final int perSeed;
  final String model;
  final String? effort;
  final int concurrency;

  /// Tope duro en dólares: no se lanza una llamada que lo pueda pasar.
  final double budgetUsd;

  /// Plazo por llamada en la medición (largo, para no mezclar «el modelo tarda» con «el modelo falla»; cuántas pasan del
  /// plazo del nodo se cuenta aparte).
  final Duration timeout;
  final double? inPerMTok;
  final double? outPerMTok;
}

class Sampled {
  const Sampled(this.seed, this.report);
  final int seed;
  final SynthReport report;
}

/// La muestra: de cada semilla, [T06ModelConfig.perSeed] reportes con texto, tomados a intervalos regulares de TODO el
/// conjunto (no los primeros) para que entren todos los subgrupos. Determinista.
List<Sampled> sampleReports(T06ModelConfig cfg) {
  final out = <Sampled>[];
  for (final seed in cfg.seeds) {
    final ds = generateDataset(SynthConfig(seed: seed));
    final withText = [for (final r in ds.reports) if ((r.text ?? '').trim().isNotEmpty) r];
    if (withText.length <= cfg.perSeed) {
      out.addAll([for (final r in withText) Sampled(seed, r)]);
      continue;
    }
    final step = withText.length / cfg.perSeed;
    for (var i = 0; i < cfg.perSeed; i++) {
      out.add(Sampled(seed, withText[(i * step).floor()]));
    }
  }
  return out;
}

class ModelRecord {
  ModelRecord({
    required this.seed,
    required this.report,
    required this.rules,
    required this.rulesEscalate,
    required this.combined,
    required this.combinedEscalate,
    required this.mode,
    required this.reason,
    required this.latencyMs,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
    required this.requestId,
  });

  final int seed;
  final SynthReport report;
  final Urgency rules;
  final bool rulesEscalate;
  final Urgency combined;
  final bool combinedEscalate;

  /// `rules+llm` si el modelo respondió algo utilizable; `rules` si se cayó al respaldo (y [reason] dice por qué).
  final String mode;
  final String? reason;
  final int latencyMs;
  final int? inputTokens;
  final int? outputTokens;
  final double costUsd;
  final String? requestId;

  String get reportKey => report.reportKey;
  Urgency get truth => report.trueUrgency;
}

class T06ModelResult {
  T06ModelResult(this.records, this.spentUsd, this.skipped, this.stoppedByBudget, this.fallbacks, this.elapsed);
  final List<ModelRecord> records;
  final double spentUsd;

  /// Reportes de la muestra que NO se consultaron (por el tope de gasto).
  final int skipped;
  final bool stoppedByBudget;
  final Map<String, int> fallbacks;
  final Duration elapsed;
}

/// Un puerto que anota lo que contestó cada llamada (tokens, id), sin cambiar nada. Lo comparten las mediciones con modelo.
class MeteredPort implements LlmPort {
  MeteredPort(this._inner, this.onResult);
  final LlmPort _inner;
  final void Function(LlmResult) onResult;

  @override
  Future<LlmResult> completeJson(LlmRequest request) async {
    final r = await _inner.completeJson(request);
    onResult(r);
    return r;
  }
}

/// Mide el triaje por reglas frente al triaje con modelo, **sobre los mismos reportes** (comparación pareada), llevando
/// el gasto: antes de cada llamada se comprueba que el gasto más lo reservado por las que están en vuelo, más lo que
/// cuesta una llamada de promedio, no pase del tope.
Future<T06ModelResult> runT06Model(T06ModelConfig cfg, LlmPort port) async {
  final price = priceOf(cfg.model, inPerMTok: cfg.inPerMTok, outPerMTok: cfg.outPerMTok);
  final queue = Queue<Sampled>()..addAll(sampleReports(cfg));
  final records = <ModelRecord>[];
  final fallbacks = <String, int>{};
  final sw = Stopwatch()..start();
  var spent = 0.0, reserved = 0.0, made = 0;
  var stopped = false;

  // Antes de saber lo que cuesta una llamada se supone una de 1 000 tokens de entrada y 1 000 de salida.
  double estimate() => made == 0 ? price.costOf(1000, 1000) : spent / made;

  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final est = estimate();
      if (spent + est > cfg.budgetUsd) {
        stopped = true;
        return;
      }
      if (spent + reserved + est > cfg.budgetUsd) {
        await Future<void>.delayed(const Duration(milliseconds: 10)); // esperar a que las de en vuelo digan lo que costaron
        continue;
      }
      final s = queue.removeFirst();
      reserved += est;
      try {
        final rec = await _one(s, cfg, port, price, fallbacks);
        records.add(rec);
        spent += rec.costUsd;
        made++;
      } finally {
        reserved -= est;
      }
    }
  }

  await Future.wait([for (var i = 0; i < cfg.concurrency; i++) worker()]);
  return T06ModelResult(records, spent, queue.length, stopped, fallbacks, sw.elapsed);
}

Future<ModelRecord> _one(Sampled s, T06ModelConfig cfg, LlmPort port, ModelPrice price, Map<String, int> fallbacks) async {
  final r = s.report;
  final hasLoc = r.lat != null && r.locQuality.hasCoordinates;
  final rules = triage(r.flags, text: r.text, hasLocation: hasLoc);
  LlmResult? last;
  String? reason;
  final sw = Stopwatch()..start();
  final res = await triageWithModel(
    MeteredPort(port, (x) => last = x),
    r.flags,
    r.text,
    hasLocation: hasLoc,
    timeout: cfg.timeout,
    onFallback: (why) => reason = why,
  );
  sw.stop();
  if (reason != null) fallbacks[reason!] = (fallbacks[reason!] ?? 0) + 1;
  final cost = price.costOf(last?.inputTokens ?? 0, last?.outputTokens ?? 0);
  return ModelRecord(
    seed: s.seed,
    report: r,
    rules: rules.urgency,
    rulesEscalate: rules.escalateToHuman,
    combined: res.urgency,
    combinedEscalate: res.escalateToHuman,
    mode: res.mode,
    reason: reason,
    latencyMs: sw.elapsedMilliseconds,
    inputTokens: last?.inputTokens,
    outputTokens: last?.outputTokens,
    costUsd: cost,
    requestId: last?.requestId,
  );
}

String _pct(double x, {int d = 1}) => '${(100 * x).toStringAsFixed(d)} %';

List<TriageSample> _samples(List<ModelRecord> rs, {required bool withModel}) => [
  for (final x in rs)
    TriageSample(
      truth: x.truth,
      predicted: withModel ? x.combined : x.rules,
      escalate: withModel ? x.combinedEscalate : x.rulesEscalate,
      subgroup: (x.truth == Urgency.p1 && x.report.subgroup == 'no_p1') ? 'gemelo_p1' : x.report.subgroup,
      incident: x.report.trueIncident + 100000 * x.seed,
      tags: x.report.tags,
    ),
];

int _percentile(List<int> sorted, double p) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

/// El informe en Markdown. **Nunca** incluye la clave ni el texto de los reportes.
String renderT06Model(T06ModelConfig cfg, T06ModelResult res) {
  final rs = res.records;
  final rules = evalTriage(_samples(rs, withModel: false));
  final model = evalTriage(_samples(rs, withModel: true));
  final b = StringBuffer();
  final used = rs.where((x) => x.mode == 'rules+llm').length;
  final lat = [for (final x in rs) if (x.mode == 'rules+llm') x.latencyMs]..sort();
  final over8 = lat.where((l) => l > 8000).length;
  final raised = rs.where((x) => x.combined.index < x.rules.index).length;
  final falseP1Rules = rs.where((x) => x.rules == Urgency.p1 && x.truth != Urgency.p1).length;
  final falseP1Model = rs.where((x) => x.combined == Urgency.p1 && x.truth != Urgency.p1).length;
  final inTok = rs.fold<int>(0, (a, x) => a + (x.inputTokens ?? 0));
  final outTok = rs.fold<int>(0, (a, x) => a + (x.outputTokens ?? 0));

  b
    ..writeln('# T06 con el modelo de lenguaje REAL · `${cfg.model}`${cfg.effort == null ? '' : ' (effort `${cfg.effort}`)'}')
    ..writeln()
    ..writeln('Mismo triaje, **mismos ${rs.length} reportes**, dos formas: sólo reglas y reglas + modelo (`triageWithModel`: el modelo nunca baja lo que dicen las reglas; sube sólo con una señal nueva de cita verificada). Semillas ${cfg.seeds.join(', ')} del generador sintético (${cfg.perSeed} reportes con texto por semilla, repartidos por todo el conjunto).')
    ..writeln()
    ..writeln('## Resumen')
    ..writeln()
    ..writeln('| | Sólo reglas | Reglas + modelo |')
    ..writeln('|---|---|---|')
    ..writeln('| **recall de P1** | ${_pct(rules.global.recall)} | **${_pct(model.global.recall)}** |')
    ..writeln('| recall de P1 contando «revisión humana» como acierto | ${_pct(rules.global.recallWithEscalation)} | ${_pct(model.global.recallWithEscalation)} |')
    ..writeln('| precisión de P1 | ${_pct(rules.global.precision)} | ${_pct(model.global.precision)} |')
    ..writeln('| reportes no P1 clasificados P1 (sobre-triaje) | $falseP1Rules | $falseP1Model |')
    ..writeln('| exactitud global | ${_pct(rules.accuracy)} | ${_pct(model.accuracy)} |')
    ..writeln()
    ..writeln('El modelo cambió la urgencia de **$raised** de ${rs.length} reportes (siempre a más urgente: el piso por reglas impide bajarla). Respondió algo utilizable en **$used** de ${rs.length}.')
    ..writeln()
    ..writeln('## Por subgrupo (reportes cuya verdad es P1)')
    ..writeln()
    ..writeln('| Subgrupo | Reportes P1 | Recall reglas | Recall reglas + modelo |')
    ..writeln('|---|---|---|---|');
  for (final k in (rules.bySubgroup.keys.toList()..sort())) {
    final r = rules.bySubgroup[k]!, m = model.bySubgroup[k]!;
    if (r.truth > 0) b.writeln('| $k | ${r.truth} | ${_pct(r.recall)} | ${_pct(m.recall)} |');
  }
  b
    ..writeln()
    ..writeln('## Por etiqueta (reportes cuya verdad es P1)')
    ..writeln()
    ..writeln('| Etiqueta | Reportes P1 | Recall reglas | Recall reglas + modelo |')
    ..writeln('|---|---|---|---|');
  for (final k in (rules.byTag.keys.toList()..sort())) {
    final r = rules.byTag[k]!, m = model.byTag[k]!;
    if (r.truth > 0) b.writeln('| $k | ${r.truth} | ${_pct(r.recall)} | ${_pct(m.recall)} |');
  }
  b
    ..writeln()
    ..writeln('## Fallos del modelo (se cae al respaldo de reglas), por causa')
    ..writeln();
  if (res.fallbacks.isEmpty) {
    b.writeln('Ninguno.');
  } else {
    b
      ..writeln('| Causa | Reportes |')
      ..writeln('|---|---|');
    for (final e in (res.fallbacks.entries.toList()..sort((a, c) => c.value.compareTo(a.value)))) {
      b.writeln('| `${e.key}` | ${e.value} |');
    }
  }
  b
    ..writeln()
    ..writeln('## Latencia y plazo del nodo')
    ..writeln()
    ..writeln('Llamadas con respuesta utilizable: p50 **${_percentile(lat, 0.5)} ms**, p95 **${_percentile(lat, 0.95)} ms**, máximo ${lat.isEmpty ? 0 : lat.last} ms. **$over8 de ${lat.length} pasaron de 8 s**, que es el plazo con el que el nodo consulta al modelo: lo que pase de ahí cae al respaldo de reglas y no se ve en la cola. Plazo de esta medición: ${cfg.timeout.inSeconds} s.')
    ..writeln()
    ..writeln('## Gasto')
    ..writeln()
    ..writeln('| | |')
    ..writeln('|---|---|')
    ..writeln('| Llamadas hechas | ${rs.length} (sin hacer por el tope: ${res.skipped}${res.stoppedByBudget ? ', **cortada por presupuesto**' : ''}) |')
    ..writeln('| Tokens de entrada / salida | $inTok / $outTok (la salida incluye el razonamiento) |')
    ..writeln('| Gasto | **\$${res.spentUsd.toStringAsFixed(4)}** de un tope de \$${cfg.budgetUsd.toStringAsFixed(2)} |')
    ..writeln('| Por reporte | \$${rs.isEmpty ? '0' : (res.spentUsd / rs.length).toStringAsFixed(5)} |')
    ..writeln('| Duración | ${res.elapsed.inSeconds} s con concurrencia ${cfg.concurrency} |')
    ..writeln()
    ..writeln('## Lo que esta medición NO dice')
    ..writeln()
    ..writeln('- Los datos son **sintéticos** y los generó la misma persona que escribió las reglas: no mide el mundo real.')
    ..writeln('- Es una **muestra** (${rs.length} reportes con texto), no el conjunto entero, y **una sola corrida**: estos modelos no permiten fijar el muestreo, así que otra corrida puede dar otras cifras.')
    ..writeln('- Sólo se consultan los reportes **con texto**; los que no lo traen se quedan con reglas, así que el recall de todo el sistema es distinto del de esta muestra.')
    ..writeln('- El mensaje al modelo es el del proyecto, **sin afinar**. Los precios son los de la guía de la API del 6 oct 2026 y hay que contrastarlos con la consola.')
    ..writeln('- El comportamiento ante un reporte con instrucciones maliciosas se prueba aparte (T13, con un servidor falso); aquí no.')
    ..writeln()
    ..writeln('Reproducir (la clave sólo por entorno; ver `packages/sim/bin/t06_model.dart`): `ANTHROPIC_API_KEY=… dart run packages/sim/bin/t06_model.dart --seeds ${cfg.seeds.join(',')} --per-seed ${cfg.perSeed} --model ${cfg.model}${cfg.effort == null ? '' : ' --effort ${cfg.effort}'} --budget-usd ${cfg.budgetUsd}`.');
  return b.toString();
}

/// Datos crudos, una fila por reporte, **sin el texto** del reporte.
String renderT06ModelCsv(T06ModelResult res) {
  final b = StringBuffer('seed,reportKey,subgroup,truth,rules,combined,mode,reason,latency_ms,input_tokens,output_tokens,cost_usd,request_id\n');
  for (final x in res.records) {
    b.writeln([
      x.seed,
      x.reportKey,
      x.report.subgroup,
      x.truth.name,
      x.rules.name,
      x.combined.name,
      x.mode,
      x.reason ?? '',
      x.latencyMs,
      x.inputTokens ?? '',
      x.outputTokens ?? '',
      x.costUsd.toStringAsFixed(6),
      x.requestId ?? '',
    ].join(','));
  }
  return b.toString();
}
