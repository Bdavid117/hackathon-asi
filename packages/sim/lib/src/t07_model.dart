import 'dart:async';
import 'dart:collection';

import 'package:sard_agents/sard_agents.dart';

import 'b3_metrics.dart';
import 'synth.dart';
import 't06_model.dart';

/// T07 y T08 con el **juez semántico real** (Reto 4): ¿agrupar con un modelo reportes que cuentan lo mismo con otras
/// palabras mejora el agrupamiento por reglas, sin falsas fusiones?
///
/// Método: cada reporte con texto se compara, en orden de llegada, con hasta [T07ModelConfig.k] reportes ANTERIORES que
/// pasan las reglas duras (el modelo no ve los que no podrían unirse). Se miden tres variantes sobre los MISMOS reportes:
/// sólo reglas, reglas + modelo con veto y reglas + modelo sin veto. Los juicios se aplican con [applyJudgments], la misma
/// función pura que usaría el nodo.

/// El criterio de adopción, **fijado antes de ver los datos de la corrida** (queda en el historial de git antes de la
/// corrida con la API). El informe lo repite y lo APLICA mecánicamente ([decideT07]) junto a los resultados.
///
/// Revisiones, todas antes de correr las semillas 701–705 (el piloto de la semilla 700 NO entra en el resultado):
///  · 1.ª (`6ed2fe5`): (3) pedía sólo «el doble de recall».
///  · 2.ª (`445318d`): el piloto mostró que el recall de las reglas es ≈ 0,3 %, así que «el doble» no tiene valor práctico;
///    se separó en dos niveles y (3) pasó a exigir una ganancia absoluta.
///  · 3.ª (esta): el piloto no había llegado a juzgar ningún escenario de T08 (la cola iba en orden y el tope cortó antes), y T08 es
///    lo que promete el Reto 4: se añadieron (5) y (6). El nivel de seguridad no exige ningún beneficio —lo cumpliría un modelo
///    inofensivo e inútil—, por eso sin (3), (5) y (6) el informe dice «sin ganancia demostrada». El mensaje al modelo no se tocó.
const String kT07DecisionRule =
    'Tercera revisión, antes de correr las semillas 701–705 (el piloto de la semilla 700 no entra en el resultado). '
    '**Para ofrecer la unión por modelo en el nodo como opción apagada por omisión** hace falta, con semillas nuevas y a la vez: '
    '(1) la falsa fusión de pares con el modelo es ≤ 1 % y no supera en más de 0,5 puntos a la de sólo reglas; '
    '(2) la precisión de las uniones que hace el modelo es ≥ 95 % (sin uniones no hay nada demostrado); '
    '(4) los fallos del modelo (plazo, HTTP, salida inválida) son ≤ 5 % de las llamadas y las llamadas de más de 8 s ≤ 5 % de las útiles. '
    '**Para recomendar activarla** además: '
    '(3) el recall de pares con el modelo sube al menos 5 puntos porcentuales y al menos el doble que el de sólo reglas; '
    '(5) en al menos el 80 % de las corroboraciones (5 fuentes con palabras propias) el modelo forma UN grupo con las 5 fuentes y '
    'más confianza que las reglas; '
    '(6) el rumor repetido no gana fuentes independientes por encima de las que tiene ni pasa de 0,8 de confianza. '
    'Sin (3), (5) y (6) el resultado es «opción disponible, sin ganancia demostrada». '
    'El veto (que el modelo corte una unión de las reglas) se adopta sólo si hay vetos y ≤ 10 % de ellos son dañinos (cortan pares '
    'del mismo suceso); si no, el nodo sólo une, no veta. Los veredictos `possible` no cambian nada (su confianza queda bajo el '
    'umbral): se informa su precisión y nada más.';

/// Un conjunto de reportes con su verdad. [kind]: `synth` (cuenta para las métricas de pares), `corroboracion` o `rumor`
/// (escenarios de T08, se informan aparte).
class T07Dataset {
  const T07Dataset(this.label, this.kind, this.reports);
  final String label;
  final String kind;
  final List<SynthReport> reports;
}

class T07ModelConfig {
  const T07ModelConfig({
    required this.seeds,
    required this.model,
    required this.effort,
    required this.concurrency,
    required this.budgetUsd,
    this.incidents = 24,
    this.reports = 300,
    this.adversarialPairs = 6,
    this.corroborationSources = 5,
    this.rumorCopies = 12,
    this.rumorSources = 3,
    this.k = kJudgeCandidates,
    this.minConfidence = kJudgeMinConfidence,
    this.timeout = const Duration(seconds: 90),
    this.inPerMTok,
    this.outPerMTok,
    this.criterion = 1,
  });

  /// Semillas del generador; deben ser **nuevas** (ver `docs/resultados/b3.md`).
  final List<int> seeds;
  final String model;
  final String? effort;
  final int concurrency;

  /// Tope duro en dólares: no se lanza una llamada que lo pueda pasar.
  final double budgetUsd;

  /// Tamaño de cada conjunto sintético (más pequeño que el de T07 para acotar el coste; la proporción de sucesos por
  /// reporte es la misma).
  final int incidents;
  final int reports;
  final int adversarialPairs;
  final int corroborationSources;
  final int rumorCopies;
  final int rumorSources;

  /// Qué criterio de adopción aplica el informe: 1 (ronda 1, [kT07DecisionRule]) o 2 (ronda 2, [kT07DecisionRuleV2]).
  final int criterion;

  /// Candidatos por reporte y confianza mínima del modelo para que un juicio cuente.
  final int k;
  final double minConfidence;

  /// Plazo por llamada en la medición (largo, para no mezclar «tarda» con «falla»; cuántas pasan del plazo del nodo se
  /// cuenta aparte).
  final Duration timeout;
  final double? inPerMTok;
  final double? outPerMTok;
}

/// Los conjuntos de la corrida: por cada semilla, un conjunto sintético, una corroboración de 5 fuentes y un rumor.
List<T07Dataset> t07Datasets(T07ModelConfig cfg) => [
  for (final s in cfg.seeds) ...[
    T07Dataset(
      'semilla-$s',
      'synth',
      generateDataset(SynthConfig(seed: s, incidents: cfg.incidents, reports: cfg.reports, adversarialPairs: cfg.adversarialPairs)).reports,
    ),
    T07Dataset('corroboracion-$s', 'corroboracion', generateCorroboration(sources: cfg.corroborationSources, seed: s)),
    T07Dataset('rumor-$s', 'rumor', generateRumor(copies: cfg.rumorCopies, sources: cfg.rumorSources, seed: s)),
  ],
];

/// Una consulta al modelo: el reporte nuevo y sus candidatos (anteriores y que pasan las reglas duras).
class JudgeJob {
  const JudgeJob(this.dataset, this.target, this.candidates);
  final String dataset;
  final Observation target;
  final List<Observation> candidates;
}

List<Observation> _chronological(T07Dataset d) {
  final obs = [for (final r in d.reports) r.toObservation()];
  obs.sort((a, b) {
    final c = a.capturedAtMs.compareTo(b.capturedAtMs);
    return c != 0 ? c : a.reportKey.compareTo(b.reportKey);
  });
  return obs;
}

/// Las consultas que haría el nodo: un trabajo por reporte con texto que tenga candidatos, en orden de llegada y contra
/// los reportes que ya conocía; primero los de los escenarios de T08 y luego los de los conjuntos sintéticos. Determinista y
/// **no depende del orden de entrada**.
List<JudgeJob> planJudgeJobs(List<T07Dataset> datasets, {int k = kJudgeCandidates}) {
  final scenarios = <JudgeJob>[], synth = <JudgeJob>[];
  for (final d in datasets) {
    final obs = _chronological(d);
    final out = d.kind == 'synth' ? synth : scenarios;
    for (var i = 1; i < obs.length; i++) {
      final cands = pickJudgeCandidates(obs[i], obs.sublist(0, i), k: k);
      if (cands.isNotEmpty) out.add(JudgeJob(d.label, obs[i], cands));
    }
  }
  // Los escenarios de T08 primero: si un tope de gasto corta la cola, no puede ser a costa de lo que promete el Reto 4.
  return [...scenarios, ...synth];
}

class JudgeRecord {
  JudgeRecord({
    required this.dataset,
    required this.targetKey,
    required this.candidateKeys,
    required this.judgments,
    required this.reason,
    required this.latencyMs,
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
    required this.requestId,
  });

  final String dataset;
  final String targetKey;
  final List<String> candidateKeys;

  /// Vacía si el modelo falló ([reason] dice por qué).
  final List<LinkJudgment> judgments;
  final String? reason;
  final int latencyMs;
  final int? inputTokens;
  final int? outputTokens;
  final double costUsd;
  final String? requestId;
}

class T07ModelResult {
  T07ModelResult(this.records, this.spentUsd, this.skipped, this.stoppedByBudget, this.fallbacks, this.elapsed);
  final List<JudgeRecord> records;
  final double spentUsd;

  /// Consultas del plan que NO se hicieron (por el tope de gasto).
  final int skipped;
  final bool stoppedByBudget;
  final Map<String, int> fallbacks;
  final Duration elapsed;
}

/// Hace las consultas del plan llevando el gasto: antes de cada llamada se comprueba que el gasto más lo reservado por las
/// que están en vuelo, más lo que cuesta una llamada de promedio, no pase del tope.
Future<T07ModelResult> runT07Model(T07ModelConfig cfg, LlmPort port, {List<T07Dataset>? datasets}) async {
  final price = priceOf(cfg.model, inPerMTok: cfg.inPerMTok, outPerMTok: cfg.outPerMTok);
  final queue = Queue<JudgeJob>()..addAll(planJudgeJobs(datasets ?? t07Datasets(cfg), k: cfg.k));
  final records = <JudgeRecord>[];
  final fallbacks = <String, int>{};
  final sw = Stopwatch()..start();
  var spent = 0.0, reserved = 0.0, made = 0;
  var stopped = false;

  // Antes de saber lo que cuesta una llamada se supone una de 1 000 tokens de entrada y 500 de salida.
  double estimate() => made == 0 ? price.costOf(1000, 500) : spent / made;

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
      final job = queue.removeFirst();
      reserved += est;
      try {
        final rec = await _one(job, cfg, port, price, fallbacks);
        records.add(rec);
        spent += rec.costUsd;
        made++;
      } finally {
        reserved -= est;
      }
    }
  }

  await Future.wait([for (var i = 0; i < cfg.concurrency; i++) worker()]);
  return T07ModelResult(records, spent, queue.length, stopped, fallbacks, sw.elapsed);
}

Future<JudgeRecord> _one(JudgeJob job, T07ModelConfig cfg, LlmPort port, ModelPrice price, Map<String, int> fallbacks) async {
  LlmResult? last;
  String? reason;
  final sw = Stopwatch()..start();
  final js = await judgeLinks(
    MeteredPort(port, (x) => last = x),
    job.target,
    job.candidates,
    timeout: cfg.timeout,
    onFallback: (why) => reason = why,
  );
  sw.stop();
  if (reason != null) fallbacks[reason!] = (fallbacks[reason!] ?? 0) + 1;
  return JudgeRecord(
    dataset: job.dataset,
    targetKey: job.target.reportKey,
    candidateKeys: [for (final c in job.candidates) c.reportKey],
    judgments: js,
    reason: reason,
    latencyMs: sw.elapsedMilliseconds,
    inputTokens: last?.inputTokens,
    outputTokens: last?.outputTokens,
    costUsd: price.costOf(last?.inputTokens ?? 0, last?.outputTokens ?? 0),
    requestId: last?.requestId,
  );
}

// ---------------------------------------------------------------------------------------------
// Evaluación
// ---------------------------------------------------------------------------------------------

/// Veredicto del juez × verdad (¿los dos reportes son del mismo suceso real?).
class JudgmentMatrix {
  int sameWhenSame = 0, sameWhenDifferent = 0;
  int possibleWhenSame = 0, possibleWhenDifferent = 0;
  int differentWhenSame = 0, differentWhenDifferent = 0;

  int get total => sameWhenSame + sameWhenDifferent + possibleWhenSame + possibleWhenDifferent + differentWhenSame + differentWhenDifferent;

  void add(JudgedVerdict v, bool truthSame) {
    switch ((v, truthSame)) {
      case (JudgedVerdict.same, true):
        sameWhenSame++;
      case (JudgedVerdict.same, false):
        sameWhenDifferent++;
      case (JudgedVerdict.possible, true):
        possibleWhenSame++;
      case (JudgedVerdict.possible, false):
        possibleWhenDifferent++;
      case (JudgedVerdict.different, true):
        differentWhenSame++;
      case (JudgedVerdict.different, false):
        differentWhenDifferent++;
    }
  }
}

/// Cuántos pares tocó el modelo y cuántos de ellos tenían razón ([harmful] = el modelo se equivocó, sólo para vetos).
class PairTally {
  int total = 0;
  int correct = 0;
  int get harmful => total - correct;
}

/// Un escenario de T08: cuántos grupos salen con las reglas y con el modelo, y cuánto cree la mayor de las agrupaciones.
class T08Row {
  const T08Row({
    required this.label,
    required this.kind,
    required this.reports,
    required this.rulesGroups,
    required this.modelGroups,
    required this.rulesIndependentSources,
    required this.modelIndependentSources,
    required this.rulesConfidence,
    required this.modelConfidence,
  });

  final String label;
  final String kind;
  final int reports;
  final int rulesGroups;
  final int modelGroups;
  final int rulesIndependentSources;
  final int modelIndependentSources;
  final double rulesConfidence;
  final double modelConfidence;
}

PairMetrics _sum(PairMetrics a, PairMetrics b) =>
    PairMetrics(a.tp + b.tp, a.fp + b.fp, a.fn + b.fn, a.groups + b.groups, a.mixedGroups + b.mixedGroups);

LinkCoverage _sumCov(LinkCoverage a, LinkCoverage b) =>
    LinkCoverage(a.truePairs + b.truePairs, a.same + b.same, a.sameCorrect + b.sameCorrect, a.possible + b.possible, a.possibleCorrect + b.possibleCorrect);

class T07Eval {
  T07Eval._(this._obs);
  final Map<String, List<Observation>> _obs;

  PairMetrics rules = PairMetrics(0, 0, 0, 0, 0);
  PairMetrics withModel = PairMetrics(0, 0, 0, 0, 0);
  PairMetrics withModelNoVeto = PairMetrics(0, 0, 0, 0, 0);

  LinkCoverage coverageRules = LinkCoverage(0, 0, 0, 0, 0);
  LinkCoverage coverageModel = LinkCoverage(0, 0, 0, 0, 0);

  /// Lo mismo restringido a los pares con texto en los dos reportes (los únicos que el modelo puede juzgar).
  LinkCoverage coverageRulesText = LinkCoverage(0, 0, 0, 0, 0);
  LinkCoverage coverageModelText = LinkCoverage(0, 0, 0, 0, 0);

  /// La evidencia que hay para juzgar: de los pares verdaderos con texto en los dos reportes, cuántos escriben la misma calle y
  /// cuántos comparten alguna palabra de contenido. No es un techo (una paráfrasis no comparte palabras), es contexto para leer
  /// «sube X puntos» contra lo que el texto permite.
  int textPairs = 0, textPairsSharingStreet = 0, textPairsSharingWord = 0;

  final JudgmentMatrix judgments = JudgmentMatrix();
  final JudgmentMatrix judgmentsConfident = JudgmentMatrix();

  /// Uniones que hizo el modelo (el par no estaba unido por reglas) y si acertó.
  final PairTally unions = PairTally();

  /// Vetos sobre uniones de las reglas; `harmful` = cortó un par del mismo suceso.
  final PairTally vetoes = PairTally();

  final Map<String, List<Link>> modelLinks = {};
  final Map<String, Set<(String, String)>> modelUnlinked = {};
  final List<T08Row> scenarios = [];

  /// Los grupos de un conjunto con unos vínculos dados (los mismos que formaría el nodo).
  List<Set<String>> groupsOf(String dataset, List<Link> links, Set<(String, String)> unlinked) =>
      groupsFromLinks(_obs[dataset]!, links, unlinked: unlinked);
}

final RegExp _streetRe = RegExp(r'carrera\s+(\d+)\s+con\s+calle\s+(\d+)', caseSensitive: false);

/// La calle escrita en el texto («carrera 16 con calle 39» → «16-39»), si la hay.
String? _street(String? text) {
  final m = _streetRe.firstMatch(text ?? '');
  return m == null ? null : '${m[1]}-${m[2]}';
}

/// Los grupos más grandes primero; el desempate es la clave más pequeña (determinista).
Set<String> _largest(List<Set<String>> groups) {
  final sorted = [...groups]..sort((a, b) {
    final c = b.length.compareTo(a.length);
    return c != 0 ? c : (a.toList()..sort()).first.compareTo((b.toList()..sort()).first);
  });
  return sorted.first;
}

/// Evalúa los juicios de [records] sobre [datasets]. Los conjuntos `synth` alimentan las métricas de pares; los demás son
/// escenarios de T08. Es una función pura: sirve igual con juicios reales que con un oráculo falso.
T07Eval evalT07(List<T07Dataset> datasets, List<JudgeRecord> records, {double minConfidence = kJudgeMinConfidence}) {
  final byDataset = <String, List<LinkJudgment>>{};
  for (final r in records) {
    (byDataset[r.dataset] ??= []).addAll(r.judgments);
  }
  final ev = T07Eval._({for (final d in datasets) d.label: [for (final r in d.reports) r.toObservation()]});
  for (final d in datasets) {
    final obs = ev._obs[d.label]!;
    final truth = {for (final r in d.reports) r.reportKey: r.trueIncident};
    final hasText = {for (final r in d.reports) r.reportKey: (r.text ?? '').trim().isNotEmpty};
    bool same(String a, String b) => truth[a] == truth[b] && truth[a]! >= 0;
    final js = byDataset[d.label] ?? const <LinkJudgment>[];

    final base = analyzeGrouping(obs);
    final withVeto = applyJudgments(obs, base.links, js, minConfidence: minConfidence);
    final noVeto = applyJudgments(obs, base.links, js, minConfidence: minConfidence, allowVeto: false);
    final modelGroups = groupsFromLinks(obs, withVeto.links, unlinked: withVeto.unlinked);
    ev.modelLinks[d.label] = withVeto.links;
    ev.modelUnlinked[d.label] = withVeto.unlinked;

    if (d.kind != 'synth') {
      final ar = assessGroup([
        for (final o in obs)
          if (_largest(base.groups).contains(o.reportKey)) o,
      ]);
      final am = assessGroup([
        for (final o in obs)
          if (_largest(modelGroups).contains(o.reportKey)) o,
      ]);
      ev.scenarios.add(T08Row(
        label: d.label,
        kind: d.kind,
        reports: obs.length,
        rulesGroups: base.groups.length,
        modelGroups: modelGroups.length,
        rulesIndependentSources: ar.independentSources,
        modelIndependentSources: am.independentSources,
        rulesConfidence: ar.confidence,
        modelConfidence: am.confidence,
      ));
      continue;
    }

    ev.rules = _sum(ev.rules, pairMetrics(base.groups, truth));
    ev.withModel = _sum(ev.withModel, pairMetrics(modelGroups, truth));
    ev.withModelNoVeto = _sum(ev.withModelNoVeto, pairMetrics(groupsFromLinks(obs, noVeto.links, unlinked: noVeto.unlinked), truth));
    ev.coverageRules = _sumCov(ev.coverageRules, linkCoverage(base.links, truth));
    ev.coverageModel = _sumCov(ev.coverageModel, linkCoverage(withVeto.links, truth));
    bool both(String a, String b) => hasText[a]! && hasText[b]!;
    ev.coverageRulesText = _sumCov(ev.coverageRulesText, linkCoverage(base.links, truth, where: both));
    ev.coverageModelText = _sumCov(ev.coverageModelText, linkCoverage(withVeto.links, truth, where: both));

    final byIncident = <int, List<SynthReport>>{};
    for (final r in d.reports) {
      if (r.trueIncident >= 0 && hasText[r.reportKey]!) (byIncident[r.trueIncident] ??= []).add(r);
    }
    for (final rs in byIncident.values) {
      for (var x = 0; x < rs.length; x++) {
        for (var y = x + 1; y < rs.length; y++) {
          ev.textPairs++;
          final sx = _street(rs[x].text);
          if (sx != null && sx == _street(rs[y].text)) ev.textPairsSharingStreet++;
          if (contentTokens(rs[x].text).intersection(contentTokens(rs[y].text)).isNotEmpty) ev.textPairsSharingWord++;
        }
      }
    }

    for (final j in js) {
      final t = same(j.a, j.b);
      ev.judgments.add(j.verdict, t);
      if (j.confidence >= minConfidence) ev.judgmentsConfident.add(j.verdict, t);
    }
    for (final l in withVeto.links) {
      if (l.pair.uncertainty.contains('union_por_modelo')) {
        ev.unions.total++;
        if (same(l.a, l.b)) ev.unions.correct++;
      }
    }
    final rulesSame = {
      for (final l in base.links)
        if (l.pair.state == LinkState.same) pairKey(l.a, l.b),
    };
    for (final p in withVeto.unlinked) {
      if (!rulesSame.contains(p)) continue;
      ev.vetoes.total++;
      if (!same(p.$1, p.$2)) ev.vetoes.correct++;
    }
  }
  return ev;
}

// ---------------------------------------------------------------------------------------------
// El criterio, aplicado mecánicamente
// ---------------------------------------------------------------------------------------------

class CriterionLine {
  const CriterionLine(this.id, this.description, this.value, this.met);
  final String id;
  final String description;
  final String value;
  final bool met;
}

class T07Verdict {
  const T07Verdict(this.lines, this.offerAsOption, this.recommend, this.allowVeto, this.conclusion);
  final List<CriterionLine> lines;

  /// Cumple la seguridad (1, 2, 4): se puede ofrecer como opción apagada por omisión.
  final bool offerAsOption;

  /// Además demuestra ganancia (3, 5, 6): se recomienda activarla.
  final bool recommend;

  /// El nodo puede dejar que el modelo vete una unión de las reglas.
  final bool allowVeto;
  final String conclusion;
}

const double _eps = 1e-12;

/// Aplica [kT07DecisionRule] a los resultados, sin margen para interpretarlos: cada criterio es un umbral y cada umbral tiene
/// su prueba en la frontera.
T07Verdict decideT07(T07Eval ev, List<JudgeRecord> records, T07ModelConfig cfg) {
  String pct(double x, [int d = 2]) => _pct(x, d: d);
  final fmM = ev.withModel.falseMergeRate, fmR = ev.rules.falseMergeRate;
  final u = ev.unions;
  final calls = records.length;
  final failures = records.where((r) => r.reason != null).length;
  final okCalls = calls - failures;
  final over8 = records.where((r) => r.reason == null && r.latencyMs > 8000).length;
  final gain = ev.withModel.recall - ev.rules.recall;
  final corro = ev.scenarios.where((s) => s.kind == 'corroboracion').toList();
  final corroOk = corro
      .where((s) => s.modelGroups == 1 && s.modelIndependentSources == cfg.corroborationSources && s.modelConfidence > s.rulesConfidence)
      .length;
  final rumor = ev.scenarios.where((s) => s.kind == 'rumor').toList();

  final l1 = CriterionLine('1', 'falsa fusión ≤ 1 % y ≤ la de las reglas + 0,5 puntos', '${pct(fmM)} con el modelo, ${pct(fmR)} con las reglas',
      fmM <= 0.01 + _eps && fmM <= fmR + 0.005 + _eps);
  final l2 = CriterionLine('2', 'precisión de las uniones del modelo ≥ 95 %', u.total == 0 ? 'sin uniones' : '${pct(u.correct / u.total, 1)} (${u.correct} de ${u.total})',
      u.total > 0 && u.correct / u.total >= 0.95 - _eps);
  final l4 = CriterionLine('4', 'fallos ≤ 5 % de las llamadas y llamadas de más de 8 s ≤ 5 % de las útiles',
      calls == 0 ? 'sin llamadas' : '$failures fallos de $calls; $over8 de $okCalls útiles pasan de 8 s',
      calls > 0 && failures / calls <= 0.05 + _eps && okCalls > 0 && over8 / okCalls <= 0.05 + _eps);
  final l3 = CriterionLine('3', 'recall de pares: +5 puntos y al menos el doble', '${pct(ev.rules.recall)} → ${pct(ev.withModel.recall)} (+${(100 * gain).toStringAsFixed(2)} puntos)',
      gain >= 0.05 - _eps && ev.withModel.recall >= 2 * ev.rules.recall - _eps);
  final l5 = CriterionLine('5', 'corroboración: un grupo con las ${cfg.corroborationSources} fuentes y más confianza en ≥ 80 % de los escenarios',
      corro.isEmpty ? 'sin escenarios' : '$corroOk de ${corro.length}', corro.isNotEmpty && corroOk / corro.length >= 0.8 - _eps);
  final rumorBad = rumor.where((s) => !(s.modelIndependentSources <= cfg.rumorSources && s.modelConfidence < 0.8)).length;
  final l6 = CriterionLine('6', 'rumor: no gana fuentes independientes ni pasa de 0,8 de confianza',
      rumor.isEmpty ? 'sin escenarios' : '${rumor.length - rumorBad} de ${rumor.length} sin ganancia indebida', rumor.isNotEmpty && rumorBad == 0);

  final v = ev.vetoes;
  final allowVeto = v.total > 0 && v.harmful / v.total <= 0.10 + _eps;
  final safe = l1.met && l2.met && l4.met;
  final recommend = safe && l3.met && l5.met && l6.met;
  final lines = [l1, l2, l4, l3, l5, l6];
  String ids(Iterable<CriterionLine> ls) => ls.map((l) => l.id).join(', ');
  final String conclusion;
  if (!safe) {
    conclusion = 'NO se ofrece la unión por modelo: no cumple el nivel de seguridad (criterios sin cumplir: ${ids([l1, l2, l4].where((l) => !l.met))}).';
  } else if (!recommend) {
    conclusion = 'Opción disponible, apagada por omisión, **sin ganancia demostrada**: cumple la seguridad pero no (${ids([l3, l5, l6].where((l) => !l.met))}).';
  } else {
    conclusion = 'Se ofrece como opción y se recomienda activarla: cumple todos los criterios.';
  }
  final vetoText = allowVeto
      ? 'El nodo puede dejar que el modelo vete (${v.harmful} de ${v.total} vetos dañinos).'
      : v.total == 0
      ? 'El nodo NO veta: sólo une (no hubo vetos que midan si es seguro).'
      : 'El nodo NO veta: sólo une (${v.harmful} de ${v.total} vetos fueron dañinos).';
  return T07Verdict(lines, safe, recommend, allowVeto, '$conclusion $vetoText');
}

/// El criterio de la RONDA 2 del juez (semillas 706–713, `--min-confidence 0.85`), **escrito y commiteado antes de gastar** y REESCRITO
/// tras ver los datos de la ronda 1: con una confianza mínima de 0,85 la ronda 1 habría dado 143 uniones buenas y 0 malas de las 257
/// y 5 que dio con 0,80 (análisis gratuito de `t07-modelo-datos.csv`: una hipótesis deducida de los MISMOS datos, no un resultado). Eso
/// hace inalcanzable por aritmética el «+5 puntos y el doble de recall» (≈ 56 % de la ganancia: ≈ +2 puntos), y el criterio de las 5
/// fuentes depende de un texto que el juez calificó `possible` (0,6): subir el umbral no lo arregla.
///
/// Como se reescribió tras ver la ronda 1, **es evidencia más débil que la de la primera vez** y el informe tiene que decirlo.
const String kT07DecisionRuleV2 =
    'Criterio de la ronda 2, REESCRITO tras ver los datos de la ronda 1 (evidencia más débil que la de la primera vez), escrito y commiteado antes de gastar. '
    'Semillas nuevas 706–713, mismo tamaño por semilla que la ronda 1, `--min-confidence 0.85`, mismo modelo, mismo esfuerzo y mismo mensaje (no se toca), '
    'comparación pareada contra reglas solas sobre los mismos reportes. **Se adopta la unión por modelo como opción apagada por omisión** sólo si se cumplen TODOS: '
    '(1) la falsa fusión de pares es ≤ 1 % y no supera en más de 0,5 puntos a la de sólo reglas; '
    '(2) la precisión de las uniones del modelo es ≥ 95 % con al menos 100 uniones hechas (con menos, el resultado es «no concluyente», no «cumple»); '
    '(3) el recall de pares sube al menos 1,5 puntos sobre el de sólo reglas (sustituye a «+5 puntos y el doble»); '
    '(4) los fallos del modelo son ≤ 5 % de las llamadas y las llamadas de más de 8 s ≤ 5 % de las útiles; '
    '(6) el rumor repetido no gana fuentes independientes por encima de las que tiene ni pasa de 0,8 de confianza. '
    'Se RETIRA el criterio de las 5 fuentes (5): se informa como observación, no como criterio. El veto sigue apagado. '
    'Si el criterio (1) vuelve a fallar, o el resultado es no concluyente, la pregunta se cierra: no se hace una tercera ronda.';

/// Número mínimo de uniones del modelo para poder juzgar su precisión en la ronda 2.
const int kT07MinUnionsV2 = 100;

/// Ganancia mínima de recall de pares (en puntos porcentuales, como fracción) de la ronda 2.
const double kT07MinRecallGainV2 = 0.015;

class T07VerdictV2 {
  const T07VerdictV2(this.lines, this.adopt, this.inconclusive, this.conclusion);
  final List<CriterionLine> lines;

  /// Cumple TODOS los criterios: se ofrece como opción apagada por omisión.
  final bool adopt;

  /// Hubo menos de [kT07MinUnionsV2] uniones y nada falló de forma definitiva: no se puede concluir ni en un sentido ni en otro.
  final bool inconclusive;
  final String conclusion;
}

/// Aplica [kT07DecisionRuleV2] a los resultados, sin margen para interpretarlos. Los ids de los criterios son los de v1 (el 5 se retiró).
T07VerdictV2 decideT07V2(T07Eval ev, List<JudgeRecord> records, T07ModelConfig cfg) {
  String pct(double x, [int d = 2]) => _pct(x, d: d);
  final fmM = ev.withModel.falseMergeRate, fmR = ev.rules.falseMergeRate;
  final u = ev.unions;
  final calls = records.length;
  final failures = records.where((r) => r.reason != null).length;
  final okCalls = calls - failures;
  final over8 = records.where((r) => r.reason == null && r.latencyMs > 8000).length;
  final gain = ev.withModel.recall - ev.rules.recall;
  final rumor = ev.scenarios.where((s) => s.kind == 'rumor').toList();

  final l1 = CriterionLine('1', 'falsa fusión ≤ 1 % y ≤ la de las reglas + 0,5 puntos', '${pct(fmM)} con el modelo, ${pct(fmR)} con las reglas', fmM <= 0.01 + _eps && fmM <= fmR + 0.005 + _eps);
  final enoughUnions = u.total >= kT07MinUnionsV2;
  final l2 = CriterionLine(
    '2',
    'precisión de las uniones del modelo ≥ 95 % con al menos $kT07MinUnionsV2 uniones',
    u.total == 0 ? 'sin uniones' : '${pct(u.correct / u.total, 1)} (${u.correct} de ${u.total}${enoughUnions ? '' : ': insuficientes'})',
    enoughUnions && u.correct / u.total >= 0.95 - _eps,
  );
  final l4 = CriterionLine('4', 'fallos ≤ 5 % de las llamadas y llamadas de más de 8 s ≤ 5 % de las útiles',
      calls == 0 ? 'sin llamadas' : '$failures fallos de $calls; $over8 de $okCalls útiles pasan de 8 s',
      calls > 0 && failures / calls <= 0.05 + _eps && okCalls > 0 && over8 / okCalls <= 0.05 + _eps);
  final l3 = CriterionLine('3', 'recall de pares: al menos +1,5 puntos sobre las reglas', '${pct(ev.rules.recall)} → ${pct(ev.withModel.recall)} (+${(100 * gain).toStringAsFixed(2)} puntos)', gain >= kT07MinRecallGainV2 - _eps);
  final rumorBad = rumor.where((s) => !(s.modelIndependentSources <= cfg.rumorSources && s.modelConfidence < 0.8)).length;
  final l6 = CriterionLine('6', 'rumor: no gana fuentes independientes ni pasa de 0,8 de confianza', rumor.isEmpty ? 'sin escenarios' : '${rumor.length - rumorBad} de ${rumor.length} sin ganancia indebida', rumor.isNotEmpty && rumorBad == 0);

  final lines = [l1, l2, l4, l3, l6];
  final adopt = lines.every((l) => l.met);
  // «No concluyente»: faltan uniones para juzgar y NADA de lo demás falló de forma definitiva.
  final inconclusive = !adopt && !enoughUnions && l1.met && l4.met && l6.met;
  String ids(Iterable<CriterionLine> ls) => ls.map((l) => l.id).join(', ');
  final String conclusion;
  if (adopt) {
    conclusion = 'Se adopta la unión por modelo como opción apagada por omisión: cumple todos los criterios de la ronda 2 (reescritos tras ver la ronda 1: evidencia más débil).';
  } else if (inconclusive) {
    conclusion = 'No concluyente: hubo menos de $kT07MinUnionsV2 uniones (${u.total}); no se puede juzgar su precisión ni su beneficio. La pregunta se cierra: no se hace una tercera ronda.';
  } else {
    conclusion = 'NO se adopta la unión por modelo: criterios sin cumplir: ${ids(lines.where((l) => !l.met))}. La pregunta se cierra: no se hace una tercera ronda.';
  }
  return T07VerdictV2(lines, adopt, inconclusive, conclusion);
}

// ---------------------------------------------------------------------------------------------
// Informes
// ---------------------------------------------------------------------------------------------

String _pct(double x, {int d = 1}) => '${(100 * x).toStringAsFixed(d)} %';

int _percentile(List<int> sorted, double p) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

/// El informe en Markdown. **Nunca** incluye la clave ni el texto de los reportes.
String renderT07Model(T07ModelConfig cfg, T07ModelResult res, List<T07Dataset> datasets, {String? codeVersion}) {
  final ev = evalT07(datasets, res.records, minConfidence: cfg.minConfidence);
  final b = StringBuffer();
  final synth = datasets.where((d) => d.kind == 'synth').toList();
  final nReports = synth.fold<int>(0, (a, d) => a + d.reports.length);
  final nText = synth.fold<int>(0, (a, d) => a + d.reports.where((r) => (r.text ?? '').trim().isNotEmpty).length);
  final ok = res.records.where((r) => r.reason == null).length;
  final lat = [for (final r in res.records) if (r.reason == null) r.latencyMs]..sort();
  final over8 = lat.where((l) => l > 8000).length;
  final inTok = res.records.fold<int>(0, (a, r) => a + (r.inputTokens ?? 0));
  final outTok = res.records.fold<int>(0, (a, r) => a + (r.outputTokens ?? 0));
  final calls = res.records.length;
  final failures = calls - ok;

  b.writeln('# T07 con el juez semántico REAL · agrupar reportes con otras palabras (Reto 4)');
  b.writeln();
  b.writeln('**Estado: medido contra la API real de Anthropic, UNA vez, con datos sintéticos.** Generado con `dart run packages/sim/bin/t07_modelo.dart`. La clave se leyó del entorno y no se escribió en ningún sitio.');
  b.writeln();
  b.writeln('## Qué se corrió');
  b.writeln();
  b.writeln('- Modelo **${cfg.model}**, effort **${cfg.effort ?? '(el de la API)'}**, confianza mínima ${cfg.minConfidence}, hasta ${cfg.k} candidatos por reporte (los anteriores que pasan las reglas duras).');
  b.writeln('- Semillas **${cfg.seeds.join(', ')}** (nuevas): ${synth.length} conjuntos sintéticos de ${cfg.incidents} sucesos y ~${cfg.reports} reportes ($nReports en total, $nText con texto), más una corroboración de ${cfg.corroborationSources} fuentes y un rumor de ${cfg.rumorCopies} copias por semilla.');
  b.writeln('- **$calls llamadas**${res.skipped > 0 ? ' (**${res.skipped} del plan NO se hicieron**: tope de gasto)' : ''}, gasto **\$${res.spentUsd.toStringAsFixed(2)}** (tope \$${cfg.budgetUsd.toStringAsFixed(2)}), ${res.elapsed.inSeconds} s.');
  b.writeln('- El tope de gasto se comprueba antes de cada llamada contando lo que cuestan las que están en vuelo; **no es estrictamente duro** (un piloto lo pasó por 0,0001 USD).');
  if (codeVersion != null) b.writeln('- Código: `$codeVersion`.');
  b.writeln();
  b.writeln(cfg.criterion == 2 ? '### Criterio de adopción de la ronda 2 (REESCRITO tras ver la ronda 1: evidencia más débil)' : '### Criterio de adopción (fijado antes de ver los datos)');
  b.writeln();
  b.writeln(cfg.criterion == 2 ? kT07DecisionRuleV2 : kT07DecisionRule);
  b.writeln();

  b.writeln('## Resultado de pares (T07)');
  b.writeln();
  b.writeln('| | Sólo reglas | Reglas + modelo (con veto) | Reglas + modelo (sin veto) |');
  b.writeln('|---|---|---|---|');
  String row(String name, String Function(PairMetrics) f) => '| $name | ${f(ev.rules)} | ${f(ev.withModel)} | ${f(ev.withModelNoVeto)} |';
  b.writeln(row('Precisión de pares', (m) => _pct(m.precision)));
  b.writeln(row('**Recall de pares**', (m) => _pct(m.recall)));
  b.writeln(row('**Falsa fusión** (criterio ≤ 1 %)', (m) => _pct(m.falseMergeRate, d: 2)));
  b.writeln(row('Grupos mezclados (más de un suceso real)', (m) => '${m.mixedGroups}'));
  b.writeln(row('Grupos (para ${synth.fold<int>(0, (a, d) => a + d.reports.map((r) => r.trueIncident).where((i) => i >= 0).toSet().length)} sucesos reales)', (m) => '${m.groups}'));
  b.writeln();
  b.writeln('Pares verdaderos: ${ev.coverageRules.truePairs}; de ellos con texto en los dos reportes: ${ev.coverageRulesText.truePairs}.');
  if (ev.textPairs > 0) {
    b.writeln('De esos ${ev.textPairs} pares con texto: **${_pct(ev.textPairsSharingStreet / ev.textPairs)}** comparten la calle escrita y **${_pct(ev.textPairsSharingWord / ev.textPairs)}** alguna palabra de contenido. '
        'No es un techo (una paráfrasis no comparte palabras), pero dice cuánta evidencia hay en el texto: en este generador los gemelos adversariales usan la MISMA calle que su suceso base.');
  }
  b.writeln();
  b.writeln('| Cobertura de pares verdaderos | Sólo reglas | + modelo (con veto) |');
  b.writeln('|---|---|---|');
  b.writeln('| Agrupa (`same`), todos los pares | ${_pct(ev.coverageRules.recallGrouped)} | ${_pct(ev.coverageModel.recallGrouped)} |');
  b.writeln('| Al menos sugiere (`same` + `possible`), todos | ${_pct(ev.coverageRules.recallSuggested)} | ${_pct(ev.coverageModel.recallSuggested)} |');
  b.writeln('| Agrupa, sólo pares con texto en los dos | ${_pct(ev.coverageRulesText.recallGrouped)} | ${_pct(ev.coverageModelText.recallGrouped)} |');
  b.writeln('| Al menos sugiere, sólo pares con texto en los dos | ${_pct(ev.coverageRulesText.recallSuggested)} | ${_pct(ev.coverageModelText.recallSuggested)} |');
  b.writeln();

  b.writeln('## Matriz del juez (veredicto × verdad)');
  b.writeln();
  b.writeln('Sobre los pares que el modelo juzgó (cada reporte contra sus candidatos), contra la verdad del generador.');
  b.writeln();
  b.writeln('| Veredicto | Mismo suceso (todos) | Distinto suceso (todos) | Mismo suceso (conf. ≥ ${cfg.minConfidence}) | Distinto suceso (conf. ≥ ${cfg.minConfidence}) |');
  b.writeln('|---|---|---|---|---|');
  final a = ev.judgments, c = ev.judgmentsConfident;
  b.writeln('| `same` | ${a.sameWhenSame} | ${a.sameWhenDifferent} | ${c.sameWhenSame} | ${c.sameWhenDifferent} |');
  b.writeln('| `possible` | ${a.possibleWhenSame} | ${a.possibleWhenDifferent} | ${c.possibleWhenSame} | ${c.possibleWhenDifferent} |');
  b.writeln('| `different` | ${a.differentWhenSame} | ${a.differentWhenDifferent} | ${c.differentWhenSame} | ${c.differentWhenDifferent} |');
  b.writeln();
  final sameJudged = a.sameWhenSame + a.sameWhenDifferent;
  if (sameJudged > 0) b.writeln('Precisión de los `same`: ${_pct(a.sameWhenSame / sameJudged)} (${a.sameWhenSame} de $sameJudged).');
  final possJudged = a.possibleWhenSame + a.possibleWhenDifferent;
  b.writeln(possJudged == 0
      ? 'Precisión de los `possible`: — (no hubo). Los `possible` no cambian nada hoy.'
      : 'Precisión de los `possible`: ${_pct(a.possibleWhenSame / possJudged)} (${a.possibleWhenSame} de $possJudged); la de las sugerencias por reglas fue 92 % (`b3.md`). Los `possible` no cambian nada hoy: su confianza queda bajo el umbral y sólo son información.');
  final diffJudged = a.differentWhenSame + a.differentWhenDifferent;
  if (diffJudged > 0) b.writeln('Precisión de los `different`: ${_pct(a.differentWhenDifferent / diffJudged)} (${a.differentWhenDifferent} de $diffJudged).');
  b.writeln();

  b.writeln('## Uniones del modelo y vetos');
  b.writeln();
  b.writeln('- **Uniones del modelo** (pares que las reglas no unían y el modelo sí, con confianza suficiente): **${ev.unions.total}**, de las cuales **${ev.unions.correct}** eran del mismo suceso${ev.unions.total == 0 ? '' : ' (precisión ${_pct(ev.unions.correct / ev.unions.total)})'}.');
  b.writeln('- **Vetos del modelo** (cortó una unión de las reglas): **${ev.vetoes.total}**, de los cuales **${ev.vetoes.harmful}** cortaron un par del mismo suceso${ev.vetoes.total == 0 ? '' : ' (dañinos ${_pct(ev.vetoes.harmful / ev.vetoes.total)})'}.');
  b.writeln();

  b.writeln('## T08 con el juez (corroboración y rumor)');
  b.writeln();
  b.writeln('| Escenario | Reportes | Grupos (reglas → modelo) | Fuentes independientes del mayor grupo (reglas → modelo) | Confianza del mayor grupo (reglas → modelo) |');
  b.writeln('|---|---|---|---|---|');
  for (final s in ev.scenarios) {
    b.writeln('| ${s.label} | ${s.reports} | ${s.rulesGroups} → ${s.modelGroups} | ${s.rulesIndependentSources} → ${s.modelIndependentSources} | ${s.rulesConfidence.toStringAsFixed(2)} → ${s.modelConfidence.toStringAsFixed(2)} |');
  }
  b.writeln();

  final List<CriterionLine> verdictLines;
  final String verdictConclusion;
  if (cfg.criterion == 2) {
    final v2 = decideT07V2(ev, res.records, cfg);
    verdictLines = v2.lines;
    verdictConclusion = v2.conclusion;
  } else {
    final v1 = decideT07(ev, res.records, cfg);
    verdictLines = v1.lines;
    verdictConclusion = v1.conclusion;
  }
  b.writeln('## Veredicto del criterio (aplicado mecánicamente)');
  b.writeln();
  b.writeln('| Criterio | Valor | ¿Cumple? |');
  b.writeln('|---|---|---|');
  for (final l in verdictLines) {
    b.writeln('| ${l.id}. ${l.description} | ${l.value} | ${l.met ? 'sí' : '**no**'} |');
  }
  b.writeln();
  b.writeln('**$verdictConclusion**');
  if (cfg.criterion == 2) {
    b.writeln();
    b.writeln('La corroboración de 5 fuentes (T08) se informa arriba como observación: su criterio se retiró (criterio retirado en la ronda 2).');
  }
  b.writeln();

  b.writeln('## Latencia, coste y fallos');
  b.writeln();
  b.writeln('- Llamadas útiles: **$ok de $calls**; fallos: **$failures**${res.fallbacks.isEmpty ? '' : ' (${res.fallbacks.entries.map((e) => '${e.key}: ${e.value}').join(', ')})'}.');
  b.writeln('- Latencia p50 / p95 / máx: ${_percentile(lat, 0.5) / 1000} / ${_percentile(lat, 0.95) / 1000} / ${lat.isEmpty ? 0 : lat.last / 1000} s; llamadas por encima de **8 s** (plazo del nodo): **$over8 de ${lat.length}**.');
  b.writeln('- Tokens: $inTok de entrada y $outTok de salida; **${calls == 0 ? 0 : (res.spentUsd / calls).toStringAsFixed(4)} USD por llamada** (precio de la guía del 6 oct 2026; la consola manda).');
  b.writeln();

  b.writeln('## Lo que esta prueba NO dice');
  b.writeln();
  b.writeln('- Datos **sintéticos**, escritos por la misma persona que las reglas y que el mensaje al modelo; **una sola corrida** (estos modelos no permiten fijar el muestreo); el mensaje **sin afinar**.');
  b.writeln('- Conjuntos pequeños (${cfg.incidents} sucesos): la falsa fusión tiene un intervalo de confianza ancho; un par mal unido pesa mucho.');
  b.writeln('- La corroboración (${cfg.corroborationSources} fuentes) y el rumor usan **textos fijos** del generador: es un caso, no una distribución.');
  b.writeln('- El modelo sólo ve los ${cfg.k} candidatos que elige el código: lo que quede fuera no se puede unir; el recall está acotado por esa elección.');
  b.writeln('- Sólo se juzgan reportes con texto; en la app el texto es **opcional** (hasta 140 bytes), así que el efecto en la operación depende de cuántos reportes reales lo traigan: aquí ${(nReports == 0 ? 0 : 100 * nText / nReports).toStringAsFixed(0)} % lo traen, un dato del generador y no de la vida real.');
  b.writeln('- El texto libre del ciudadano **sale hacia un tercero sin redactar** (ver PDF §8).');
  b.writeln('- Las variantes con y sin veto se miden las dos sobre los mismos datos; si se elige una después de verlas, esa elección es exploratoria (el criterio de arriba se fijó antes).');
  return b.toString();
}

/// Datos crudos: una fila por par juzgado, con la verdad. **Sin el texto de los reportes.**
String renderT07ModelCsv(List<T07Dataset> datasets, List<JudgeRecord> records) {
  final truth = {
    for (final d in datasets) d.label: {for (final r in d.reports) r.reportKey: r.trueIncident},
  };
  final b = StringBuffer('dataset,a,b,verdict,confidence,truth_same\n');
  for (final r in records) {
    final t = truth[r.dataset] ?? const <String, int>{};
    for (final j in r.judgments) {
      final same = t[j.a] != null && t[j.a] == t[j.b] && t[j.a]! >= 0;
      b.writeln('${r.dataset},${j.a},${j.b},${j.verdict.name},${j.confidence},$same');
    }
  }
  return b.toString();
}
