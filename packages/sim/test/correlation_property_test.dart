import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// Referencia: comparar TODOS con TODOS (sólo con la ventana de tiempo y el tipo compatible, que son
/// política y no optimización). El bloqueo espacial y el orden de candidatos son optimizaciones:
/// no pueden cambiar qué pares son `same`.
Set<(String, String)> bruteForceSame(List<Observation> all, Weights w, Duration window) {
  final out = <(String, String)>{};
  for (var i = 0; i < all.length; i++) {
    for (var j = i + 1; j < all.length; j++) {
      final a = all[i], b = all[j];
      if ((a.capturedAtMs - b.capturedAtMs).abs() > window.inMilliseconds) continue;
      if (!typesCompatible(a.incidentType, b.incidentType)) continue;
      if (scorePair(a, b, w).state == LinkState.same) out.add(pairKey(a.reportKey, b.reportKey));
    }
  }
  return out;
}

void main() {
  final ds = generateDataset(const SynthConfig(seed: 3));
  final obs = [for (final r in ds.reports) r.toObservation()];

  test('el conjunto incluye reportes imprecisos y sin ubicación (si no, la prueba no prueba nada)', () {
    expect(obs.where((o) => o.hasLocation && o.sigma! >= 1000), isNotEmpty);
    expect(obs.where((o) => !o.hasLocation), isNotEmpty);
  });

  test('el bloqueo reproduce EXACTAMENTE los vínculos `same` de comparar todos con todos', () {
    const w = Weights();
    const window = Duration(hours: 3);
    final fast = computeLinks(obs, weights: w, maxCandidates: kNoCandidateLimit, window: window);
    final got = {
      for (final l in fast.links)
        if (l.pair.state == LinkState.same) pairKey(l.a, l.b),
    };
    final want = bruteForceSame(obs, w, window);
    expect(want, isNotEmpty);
    expect(got.difference(want), isEmpty, reason: 'vínculos que sobran');
    expect(want.difference(got), isEmpty, reason: 'vínculos que faltan');
  });

  test('el bloqueo compara bastante menos de la mitad de los pares posibles', () {
    final r = computeLinks(obs);
    final all = obs.length * (obs.length - 1) ~/ 2;
    expect(r.comparisons, lessThan(all ~/ 2), reason: '${r.comparisons} de $all');
  });

  test('con el tope de 20 candidatos, los grupos no dependen del orden de llegada (3 barajas)', () {
    String sig(List<Set<String>> gs) => (gs.map((s) => (s.toList()..sort()).join(',')).toList()..sort()).join('|');
    final ref = sig(groupObservations(obs));
    for (final seed in [1, 2, 3]) {
      final sh = [...obs]..shuffle(Random(seed));
      expect(sig(groupObservations(sh)), ref, reason: 'baraja $seed');
    }
  });

  test('ningún reporte desaparece de los grupos', () {
    final groups = groupObservations(obs);
    expect(groups.expand((g) => g).toSet(), obs.map((o) => o.reportKey).toSet());
  });
}
