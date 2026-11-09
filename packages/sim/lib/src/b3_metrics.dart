import 'package:sard_agents/sard_agents.dart';

/// Una predicción de triaje frente a la verdad de referencia.
class TriageSample {
  const TriageSample({
    required this.truth,
    required this.predicted,
    required this.escalate,
    required this.subgroup,
    required this.incident,
    required this.tags,
  });

  final Urgency truth;
  final Urgency predicted;

  /// El triaje pidió revisión humana.
  final bool escalate;
  final String subgroup;
  final int incident;
  final Set<String> tags;
}

/// Recall y precisión de P1.
class P1Stats {
  int truth = 0; // reportes cuya verdad es P1
  int predicted = 0; // reportes predichos como P1
  int tp = 0; // P1 predichos que son P1
  int caughtOrEscalated = 0; // P1 verdaderos que salieron P1 **o** con revisión humana

  double get recall => truth == 0 ? 0.0 : tp / truth;
  double get precision => predicted == 0 ? 0.0 : tp / predicted;

  /// Contando «escalar a revisión humana» como un acierto. Se reporta SIEMPRE aparte de [recall]:
  /// son afirmaciones distintas («el sistema lo clasificó P1» frente a «el sistema pidió que un
  /// humano lo mire»).
  double get recallWithEscalation => truth == 0 ? 0.0 : caughtOrEscalated / truth;
}

class TriageEval {
  TriageEval(this.global, this.bySubgroup, this.byTag, this.confusion, this.accuracy, this.incidentRecallP1);
  final P1Stats global;
  final Map<String, P1Stats> bySubgroup;
  final Map<String, P1Stats> byTag;

  /// `confusion[verdad][predicción]` con el orden P1..P4.
  final List<List<int>> confusion;
  final double accuracy;

  /// Fracción de sucesos P1 de los que **algún** reporte salió P1.
  final double incidentRecallP1;
}

void _add(P1Stats s, TriageSample x) {
  final isTruthP1 = x.truth == Urgency.p1;
  final isPredP1 = x.predicted == Urgency.p1;
  if (isTruthP1) s.truth++;
  if (isPredP1) s.predicted++;
  if (isTruthP1 && isPredP1) s.tp++;
  if (isTruthP1 && (isPredP1 || x.escalate)) s.caughtOrEscalated++;
}

TriageEval evalTriage(List<TriageSample> samples) {
  final global = P1Stats();
  final bySub = <String, P1Stats>{};
  final byTag = <String, P1Stats>{};
  final conf = List.generate(4, (_) => List.filled(4, 0));
  var correct = 0;
  final p1Incidents = <int>{};
  final caughtIncidents = <int>{};
  for (final x in samples) {
    _add(global, x);
    _add(bySub.putIfAbsent(x.subgroup, P1Stats.new), x);
    for (final t in x.tags) {
      _add(byTag.putIfAbsent(t, P1Stats.new), x);
    }
    conf[x.truth.index][x.predicted.index]++;
    if (x.truth == x.predicted) correct++;
    if (x.truth == Urgency.p1) {
      p1Incidents.add(x.incident);
      if (x.predicted == Urgency.p1) caughtIncidents.add(x.incident);
    }
  }
  return TriageEval(
    global,
    bySub,
    byTag,
    conf,
    samples.isEmpty ? 0.0 : correct / samples.length,
    p1Incidents.isEmpty ? 0.0 : caughtIncidents.length / p1Incidents.length,
  );
}

/// Métricas de agrupamiento por pares **sobre los grupos finales** (componentes).
///
/// Un solo vínculo falso fusiona dos sucesos enteros, así que lo que importa es cuántos pares de
/// reportes quedan juntos sin ser del mismo suceso, no cuántos vínculos fueron erróneos.
class PairMetrics {
  PairMetrics(this.tp, this.fp, this.fn, this.groups, this.mixedGroups);
  final int tp, fp, fn;
  final int groups;

  /// Grupos que contienen reportes de más de un suceso real.
  final int mixedGroups;

  double get precision => tp + fp == 0 ? 0.0 : tp / (tp + fp);
  double get recall => tp + fn == 0 ? 0.0 : tp / (tp + fn);
  double get f1 => precision + recall == 0 ? 0.0 : 2 * precision * recall / (precision + recall);

  /// Pares dentro de un mismo grupo que son de sucesos distintos, sobre todos los pares dentro de
  /// algún grupo. T07 exige ≤ 1 %.
  double get falseMergeRate => tp + fp == 0 ? 0.0 : fp / (tp + fp);
}

PairMetrics pairMetrics(List<Set<String>> predicted, Map<String, int> truth) {
  var tp = 0, fp = 0, mixed = 0;
  for (final g in predicted) {
    final labels = <int>{};
    final keys = g.where(truth.containsKey).toList();
    for (final k in keys) {
      if (truth[k]! >= 0) labels.add(truth[k]!);
    }
    if (labels.length > 1) mixed++;
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        if (truth[keys[i]] == truth[keys[j]] && truth[keys[i]]! >= 0) {
          tp++;
        } else {
          fp++;
        }
      }
    }
  }
  final sizes = <int, int>{};
  truth.forEach((_, l) {
    if (l >= 0) sizes[l] = (sizes[l] ?? 0) + 1;
  });
  final truePairs = sizes.values.fold<int>(0, (a, n) => a + n * (n - 1) ~/ 2);
  return PairMetrics(tp, fp, truePairs - tp, predicted.length, mixed);
}

/// Métricas a nivel de **vínculo** (se reportan aparte de las de componentes).
class LinkMetrics {
  LinkMetrics(this.same, this.sameCorrect);
  final int same;
  final int sameCorrect;
  double get precision => same == 0 ? 0.0 : sameCorrect / same;
}

LinkMetrics linkMetrics(List<Link> links, Map<String, int> truth) {
  var same = 0, ok = 0;
  for (final l in links) {
    if (l.pair.state != LinkState.same) continue;
    same++;
    if (truth[l.a] == truth[l.b] && truth[l.a]! >= 0) ok++;
  }
  return LinkMetrics(same, ok);
}

/// Grupos que resultan de usar [hi] (y [noLoc] cuando falta la ubicación) como umbral de `same`
/// sobre vínculos ya puntuados. Permite barrer umbrales sin volver a puntuar.
List<Set<String>> groupsAt(List<String> keys, List<Link> links, double hi, double noLoc) {
  final parent = {for (final k in keys) k: k};
  String find(String x) {
    var r = x;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    return r;
  }

  for (final l in links) {
    final threshold = l.pair.uncertainty.contains('ubicacion_ausente') ? noLoc : hi;
    if (l.pair.score < threshold) continue;
    final ra = find(l.a), rb = find(l.b);
    if (ra == rb) continue;
    if (ra.compareTo(rb) < 0) {
      parent[rb] = ra;
    } else {
      parent[ra] = rb;
    }
  }
  final groups = <String, Set<String>>{};
  for (final k in keys) {
    groups.putIfAbsent(find(k), () => <String>{}).add(k);
  }
  final order = groups.keys.toList()..sort();
  return [for (final k in order) groups[k]!];
}

/// Cobertura de los vínculos: cuántos pares verdaderos AGRUPA (`same`), cuántos al menos
/// SUGIERE (`possible`) y qué tan fiables son las sugerencias.
class LinkCoverage {
  LinkCoverage(this.truePairs, this.same, this.sameCorrect, this.possible, this.possibleCorrect);
  final int truePairs;
  final int same;
  final int sameCorrect;
  final int possible;
  final int possibleCorrect;

  double get recallGrouped => truePairs == 0 ? 0.0 : sameCorrect / truePairs;
  double get recallSuggested => truePairs == 0 ? 0.0 : (sameCorrect + possibleCorrect) / truePairs;
  double get precisionPossible => possible == 0 ? 0.0 : possibleCorrect / possible;
}

LinkCoverage linkCoverage(List<Link> links, Map<String, int> truth) {
  final sizes = <int, int>{};
  truth.forEach((_, l) {
    if (l >= 0) sizes[l] = (sizes[l] ?? 0) + 1;
  });
  final truePairs = sizes.values.fold<int>(0, (a, n) => a + n * (n - 1) ~/ 2);
  var same = 0, sameOk = 0, poss = 0, possOk = 0;
  for (final l in links) {
    final ok = truth[l.a] == truth[l.b] && truth[l.a]! >= 0;
    if (l.pair.state == LinkState.same) {
      same++;
      if (ok) sameOk++;
    } else if (l.pair.state == LinkState.possible) {
      poss++;
      if (ok) possOk++;
    }
  }
  return LinkCoverage(truePairs, same, sameOk, poss, possOk);
}

/// Recall de P1 **tal como lo ve la cola**: la urgencia de un grupo es la más alta de sus miembros,
/// así que un P1 mal clasificado queda a la vista si un compañero de grupo sí salió P1. Cuenta, de
/// los reportes cuya verdad es P1, cuántos están en un grupo que se muestra como P1.
double groupVisibleRecallP1(List<Set<String>> groups, Map<String, Urgency> predicted, Map<String, Urgency> truth) {
  var p1 = 0, visible = 0;
  for (final g in groups) {
    final groupIsP1 = g.any((k) => predicted[k] == Urgency.p1);
    for (final k in g) {
      if (truth[k] != Urgency.p1) continue;
      p1++;
      if (groupIsP1) visible++;
    }
  }
  return p1 == 0 ? 0.0 : visible / p1;
}

/// Los mismos vínculos con el estado recalculado para otros umbrales de `same` ([hi], y [noLoc]
/// cuando falta la ubicación). Los vínculos ya puntuados no se vuelven a calcular.
List<Link> rethreshold(List<Link> links, double hi, double noLoc) => [
  for (final l in links)
    Link(
      l.a,
      l.b,
      PairScore(
        l.pair.score,
        l.pair.score >= (l.pair.uncertainty.contains('ubicacion_ausente') ? noLoc : hi) ? LinkState.same : LinkState.possible,
        l.pair.uncertainty,
        l.pair.terms,
      ),
    ),
];
