import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

TriageSample s(Urgency truth, Urgency pred, {bool esc = false, String sub = 'x', int inc = 0, Set<String> tags = const {}}) =>
    TriageSample(truth: truth, predicted: pred, escalate: esc, subgroup: sub, incident: inc, tags: tags);

void main() {
  group('T06 · recall y precisión de P1 (calculados a mano)', () {
    // verdad P1: 4 reportes → 3 acertados como P1, 1 predicho P2 con escalado.
    // verdad no-P1: 3 reportes → 1 predicho P1 (falso positivo), 2 acertados.
    final samples = [
      s(Urgency.p1, Urgency.p1),
      s(Urgency.p1, Urgency.p1),
      s(Urgency.p1, Urgency.p1),
      s(Urgency.p1, Urgency.p2, esc: true),
      s(Urgency.p2, Urgency.p1),
      s(Urgency.p2, Urgency.p2),
      s(Urgency.p3, Urgency.p3),
    ];
    final m = evalTriage(samples);

    test('recall = 3/4, precisión = 3/4, exactitud = 5/7', () {
      expect(m.global.truth, 4);
      expect(m.global.recall, closeTo(0.75, 1e-12));
      expect(m.global.precision, closeTo(0.75, 1e-12));
      expect(m.accuracy, closeTo(5 / 7, 1e-12));
    });

    test('contando el escalado a revisión humana como acierto: recall = 4/4, rotulado aparte', () {
      expect(m.global.recallWithEscalation, 1.0);
      expect(m.global.recall, lessThan(m.global.recallWithEscalation));
    });

    test('matriz de confusión verdad × predicción', () {
      expect(m.confusion[Urgency.p1.index][Urgency.p1.index], 3);
      expect(m.confusion[Urgency.p1.index][Urgency.p2.index], 1);
      expect(m.confusion[Urgency.p2.index][Urgency.p1.index], 1);
    });

    test('sin ningún P1 verdadero el recall no es NaN sino 0', () {
      final e = evalTriage([s(Urgency.p3, Urgency.p3)]);
      expect(e.global.recall, 0.0);
      expect(e.global.precision, 0.0);
    });
  });

  group('T06 · por subgrupo y a nivel de suceso', () {
    final samples = [
      s(Urgency.p1, Urgency.p1, sub: 'coherentes', inc: 1),
      s(Urgency.p1, Urgency.p1, sub: 'coherentes', inc: 1),
      s(Urgency.p1, Urgency.p3, sub: 'sin_pistas', inc: 2, esc: true),
      s(Urgency.p1, Urgency.p3, sub: 'sin_pistas', inc: 2, esc: true),
      s(Urgency.p1, Urgency.p3, sub: 'sin_pistas', inc: 3),
      s(Urgency.p1, Urgency.p1, sub: 'parcial', inc: 3),
    ];
    final m = evalTriage(samples);

    test('recall por subgrupo', () {
      expect(m.bySubgroup['coherentes']!.recall, 1.0);
      expect(m.bySubgroup['sin_pistas']!.recall, 0.0);
      expect(m.bySubgroup['sin_pistas']!.recallWithEscalation, closeTo(2 / 3, 1e-12));
      expect(m.bySubgroup['parcial']!.recall, 1.0);
    });

    test('recall a nivel de suceso: un suceso P1 se «atrapa» si alguno de sus reportes salió P1', () {
      // sucesos P1: 1 (atrapado), 2 (ningún reporte P1), 3 (un reporte P1) → 2/3
      expect(m.incidentRecallP1, closeTo(2 / 3, 1e-12));
    });

    test('por etiqueta ortogonal (p. ej. parafraseado)', () {
      final e = evalTriage([
        s(Urgency.p1, Urgency.p1, tags: {'parafraseado'}),
        s(Urgency.p1, Urgency.p3, tags: {'parafraseado'}),
        s(Urgency.p1, Urgency.p1),
      ]);
      expect(e.byTag['parafraseado']!.recall, 0.5);
    });
  });

  group('T07 · métricas de agrupamiento SOBRE COMPONENTES (calculadas a mano)', () {
    // verdad: A = {1,2,3}, B = {4,5}.  predicho: {1,2}, {3,4}, {5}
    final truth = {'1': 0, '2': 0, '3': 0, '4': 1, '5': 1};
    final predicted = [
      {'1', '2'},
      {'3', '4'},
      {'5'},
    ];
    final m = pairMetrics(predicted, truth);

    test('pares predichos (1,2) ✓ y (3,4) ✗; pares verdaderos (1,2),(1,3),(2,3),(4,5)', () {
      expect(m.tp, 1);
      expect(m.fp, 1);
      expect(m.fn, 3);
      expect(m.precision, 0.5);
      expect(m.recall, 0.25);
      expect(m.f1, closeTo(2 * 0.5 * 0.25 / 0.75, 1e-12));
    });

    test('la tasa de falsa fusión es la fracción de pares dentro de un grupo que son de sucesos distintos', () {
      expect(m.falseMergeRate, 0.5);
    });

    test('grupos mezclados: 1 de 3 contiene más de un suceso real', () {
      expect(m.groups, 3);
      expect(m.mixedGroups, 1);
    });

    test('un solo vínculo falso entre dos sucesos de 12 reportes mezcla un grupo con 144 pares cruzados', () {
      final tr = {for (var i = 0; i < 12; i++) 'a$i': 0, for (var i = 0; i < 12; i++) 'b$i': 1};
      final pred = [
        {for (var i = 0; i < 12; i++) 'a$i', for (var i = 0; i < 12; i++) 'b$i'},
      ];
      final x = pairMetrics(pred, tr);
      expect(x.fp, 144);
      expect(x.falseMergeRate, closeTo(144 / (66 + 66 + 144), 1e-12));
      expect(x.mixedGroups, 1);
    });

    test('sin ningún par predicho, la falsa fusión es 0 (no NaN) y el recall es 0', () {
      final x = pairMetrics([{'1'}, {'2'}], {'1': 0, '2': 0});
      expect(x.falseMergeRate, 0.0);
      expect(x.recall, 0.0);
      expect(x.precision, 0.0);
    });
  });

  group('T07 · nivel de vínculo (aparte)', () {
    test('precisión de los vínculos `same`: los que unen reportes del mismo suceso', () {
      final links = [
        Link('1', '2', const PairScore(0.9, LinkState.same, [], {})),
        Link('1', '4', const PairScore(0.85, LinkState.same, [], {})),
        Link('2', '3', const PairScore(0.6, LinkState.possible, [], {})),
      ];
      final truth = {'1': 0, '2': 0, '3': 0, '4': 1};
      final l = linkMetrics(links, truth);
      expect(l.same, 2);
      expect(l.sameCorrect, 1);
      expect(l.precision, 0.5);
    });
  });

  group('T07 · cobertura de las sugerencias (`possible`), aparte de lo que agrupa', () {
    final truth = {'1': 0, '2': 0, '3': 0, '4': 1, '5': 1, '6': 2};
    // pares verdaderos: (1,2) (1,3) (2,3) (4,5) = 4
    final links = [
      Link('1', '2', const PairScore(0.9, LinkState.same, [], {})), // verdadero, same
      Link('4', '5', const PairScore(0.7, LinkState.possible, [], {})), // verdadero, possible
      Link('1', '3', const PairScore(0.6, LinkState.possible, [], {})), // verdadero, possible
      Link('3', '6', const PairScore(0.58, LinkState.possible, [], {})), // falso, possible
    ];
    final c = linkCoverage(links, truth);

    test('pares verdaderos totales, y cuántos llegan a same y a possible', () {
      expect(c.truePairs, 4);
      expect(c.sameCorrect, 1);
      expect(c.possible, 3);
      expect(c.possibleCorrect, 2);
    });

    test('recall que AGRUPA = 1/4; recall que al menos SUGIERE = 3/4; precisión de lo sugerido = 2/3', () {
      expect(c.recallGrouped, closeTo(0.25, 1e-12));
      expect(c.recallSuggested, closeTo(0.75, 1e-12));
      expect(c.precisionPossible, closeTo(2 / 3, 1e-12));
    });
  });

  group('T06 · recall de P1 tal como lo ve la cola (urgencia del grupo = la más alta)', () {
    test('un P1 clasificado P3 queda visible si en su grupo hay un reporte clasificado P1', () {
      final truth = {'a': Urgency.p1, 'b': Urgency.p3, 'c': Urgency.p1};
      final pred = {'a': Urgency.p3, 'b': Urgency.p1, 'c': Urgency.p3};
      final groups = [
        {'a', 'b'},
        {'c'},
      ];
      expect(groupVisibleRecallP1(groups, pred, truth), closeTo(0.5, 1e-12));
    });

    test('sin P1 verdaderos, 0 (no NaN)', () {
      expect(groupVisibleRecallP1([{'a'}], {'a': Urgency.p3}, {'a': Urgency.p3}), 0.0);
    });

    test('con cada reporte solo (sin agrupar) coincide con el recall por reporte', () {
      final truth = {'a': Urgency.p1, 'b': Urgency.p1, 'c': Urgency.p2};
      final pred = {'a': Urgency.p1, 'b': Urgency.p3, 'c': Urgency.p1};
      expect(groupVisibleRecallP1([{'a'}, {'b'}, {'c'}], pred, truth), closeTo(0.5, 1e-12));
    });
  });

  group('rethreshold: reetiquetar vínculos con otros umbrales', () {
    final links = [
      Link('a', 'b', const PairScore(0.85, LinkState.same, [], {})),
      Link('c', 'd', const PairScore(0.93, LinkState.same, ['ubicacion_ausente'], {})),
      Link('e', 'f', const PairScore(0.70, LinkState.possible, [], {})),
    ];

    test('un umbral más alto convierte `same` en `possible`; uno más bajo, `possible` en `same`', () {
      final hi = rethreshold(links, 0.90, 0.92);
      expect(hi.map((l) => l.pair.state), [LinkState.possible, LinkState.same, LinkState.possible]);
      final lo = rethreshold(links, 0.65, 0.92);
      expect(lo.map((l) => l.pair.state), [LinkState.same, LinkState.same, LinkState.same]);
    });

    test('sin ubicación se usa su propio umbral', () {
      final r = rethreshold(links, 0.80, 0.95);
      expect(r[1].pair.state, LinkState.possible);
      expect(r[0].pair.state, LinkState.same);
    });

    test('conserva la puntuación, los términos y la incertidumbre', () {
      final r = rethreshold(links, 0.90, 0.92);
      expect(r[1].pair.score, 0.93);
      expect(r[1].pair.uncertainty, ['ubicacion_ausente']);
    });
  });

  group('agrupar re-umbralando vínculos', () {
    test('con los umbrales por defecto coincide con groupObservations sobre un conjunto generado', () {
      final ds = generateDataset(const SynthConfig(seed: 11, incidents: 12, reports: 150, adversarialPairs: 3));
      final obs = [for (final r in ds.reports) r.toObservation()];
      final res = computeLinks(obs);
      final a = groupsAt(obs.map((o) => o.reportKey).toList(), res.links, 0.80, 0.92);
      final b = groupObservations(obs);
      String sig(List<Set<String>> g) => (g.map((x) => (x.toList()..sort()).join(',')).toList()..sort()).join('|');
      expect(sig(a), sig(b));
    });

    test('un umbral más alto nunca agrupa MÁS', () {
      final ds = generateDataset(const SynthConfig(seed: 12, incidents: 12, reports: 150, adversarialPairs: 3));
      final obs = [for (final r in ds.reports) r.toObservation()];
      final res = computeLinks(obs);
      final keys = obs.map((o) => o.reportKey).toList();
      var prev = 1 << 30;
      for (final th in [0.6, 0.7, 0.8, 0.9, 0.97]) {
        final g = groupsAt(keys, res.links, th, th).length;
        expect(g, greaterThanOrEqualTo(prev == 1 << 30 ? 0 : prev), reason: 'θ=$th');
        prev = g;
      }
    });
  });
}
