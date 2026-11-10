import 'dart:async';
import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// T07/T08 con el juez semántico REAL (`bin/t07_modelo.dart`). Aquí se prueba la maquinaria SIN clave: un «oráculo» falso
/// contesta según la verdad (o contesta mal a propósito) y se comprueba que la medición lo cuenta bien, que respeta el
/// tope de gasto y que el informe no filtra los textos.
const int _t0 = 1786370851000;

SynthReport rep(
  String key, {
  required int inc,
  required String? text,
  double? lat = 5.0689,
  double? lon = -75.5174,
  int minutes = 0,
  int type = 2,
  String sourceClass = 'app',
}) => SynthReport(
  reportKey: key,
  deviceId: key.split('-').first,
  incidentType: type,
  flags: 0,
  lat: lat,
  lon: lon,
  locQuality: lat == null ? LocQuality.none : LocQuality.within50m,
  capturedAtMs: _t0 + minutes * 60000,
  text: text,
  sourceClass: sourceClass,
  trueIncident: inc,
  trueUrgency: Urgency.p2,
  subgroup: 'no_p1',
  tags: {if ((text ?? '').isNotEmpty) 'con_texto' else 'sin_texto'},
);

/// Tres sucesos: A (puente, 3 reportes con palabras distintas), B (incendio lejos, 2) y C (un gemelo adversarial de A:
/// cerca y casi a la vez, pero OTRO suceso).
List<SynthReport> fixture() => [
  rep('a1-1', inc: 0, text: 'el puente de la calle veinte se partió', minutes: 0),
  rep('a2-1', inc: 0, text: 'vi caer la mitad del puente cerca', minutes: 2, lat: 5.0690),
  rep('a3-1', inc: 0, text: 'hay carros debajo del puente colapsado', minutes: 4, lat: 5.0689, lon: -75.5175),
  rep('b1-1', inc: 1, text: 'incendio en la fábrica de zapatos', minutes: 1, lat: 5.10, lon: -75.60, type: 3),
  rep('b2-1', inc: 1, text: 'sale humo negro por la fábrica', minutes: 3, lat: 5.1001, lon: -75.6001, type: 3),
  rep('c1-1', inc: 2, text: 'se derrumbó un muro en la panadería', minutes: 3, lat: 5.0691),
  rep('n1-1', inc: 0, text: null, minutes: 5), // sin texto: nunca se juzga
];

T07ModelConfig cfg({double budget = 100, int concurrency = 3, double minConfidence = 0.8, int criterion = 1}) => T07ModelConfig(
  seeds: const [1],
  model: 'claude-sonnet-5-5',
  effort: 'low',
  concurrency: concurrency,
  budgetUsd: budget,
  minConfidence: minConfidence,
  criterion: criterion,
);

/// Contesta por la verdad (`truth`), o a todo «same» / «different»; cuenta las llamadas y mide tokens (1 000 + 500).
class _Oracle implements LlmPort {
  _Oracle(this.incOf, {this.mode = 'truth', this.conf = 0.95, this.inTok = 1000, this.outTok = 500});
  final Map<String, int> incOf;
  final String mode;
  final double conf;
  final int inTok, outTok;
  int calls = 0;
  final List<LlmRequest> requests = [];

  @override
  Future<LlmResult> completeJson(LlmRequest r) async {
    calls++;
    requests.add(r);
    final t = RegExp(r'<reporte_nuevo>\n(.*?)\n</reporte_nuevo>', dotAll: true).firstMatch(r.user)![1]!;
    final cs = [for (final m in RegExp(r'<candidato>\n(.*?)\n</candidato>', dotAll: true).allMatches(r.user)) m[1]!];
    final items = <Map<String, Object?>>[];
    for (var i = 0; i < cs.length; i++) {
      final same = mode == 'same' || (mode == 'truth' && incOf[cs[i]] == incOf[t]);
      final verdict = mode == 'possible' ? 'possible' : (same ? 'same' : 'different');
      final cites = verdict != 'different';
      items.add({
        'candidate': i + 1,
        'verdict': verdict,
        'confidence': conf,
        'quote_new': cites ? t.substring(0, 5) : '',
        'quote_candidate': cites ? cs[i].substring(0, 5) : '',
      });
    }
    return LlmResult(text: jsonEncode({'judgments': items}), stopReason: 'end_turn', inputTokens: inTok, outputTokens: outTok, requestId: 'req_$calls');
  }
}

class _Fail implements LlmPort {
  _Fail(this.res);
  final LlmResult res;
  @override
  Future<LlmResult> completeJson(LlmRequest r) async => res;
}

Map<String, int> textToIncident(List<SynthReport> rs) => {for (final r in rs) if (r.text != null) r.text!: r.trueIncident};

void main() {
  group('planJudgeJobs', () {
    test('un trabajo por reporte CON texto que tenga candidatos, en orden cronológico, y sólo contra los ANTERIORES', () {
      final jobs = planJudgeJobs([T07Dataset('s1', 'synth', fixture())], k: 6);
      final targets = jobs.map((j) => j.target.reportKey).toList();
      expect(targets.contains('n1-1'), isFalse, reason: 'sin texto no se juzga');
      expect(targets.contains('a1-1'), isFalse, reason: 'el primero no tiene anteriores');
      for (final j in jobs) {
        for (final c in j.candidates) {
          expect(c.capturedAtMs, lessThanOrEqualTo(j.target.capturedAtMs), reason: 'sólo anteriores');
        }
        expect(j.candidates.length, lessThanOrEqualTo(6));
        expect(j.candidates, isNotEmpty);
      }
      final order = [for (final j in jobs) j.target.capturedAtMs];
      expect(order, [...order]..sort());
    });

    test('NO depende del orden de entrada de los reportes', () {
      final a = planJudgeJobs([T07Dataset('s1', 'synth', fixture())], k: 6);
      final b = planJudgeJobs([T07Dataset('s1', 'synth', fixture().reversed.toList())], k: 6);
      List<String> sig(List<JudgeJob> js) => [for (final j in js) '${j.target.reportKey}:${j.candidates.map((c) => c.reportKey).join(',')}'];
      expect(sig(a), sig(b));
    });

    test('los candidatos respetan las reglas duras: B (lejos, otro tipo) no es candidato de A ni al revés', () {
      final jobs = planJudgeJobs([T07Dataset('s1', 'synth', fixture())], k: 6);
      for (final j in jobs) {
        final inc = {'a': 0, 'b': 1};
        final t = j.target.reportKey[0];
        if (t == 'b') expect(j.candidates.every((c) => c.reportKey[0] == 'b'), isTrue);
        if (t == 'a') expect(j.candidates.any((c) => c.reportKey[0] == 'b'), isFalse);
        expect(inc, isNotEmpty);
      }
    });

    test('los escenarios de T08 van PRIMERO en la cola (un tope de gasto no puede dejarlos sin medir)', () {
      final data = [
        T07Dataset('s1', 'synth', fixture()),
        T07Dataset('corro', 'corroboracion', generateCorroboration(sources: 5, seed: 1)),
        T07Dataset('rum', 'rumor', generateRumor(copies: 4, sources: 2, seed: 1)),
      ];
      final kinds = [for (final j in planJudgeJobs(data, k: 6)) j.dataset == 's1' ? 'synth' : 'esc'];
      final firstSynth = kinds.indexOf('synth');
      expect(firstSynth, greaterThan(0));
      expect(kinds.sublist(0, firstSynth).every((k) => k == 'esc'), isTrue);
      expect(kinds.sublist(firstSynth).every((k) => k == 'synth'), isTrue);
      expect(kinds.where((k) => k == 'esc').length, 4 + 3, reason: '4 de la corroboración (5 reportes) y 3 del rumor (4 copias)');
    });

    test('varios conjuntos NO se mezclan', () {
      final x = fixture();
      final jobs = planJudgeJobs([T07Dataset('s1', 'synth', x), T07Dataset('s2', 'synth', x)], k: 6);
      expect(jobs.where((j) => j.dataset == 's1').length, jobs.where((j) => j.dataset == 's2').length);
      for (final j in jobs) {
        expect(j.candidates.length, lessThanOrEqualTo(4), reason: 'cada conjunto sólo tiene 6 con texto: no se ven los del otro');
      }
    });
  });

  group('t07Datasets', () {
    test('por semilla: un conjunto sintético, una corroboración y un rumor, con los tamaños de la configuración', () {
      final c = T07ModelConfig(seeds: const [11, 12], model: 'claude-sonnet-5-5', effort: 'low', concurrency: 1, budgetUsd: 1, incidents: 10, reports: 80, adversarialPairs: 2, corroborationSources: 4, rumorCopies: 7, rumorSources: 2);
      final ds = t07Datasets(c);
      expect([for (final d in ds) d.label], ['semilla-11', 'corroboracion-11', 'rumor-11', 'semilla-12', 'corroboracion-12', 'rumor-12']);
      expect([for (final d in ds.take(3)) d.kind], ['synth', 'corroboracion', 'rumor']);
      expect(ds[1].reports.length, 4);
      expect(ds[2].reports.length, 7);
      expect(ds[2].reports.map((r) => r.deviceId).toSet().length, 2);
      expect(ds[0].reports.map((r) => r.trueIncident).where((i) => i >= 0).toSet().length, lessThanOrEqualTo(12));
      expect(ds[0].reports.length, inInclusiveRange(60, 140));
      expect(ds[0].reports.first.reportKey, isNot(ds[3].reports.first.reportKey), reason: 'cada semilla genera sus propios reportes');
    });
  });

  group('runT07Model con un oráculo que contesta por la verdad', () {
    final data = [T07Dataset('s1', 'synth', fixture())];

    Future<(T07ModelResult, T07Eval)> run(LlmPort port, {T07ModelConfig? c}) async {
      final res = await runT07Model(c ?? cfg(), port, datasets: data);
      return (res, evalT07(data, res.records, minConfidence: (c ?? cfg()).minConfidence));
    }

    test('el modelo agrupa lo que las reglas dejaban suelto (otras palabras) SIN falsa fusión', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      expect(ev.rules.recall, lessThan(1), reason: 'precondición: las reglas solas no unen las paráfrasis');
      expect(ev.withModel.recall, greaterThan(ev.rules.recall));
      expect(ev.withModel.falseMergeRate, 0);
      expect(ev.withModel.mixedGroups, 0);
      expect(ev.withModel.groups, lessThan(ev.rules.groups));
    });

    test('el gemelo adversarial (cerca y a la vez, otro suceso) NO se une con un oráculo que lo ve', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      final g = ev.groupsOf('s1', ev.modelLinks['s1']!, ev.modelUnlinked['s1']!);
      expect(g.any((s) => s.contains('c1-1') && s.length > 1), isFalse);
    });

    test('un juez que dice «same» a TODO se ve en la medición (falsa fusión > 0), pero las reglas duras siguen a salvo', () async {
      final (_, ev) = await run(_Oracle(const {}, mode: 'same'));
      expect(ev.withModel.falseMergeRate, greaterThan(0), reason: 'la medición tiene que ver a un juez que une de más');
      expect(ev.unions.total, greaterThan(0));
      expect(ev.unions.correct, lessThan(ev.unions.total), reason: 'unió pares de sucesos distintos (A con su gemelo C)');
      expect(ev.judgments.sameWhenDifferent, greaterThan(0));
      final g = ev.groupsOf('s1', ev.modelLinks['s1']!, ev.modelUnlinked['s1']!);
      expect(g.any((s) => s.contains('b1-1') && s.contains('a1-1')), isFalse, reason: 'B está lejos y es de otro tipo: nunca se une con A');
    });

    test('un juez que dice «different» a todo: con veto parte lo que las reglas unían; sin veto no', () async {
      final texto = 'edificio caído en la carrera 23 con calle 10, hay heridos';
      final dup = [
        T07Dataset('s1', 'synth', [rep('p1-1', inc: 0, text: texto), rep('q1-1', inc: 0, text: texto, minutes: 2)]),
      ];
      final res = await runT07Model(cfg(), _Oracle(const {}, mode: 'different'), datasets: dup);
      final ev = evalT07(dup, res.records, minConfidence: 0.8);
      expect(ev.rules.groups, 1, reason: 'precondición: las reglas unen dos textos idénticos');
      expect(ev.withModel.groups, 2, reason: 'con veto el modelo los separa');
      expect(ev.withModelNoVeto.groups, 1);
      expect(ev.vetoes.total, 1);
      expect(ev.vetoes.harmful, 1, reason: 'eran del mismo suceso: un veto malo');
    });

    test('mide la evidencia disponible: de los pares verdaderos con texto en los dos, cuántos comparten la calle escrita y cuántos alguna palabra', () async {
      final rs = [
        rep('e1-1', inc: 0, text: 'carrera 16 con calle 39, hay heridos'),
        rep('e2-1', inc: 0, text: 'nadie herido, carrera 16 con calle 39', minutes: 1),
        rep('e3-1', inc: 0, text: 'mucha sangre', minutes: 2),
        rep('e5-1', inc: 0, text: 'carrera 16 con calle 40', minutes: 3), // misma carrera, OTRA calle
        rep('e6-1', inc: 0, text: 'sangre por todos lados', minutes: 3),
        rep('e7-1', inc: 0, text: null, minutes: 4), // sin texto: sus pares no se cuentan
        rep('e4-1', inc: 1, text: 'carrera 16 con calle 39, humo', minutes: 2, lat: 5.10, lon: -75.60), // otro suceso con la MISMA calle: no es par verdadero
      ];
      final d = [T07Dataset('s1', 'synth', rs)];
      final ev = evalT07(d, const [], minConfidence: 0.8);
      expect(ev.textPairs, 10, reason: '5 reportes con texto del suceso 0 → 10 pares; e7 no tiene texto');
      expect(ev.textPairsSharingStreet, 1, reason: 'sólo e1–e2 escriben la misma calle (e5 es la calle 40)');
      expect(ev.textPairsSharingWord, 4, reason: 'e1–e2, e1–e5, e2–e5 (carrera/calle) y e3–e6 (sangre)');
    });

    test('una unión que las reglas YA hacían no se cuenta como del modelo', () async {
      final texto = 'edificio caído en la carrera 23 con calle 10, hay heridos';
      final dup = [
        T07Dataset('s1', 'synth', [rep('p1-1', inc: 0, text: texto), rep('q1-1', inc: 0, text: texto, minutes: 2)]),
      ];
      final res = await runT07Model(cfg(), _Oracle({texto: 0}), datasets: dup);
      final ev = evalT07(dup, res.records, minConfidence: 0.8);
      expect(ev.rules.groups, 1, reason: 'precondición: las reglas ya los unen');
      expect(ev.unions.total, 0);
    });

    test('dos rumores (verdad −1) que un juez une NO cuentan como «mismo suceso»: no hay suceso', () async {
      final rs = [
        rep('r1-1', inc: -1, text: 'dicen por la radio que cayó el puente', sourceClass: 'radio'),
        rep('r2-1', inc: -1, text: 'por la radio dicen que se cayó el puente', minutes: 1, sourceClass: 'radio'),
      ];
      final d = [T07Dataset('s1', 'synth', rs)];
      final res = await runT07Model(cfg(), _Oracle(const {}, mode: 'same'), datasets: d);
      final ev = evalT07(d, res.records, minConfidence: 0.8);
      expect(ev.judgments.total, greaterThan(0));
      expect(ev.judgments.sameWhenSame, 0);
      expect(ev.judgments.sameWhenDifferent, ev.judgments.total);
    });

    test('la matriz distingue «different» de «possible» y cada una según la verdad', () async {
      final (_, evD) = await run(_Oracle(const {}, mode: 'different'));
      expect(evD.judgments.differentWhenSame, greaterThan(0), reason: 'dijo «different» a pares del mismo suceso');
      expect(evD.judgments.differentWhenDifferent, greaterThan(0));
      expect(evD.judgments.sameWhenSame + evD.judgments.sameWhenDifferent + evD.judgments.possibleWhenSame + evD.judgments.possibleWhenDifferent, 0);
      final (_, evP) = await run(_Oracle(textToIncident(fixture()), mode: 'possible'));
      expect(evP.judgments.possibleWhenSame, greaterThan(0));
      expect(evP.judgments.possibleWhenDifferent, greaterThan(0));
      expect(evP.judgments.sameWhenSame + evP.judgments.differentWhenSame + evP.judgments.differentWhenDifferent, 0);
      expect(evP.withModel.groups, evP.rules.groups, reason: '«possible» no une');
      expect(evP.judgments.total, evP.judgments.possibleWhenSame + evP.judgments.possibleWhenDifferent, reason: 'el total cuenta todas las casillas');
    });

    test('mide por separado lo que el modelo UNE (y si acertó) y lo que VETA', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      expect(ev.unions.total, greaterThan(0));
      expect(ev.unions.correct, ev.unions.total, reason: 'el oráculo nunca une de más');
      expect(ev.vetoes.harmful, 0);
    });

    test('la matriz del juez: veredicto × verdad, sobre los juicios hechos', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      expect(ev.judgments.sameWhenSame, greaterThan(0));
      expect(ev.judgments.sameWhenDifferent, 0);
      expect(ev.judgments.differentWhenSame, 0);
      expect(ev.judgments.differentWhenDifferent, greaterThan(0));
      expect(ev.judgments.total, ev.judgments.sameWhenSame + ev.judgments.sameWhenDifferent + ev.judgments.possibleWhenSame + ev.judgments.possibleWhenDifferent + ev.judgments.differentWhenSame + ev.judgments.differentWhenDifferent);
    });

    test('lleva el gasto, los tokens, las llamadas y el id de petición de cada una', () async {
      final o = _Oracle(textToIncident(fixture()));
      final (res, _) = await run(o);
      expect(res.records.length, o.calls);
      expect(res.spentUsd, closeTo(o.calls * 0.007, 1e-9), reason: '1 000 de entrada a 2 USD + 500 de salida a 10 USD por millón');
      expect(res.records.every((r) => r.requestId != null && r.inputTokens == 1000 && r.outputTokens == 500), isTrue);
      expect(res.stoppedByBudget, isFalse);
      expect(res.fallbacks, isEmpty);
    });

    test('el tope de gasto es DURO: con 1 ¢ no pasa de una llamada y lo dice', () async {
      final o = _Oracle(textToIncident(fixture()));
      final (res, _) = await run(o, c: cfg(budget: 0.01, concurrency: 1));
      expect(o.calls, 1);
      expect(res.spentUsd, lessThanOrEqualTo(0.01));
      expect(res.stoppedByBudget, isTrue);
      expect(res.skipped, greaterThan(0));
    });

    test('con varias llamadas a la vez el tope tampoco se pasa (el gasto en vuelo cuenta)', () async {
      final o = _Oracle(textToIncident(fixture()));
      final (res, _) = await run(o, c: cfg(budget: 0.02, concurrency: 5));
      expect(res.spentUsd, lessThanOrEqualTo(0.02));
      expect(o.calls, lessThanOrEqualTo(2));
    });

    test('el tope usa lo que COSTÓ de verdad cada llamada, no sólo el supuesto inicial (3 000+1 500 tokens = 0,021 USD)', () async {
      final o = _Oracle(textToIncident(fixture()), inTok: 3000, outTok: 1500);
      final (res, _) = await run(o, c: cfg(budget: 0.05, concurrency: 1));
      expect(o.calls, 2, reason: 'tras la primera se sabe que cada una cuesta 0,021: una tercera pasaría de 0,05');
      expect(res.spentUsd, closeTo(0.042, 1e-9));
      expect(res.stoppedByBudget, isTrue);
    });

    test('un juez con confianza BAJA (0,5) no cambia nada y la matriz «confiada» queda vacía', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture()), conf: 0.5));
      expect(ev.judgments.total, greaterThan(0));
      expect(ev.judgmentsConfident.total, 0);
      expect(ev.withModel.groups, ev.rules.groups);
      expect(ev.unions.total, 0);
    });

    test('la matriz «confiada» cuenta lo mismo que la total cuando toda la confianza es alta', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      expect(ev.judgmentsConfident.total, ev.judgments.total);
      expect(ev.judgmentsConfident.sameWhenSame, ev.judgments.sameWhenSame);
    });

    test('un veto sobre un par que las reglas NO unían no cuenta como veto de unión (pero el par queda en unlinked)', () async {
      final (_, ev) = await run(_Oracle(const {}, mode: 'different'));
      expect(ev.modelUnlinked['s1'], isNotEmpty);
      expect(ev.vetoes.total, 0, reason: 'las reglas no tenían ningún «same» en esta fixture: no hubo unión que cortar');
    });

    test('la cobertura de pares cuenta los verdaderos (7) y los que tienen texto en los dos (4)', () async {
      final (_, ev) = await run(_Oracle(textToIncident(fixture())));
      expect(ev.coverageRules.truePairs, 7);
      expect(ev.coverageRulesText.truePairs, 4);
      expect(ev.coverageModelText.recallGrouped, greaterThan(ev.coverageRulesText.recallGrouped));
    });

    test('con DOS conjuntos las métricas se SUMAN (mismos datos dos veces = el doble de pares)', () async {
      final dos = [T07Dataset('s1', 'synth', fixture()), T07Dataset('s2', 'synth', fixture())];
      final res = await runT07Model(cfg(), _Oracle(textToIncident(fixture())), datasets: dos);
      final ev2 = evalT07(dos, res.records, minConfidence: 0.8);
      final ev1 = evalT07(data, res.records.where((r) => r.dataset == 's1').toList(), minConfidence: 0.8);
      expect(ev2.withModel.tp, 2 * ev1.withModel.tp);
      expect(ev2.rules.groups, 2 * ev1.rules.groups);
      expect(ev2.coverageRules.truePairs, 2 * ev1.coverageRules.truePairs);
      expect(ev2.unions.total, 2 * ev1.unions.total);
      expect(ev2.judgments.total, 2 * ev1.judgments.total);
    });

    test('si el modelo FALLA siempre, la medición cuenta cada causa y el resultado es el de las reglas', () async {
      final (res, ev) = await run(_Fail(const LlmResult(timedOut: true)));
      expect(res.fallbacks['plazo_agotado'], res.records.length);
      expect(ev.withModel.recall, ev.rules.recall);
      expect(ev.withModel.groups, ev.rules.groups);
      expect(ev.judgments.total, 0);
    });

    test('un modelo que contesta basura se cuenta como «salida_invalida» y no cambia nada', () async {
      final (res, ev) = await run(_Fail(const LlmResult(text: 'claro que sí', stopReason: 'end_turn')));
      expect(res.fallbacks['salida_invalida'], res.records.length);
      expect(ev.withModel.groups, ev.rules.groups);
    });
  });

  group('T08 con el juez: corroboración y rumor', () {
    test('5 fuentes independientes con palabras propias forman UN grupo con 5 fuentes, y la confianza sube', () async {
      final corro = generateCorroboration(sources: 5, seed: 1);
      final data = [T07Dataset('corroboracion-1', 'corroboracion', corro)];
      final res = await runT07Model(cfg(), _Oracle(textToIncident(corro)), datasets: data);
      final ev = evalT07(data, res.records, minConfidence: 0.8);
      final s = ev.scenarios.single;
      expect(s.rulesGroups, greaterThan(1), reason: 'precondición: las reglas solas no las agrupan');
      expect(s.modelGroups, 1);
      expect(s.modelIndependentSources, 5);
      expect(s.modelConfidence, greaterThan(s.rulesConfidence));
    });

    test('un rumor repetido NO gana credibilidad por tener más copias: las fuentes siguen contándose por familias', () async {
      final rumor = generateRumor(copies: 12, sources: 3, seed: 1);
      final data = [T07Dataset('rumor-1', 'rumor', rumor)];
      final res = await runT07Model(cfg(), _Oracle(textToIncident(rumor), mode: 'same'), datasets: data);
      final s = evalT07(data, res.records, minConfidence: 0.8).scenarios.single;
      expect(s.modelIndependentSources, lessThanOrEqualTo(3));
      expect(s.modelConfidence, lessThan(0.8));
    });

    test('el escenario mide el MAYOR grupo, no uno cualquiera', () async {
      final rs = [
        rep('x1-1', inc: 0, text: 'el puente de la calle veinte se partió', minutes: 0),
        rep('x2-1', inc: 0, text: 'vi caer la mitad del puente cerca', minutes: 2),
        rep('x3-1', inc: 0, text: 'hay carros debajo del puente colapsado', minutes: 4),
        rep('y1-1', inc: 1, text: 'incendio en la fábrica de zapatos', minutes: 1, lat: 5.10, lon: -75.60, type: 3),
      ];
      final data = [T07Dataset('corroboracion-x', 'corroboracion', rs)];
      final res = await runT07Model(cfg(), _Oracle(textToIncident(rs)), datasets: data);
      final s = evalT07(data, res.records, minConfidence: 0.8).scenarios.single;
      expect(s.modelGroups, 2);
      expect(s.modelIndependentSources, 3, reason: 'el grupo de 3 fuentes, no el de 1');
    });

    test('los escenarios no entran en las métricas de pares de T07 (sólo los conjuntos «synth»)', () async {
      final corro = generateCorroboration(sources: 5, seed: 1);
      final data = [T07Dataset('s1', 'synth', fixture()), T07Dataset('corroboracion-1', 'corroboracion', corro)];
      final res = await runT07Model(cfg(), _Oracle({...textToIncident(fixture()), ...textToIncident(corro)}), datasets: data);
      final ev = evalT07(data, res.records, minConfidence: 0.8);
      final solo = evalT07([data.first], res.records.where((r) => r.dataset == 's1').toList(), minConfidence: 0.8);
      expect(ev.withModel.tp, solo.withModel.tp);
      expect(ev.withModel.groups, solo.withModel.groups);
      expect(ev.scenarios.length, 1);
    });
  });

  group('decideT07V2: el criterio de la ronda 2 (escrito y commiteado antes de gastar)', () {
    final fx = fixture();
    final corro = generateCorroboration(sources: 5, seed: 1);
    final rumor = generateRumor(copies: 6, sources: 2, seed: 1);
    final data = [T07Dataset('s1', 'synth', fx), T07Dataset('corroboracion-1', 'corroboracion', corro), T07Dataset('rumor-1', 'rumor', rumor)];
    final truth = {...textToIncident(fx), ...textToIncident(corro), ...textToIncident(rumor)};

    JudgeRecord rec({String? reason, int latencyMs = 100}) => JudgeRecord(
      dataset: 's1', targetKey: 't', candidateKeys: const [], judgments: const [], reason: reason, latencyMs: latencyMs, inputTokens: 1, outputTokens: 1, costUsd: 0, requestId: null,
    );

    /// Una evaluación que CUMPLE todo en v2 (se rompe una condición a la vez): reglas 1 % de recall y 0 % de falsa fusión, modelo +2 puntos
    /// y 0 %, 120 uniones todas buenas, y el rumor sin ganancia indebida.
    Future<(List<JudgeRecord>, T07Eval)> passing() async {
      final res = await runT07Model(cfg(), _Oracle(truth), datasets: data);
      final ev = evalT07(data, res.records, minConfidence: 0.85);
      ev.rules = PairMetrics(100, 0, 9900, 1, 0);
      ev.withModel = PairMetrics(300, 0, 9700, 1, 0);
      ev.unions
        ..total = 120
        ..correct = 120;
      ev.scenarios
        ..clear()
        ..add(T08Row(label: 'r', kind: 'rumor', reports: 12, rulesGroups: 1, modelGroups: 1, rulesIndependentSources: 1, modelIndependentSources: 1, rulesConfidence: 0.2, modelConfidence: 0.2));
      return ([for (var i = 0; i < 20; i++) rec()], ev);
    }

    bool met(T07VerdictV2 v, String id) => v.lines.singleWhere((l) => l.id == id).met;

    test('todo cumplido: se adopta (como opción apagada por omisión) y no hay veto', () async {
      final (recs, ev) = await passing();
      final v = decideT07V2(ev, recs, cfg());
      for (final l in v.lines) {
        expect(l.met, isTrue, reason: '${l.id}: ${l.description} → ${l.value}');
      }
      expect((v.adopt, v.inconclusive), (true, false));
      expect(v.conclusion, contains('Se adopta'));
    });

    test('falla si la falsa fusión supera 1 % aunque el recall suba mucho', () async {
      final (recs, ev) = await passing();
      ev.rules = PairMetrics(100, 0, 9900, 1, 0);
      ev.withModel = PairMetrics(980, 20, 9020, 1, 0); // 2 % de falsa fusión y +9 puntos de recall
      final v = decideT07V2(ev, recs, cfg());
      expect((v.adopt, met(v, '1'), met(v, '3')), (false, false, true));
      expect(v.conclusion, contains('NO se adopta'));
      expect(v.conclusion, contains('no se hace una tercera ronda'));
      // el tope de 1 % es absoluto: unas reglas que ya fusionan mal (1,8 %) no dan permiso para 1,9 % aunque estén dentro de +0,5 puntos
      ev.rules = PairMetrics(982, 18, 9000, 1, 0);
      ev.withModel = PairMetrics(981, 19, 9000, 1, 0);
      expect(met(decideT07V2(ev, recs, cfg()), '1'), isFalse);
      // y una falsa fusión que falla NO se disfraza de «no concluyente» aunque haya pocas uniones
      ev.rules = PairMetrics(100, 0, 9900, 1, 0);
      ev.withModel = PairMetrics(980, 20, 9020, 1, 0);
      ev.unions
        ..total = 99
        ..correct = 99;
      final few = decideT07V2(ev, recs, cfg());
      expect((few.inconclusive, few.adopt), (false, false));
    });

    test('falla si supera a las reglas en más de 0,5 puntos aunque quede bajo 1 %', () async {
      final (recs, ev) = await passing();
      ev.rules = PairMetrics(1000, 4, 9000, 1, 0); // 0,4 %
      ev.withModel = PairMetrics(1986, 14, 8000, 1, 0); // 0,7 %: ≤ 1 % pero 0,3 puntos sobre las reglas: pasa
      expect(met(decideT07V2(ev, recs, cfg()), '1'), isTrue);
      ev.withModel = PairMetrics(1982, 18, 8000, 1, 0); // 0,9 %: ≤ 1 % pero 0,5 puntos justos y medio: no pasa
      expect(met(decideT07V2(ev, recs, cfg()), '1'), isFalse);
    });

    test('no concluyente con menos de 100 uniones (aunque todas sean buenas); con 100 ya cuenta', () async {
      final (recs, ev) = await passing();
      ev.unions
        ..total = 99
        ..correct = 99;
      var v = decideT07V2(ev, recs, cfg());
      expect((v.adopt, v.inconclusive, met(v, '2')), (false, true, false));
      expect(v.conclusion, contains('No concluyente'));
      ev.unions
        ..total = 100
        ..correct = 100;
      v = decideT07V2(ev, recs, cfg());
      expect((v.adopt, v.inconclusive), (true, false));
    });

    test('la precisión de las uniones sigue exigiendo ≥ 95 %: con 100 uniones, 95 pasan y 94 no (y entonces NO es «no concluyente»)', () async {
      final (recs, ev) = await passing();
      ev.unions
        ..total = 100
        ..correct = 95;
      expect(met(decideT07V2(ev, recs, cfg()), '2'), isTrue);
      ev.unions.correct = 94;
      final v = decideT07V2(ev, recs, cfg());
      expect((met(v, '2'), v.inconclusive, v.adopt), (false, false, false));
    });

    test('el recall exige +1,5 puntos sobre las reglas (ya no «+5 y el doble»)', () async {
      final (recs, ev) = await passing();
      ev.rules = PairMetrics(100, 0, 9900, 1, 0); // 1 %
      ev.withModel = PairMetrics(250, 0, 9750, 1, 0); // 2,5 %: +1,5 puntos justos
      expect((met(decideT07V2(ev, recs, cfg()), '3'), decideT07V2(ev, recs, cfg()).adopt), (true, true));
      ev.withModel = PairMetrics(249, 0, 9751, 1, 0); // 2,49 %
      expect((met(decideT07V2(ev, recs, cfg()), '3'), decideT07V2(ev, recs, cfg()).adopt), (false, false), reason: 'con SÓLO el recall roto no se adopta');
      ev.rules = PairMetrics(1000, 0, 9000, 1, 0); // 10 %
      ev.withModel = PairMetrics(1150, 0, 8850, 1, 0); // 11,5 %: +1,5 puntos aunque sólo ×1,15 (no hay «el doble»)
      expect(met(decideT07V2(ev, recs, cfg()), '3'), isTrue);
    });

    test('un rumor que gana fuentes independientes o pasa de 0,8 de confianza impide la adopción', () async {
      final (recs, ev) = await passing();
      T08Row rumorRow({int sources = 1, double conf = 0.2}) => T08Row(
        label: 'r', kind: 'rumor', reports: 12, rulesGroups: 1, modelGroups: 1, rulesIndependentSources: 1, modelIndependentSources: sources, rulesConfidence: 0.2, modelConfidence: conf,
      );
      ev.scenarios
        ..clear()
        ..add(rumorRow(sources: cfg().rumorSources + 1));
      expect((decideT07V2(ev, recs, cfg()).adopt, met(decideT07V2(ev, recs, cfg()), '6')), (false, false));
      ev.scenarios
        ..clear()
        ..add(rumorRow(conf: 0.81));
      expect(met(decideT07V2(ev, recs, cfg()), '6'), isFalse);
    });

    test('el criterio de las 5 fuentes YA NO cuenta: no formar el grupo de 5 no impide adoptar, y no figura entre los criterios', () async {
      final (recs, ev) = await passing();
      ev.scenarios.add(T08Row(
        label: 'c', kind: 'corroboracion', reports: 5, rulesGroups: 5, modelGroups: 3, rulesIndependentSources: 1, modelIndependentSources: 2, rulesConfidence: 0.6, modelConfidence: 0.6,
      ));
      final v = decideT07V2(ev, recs, cfg());
      expect(v.adopt, isTrue);
      expect(v.lines.map((l) => l.id), ['1', '2', '4', '3', '6'], reason: 'el 5 se retiró');
    });

    test('la fiabilidad (4) se mantiene: más de un 5 % de fallos impide adoptar', () async {
      final (_, ev) = await passing();
      final bad = [for (var i = 0; i < 20; i++) rec(reason: i < 2 ? 'plazo_agotado' : null)];
      expect((decideT07V2(ev, bad, cfg()).adopt, met(decideT07V2(ev, bad, cfg()), '4')), (false, false));
    });

    test('el texto de la regla v2 dice que se reescribió tras ver la ronda 1', () {
      final rule = kT07DecisionRuleV2.toLowerCase();
      expect(rule, contains('reescrito'));
      expect(rule, contains('ronda 1'));
      expect(rule, contains('evidencia más débil'));
    });
  });

  group('decideT07: el criterio se aplica mecánicamente', () {
    final fx = fixture();
    final corro = generateCorroboration(sources: 5, seed: 1);
    final rumor = generateRumor(copies: 6, sources: 2, seed: 1);
    final data = [T07Dataset('s1', 'synth', fx), T07Dataset('corroboracion-1', 'corroboracion', corro), T07Dataset('rumor-1', 'rumor', rumor)];
    final truth = {...textToIncident(fx), ...textToIncident(corro), ...textToIncident(rumor)};

    Future<(T07ModelResult, T07Eval)> run(LlmPort port) async {
      final res = await runT07Model(cfg(), port, datasets: data);
      return (res, evalT07(data, res.records, minConfidence: 0.8));
    }

    bool met(T07Verdict v, String id) => v.lines.singleWhere((l) => l.id == id).met;

    JudgeRecord rec({String? reason, int latencyMs = 100}) => JudgeRecord(
      dataset: 's1', targetKey: 't', candidateKeys: const [], judgments: const [], reason: reason, latencyMs: latencyMs, inputTokens: 1, outputTokens: 1, costUsd: 0, requestId: null,
    );

    test('un oráculo perfecto cumple los dos niveles; sin vetos no hay evidencia para que el nodo vete', () async {
      final (res, ev) = await run(_Oracle(truth));
      final v = decideT07(ev, res.records, cfg());
      for (final l in v.lines) {
        expect(l.met, isTrue, reason: '${l.id}: ${l.description} → ${l.value}');
      }
      expect(v.offerAsOption, isTrue);
      expect(v.recommend, isTrue);
      expect(v.allowVeto, isFalse, reason: 'sin vetos medidos no se sabe si vetar es seguro');
      expect(v.conclusion, contains('se recomienda'));
    });

    test('un juez que dice «same» a todo NO cumple la seguridad: ni se ofrece', () async {
      final (res, ev) = await run(_Oracle(const {}, mode: 'same'));
      final v = decideT07(ev, res.records, cfg());
      expect(v.offerAsOption, isFalse);
      expect(v.recommend, isFalse);
      expect(met(v, '1') && met(v, '2'), isFalse);
      expect(v.conclusion, contains('NO se ofrece'));
    });

    test('un modelo que siempre falla no cumple la fiabilidad (4)', () async {
      final (res, ev) = await run(_Fail(const LlmResult(timedOut: true)));
      final v = decideT07(ev, res.records, cfg());
      expect(met(v, '4'), isFalse);
      expect(v.offerAsOption, isFalse);
    });

    test('seguro pero SIN ganancia: opción disponible, apagada, «sin ganancia demostrada»', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.withModel = ev.rules; // el modelo no mejoró nada
      final v = decideT07(ev, res.records, cfg());
      expect(v.offerAsOption, isTrue);
      expect(v.recommend, isFalse);
      expect(met(v, '3'), isFalse);
      expect(v.conclusion, contains('sin ganancia demostrada'));
      expect(v.conclusion, contains('no (3)'), reason: 'dice exactamente qué criterio falta');
    });

    test('(1) falsa fusión: ≤ 1 % y ≤ la de las reglas + 0,5 puntos', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.rules = PairMetrics(1000, 0, 0, 1, 0);
      ev.withModel = PairMetrics(99, 1, 0, 1, 0);
      expect(met(decideT07(ev, res.records, cfg()), '1'), isFalse, reason: '1 % cuando las reglas tienen 0 %: pasa +0,5 puntos');
      ev.rules = PairMetrics(100, 1, 0, 1, 0); // ≈ 0,99 %
      ev.withModel = PairMetrics(99, 1, 0, 1, 0); // 1 %
      expect(met(decideT07(ev, res.records, cfg()), '1'), isTrue);
      ev.withModel = PairMetrics(98, 2, 0, 1, 0); // 2 %
      expect(met(decideT07(ev, res.records, cfg()), '1'), isFalse);
      ev.rules = PairMetrics(1000, 0, 0, 1, 0);
      ev.withModel = PairMetrics(992, 8, 0, 1, 0); // 0,8 %: bajo 1 % pero > 0 + 0,5
      expect(met(decideT07(ev, res.records, cfg()), '1'), isFalse);
      ev.withModel = PairMetrics(996, 4, 0, 1, 0); // 0,4 %
      expect(met(decideT07(ev, res.records, cfg()), '1'), isTrue);
      ev.withModel = PairMetrics(9945, 55, 0, 1, 0); // 0,55 %: pasa 0 + 0,5 puntos
      expect(met(decideT07(ev, res.records, cfg()), '1'), isFalse);
      ev.withModel = PairMetrics(9955, 45, 0, 1, 0); // 0,45 %
      expect(met(decideT07(ev, res.records, cfg()), '1'), isTrue);
    });

    test('(2) precisión de las uniones ≥ 95 %; sin uniones no hay nada demostrado', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.unions
        ..total = 20
        ..correct = 19;
      expect(met(decideT07(ev, res.records, cfg()), '2'), isTrue);
      ev.unions.correct = 18;
      expect(met(decideT07(ev, res.records, cfg()), '2'), isFalse);
      ev.unions
        ..total = 0
        ..correct = 0;
      expect(met(decideT07(ev, res.records, cfg()), '2'), isFalse);
    });

    test('(4) fiabilidad: fallos ≤ 5 % de las llamadas y llamadas de más de 8 s ≤ 5 % de las útiles', () async {
      final (_, ev) = await run(_Oracle(truth));
      List<JudgeRecord> recs({int fail = 0, int slow = 0, int total = 20}) => [
        for (var i = 0; i < total; i++) rec(reason: i < fail ? 'plazo_agotado' : null, latencyMs: i >= total - slow ? 8001 : 8000),
      ];
      expect(met(decideT07(ev, recs(fail: 1), cfg()), '4'), isTrue);
      expect(met(decideT07(ev, recs(fail: 2), cfg()), '4'), isFalse);
      expect(met(decideT07(ev, recs(slow: 1), cfg()), '4'), isTrue, reason: '8 000 ms no pasa de 8 s; 8 001 sí');
      expect(met(decideT07(ev, recs(slow: 2), cfg()), '4'), isFalse);
      expect(met(decideT07(ev, recs(fail: 1, slow: 1), cfg()), '4'), isFalse, reason: '1 lenta de 19 útiles es 5,3 %: se mide sobre las útiles, no sobre todas');
      expect(met(decideT07(ev, const [], cfg()), '4'), isFalse, reason: 'sin llamadas no hay fiabilidad demostrada');
    });

    test('(3) ganancia de recall: al menos 5 puntos Y al menos el doble', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.rules = PairMetrics(2, 0, 98, 1, 0); // 2 %
      ev.withModel = PairMetrics(7, 0, 93, 1, 0); // 7 %
      expect(met(decideT07(ev, res.records, cfg()), '3'), isTrue);
      ev.withModel = PairMetrics(6, 0, 94, 1, 0); // 6 %: sólo +4 puntos
      expect(met(decideT07(ev, res.records, cfg()), '3'), isFalse);
      ev.rules = PairMetrics(4, 0, 196, 1, 0); // 2 %
      ev.withModel = PairMetrics(13, 0, 187, 1, 0); // 6,5 %: +4,5 puntos
      expect(met(decideT07(ev, res.records, cfg()), '3'), isFalse);
      ev.rules = PairMetrics(1, 0, 99, 1, 0); // 1 %
      ev.withModel = PairMetrics(6, 0, 94, 1, 0); // 6 %: +5 puntos justos (con el redondeo de coma flotante)
      expect(met(decideT07(ev, res.records, cfg()), '3'), isTrue);
      ev.rules = PairMetrics(2, 0, 98, 1, 0);
      ev.rules = PairMetrics(10, 0, 90, 1, 0); // 10 %
      ev.withModel = PairMetrics(15, 0, 85, 1, 0); // 15 %: +5 puntos pero sólo ×1,5
      expect(met(decideT07(ev, res.records, cfg()), '3'), isFalse);
    });

    test('veto: sólo si hay vetos y ≤ 10 % son dañinos', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.vetoes
        ..total = 10
        ..correct = 9;
      expect(decideT07(ev, res.records, cfg()).allowVeto, isTrue);
      ev.vetoes.correct = 8;
      expect(decideT07(ev, res.records, cfg()).allowVeto, isFalse);
      ev.vetoes
        ..total = 0
        ..correct = 0;
      expect(decideT07(ev, res.records, cfg()).allowVeto, isFalse);
    });

    T08Row corro5({bool ok = true}) => T08Row(
      label: 'c', kind: 'corroboracion', reports: 5, rulesGroups: 5, modelGroups: ok ? 1 : 3, rulesIndependentSources: 1, modelIndependentSources: ok ? 5 : 2, rulesConfidence: 0.6, modelConfidence: ok ? 0.95 : 0.6,
    );
    T08Row rumorRow({int sources = 1, double conf = 0.2}) => T08Row(
      label: 'r', kind: 'rumor', reports: 12, rulesGroups: 1, modelGroups: 1, rulesIndependentSources: 1, modelIndependentSources: sources, rulesConfidence: 0.2, modelConfidence: conf,
    );

    test('(5) corroboración: un grupo con las 5 fuentes y más confianza en al menos el 80 % de los escenarios', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.scenarios
        ..clear()
        ..addAll([corro5(), corro5(), corro5(), corro5(), corro5(ok: false)]);
      expect(met(decideT07(ev, res.records, cfg()), '5'), isTrue, reason: '4 de 5');
      ev.scenarios
        ..clear()
        ..addAll([corro5(), corro5(), corro5(ok: false), corro5(ok: false), corro5(ok: false)]);
      expect(met(decideT07(ev, res.records, cfg()), '5'), isFalse, reason: '2 de 5');
      ev.scenarios.clear();
      expect(met(decideT07(ev, res.records, cfg()), '5'), isFalse, reason: 'sin escenarios no hay nada demostrado');
    });

    test('romper UNA sola de las condiciones de seguridad (1, 2 o 4) basta para no ofrecerla', () async {
      final (res, ev0) = await run(_Oracle(truth));
      T07Eval fresh() => evalT07(data, res.records, minConfidence: 0.8);
      final malos = [for (var i = 0; i < 20; i++) rec(reason: i < 2 ? 'plazo_agotado' : null)];
      final ev1 = fresh()..withModel = PairMetrics(90, 10, 0, 1, 0);
      final v1 = decideT07(ev1, res.records, cfg());
      expect([v1.offerAsOption, v1.conclusion.contains('sin cumplir: 1)')], [false, true]);
      final ev2 = fresh();
      ev2.unions
        ..total = 0
        ..correct = 0;
      final v2 = decideT07(ev2, res.records, cfg());
      expect([v2.offerAsOption, v2.conclusion.contains('sin cumplir: 2)')], [false, true]);
      final v4 = decideT07(ev0, malos, cfg());
      expect([v4.offerAsOption, v4.conclusion.contains('sin cumplir: 4)')], [false, true]);
      expect(decideT07(ev0, res.records, cfg()).offerAsOption, isTrue, reason: 'precondición: sin romper nada sí se ofrece');
    });

    test('un rumor que se pasa impide recomendarla aunque lo demás cumpla (y la conclusión dice «no (6)»)', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.scenarios.removeWhere((s) => s.kind == 'rumor');
      final v = decideT07(ev, res.records, cfg());
      expect(v.offerAsOption, isTrue);
      expect(v.recommend, isFalse);
      expect(v.conclusion, contains('no (6)'));
    });

    test('(5) cada condición cuenta por separado: grupos, fuentes y confianza', () async {
      final (res, ev) = await run(_Oracle(truth));
      T08Row row({int groups = 1, int sources = 5, double conf = 0.95}) => T08Row(
        label: 'c', kind: 'corroboracion', reports: 5, rulesGroups: 5, modelGroups: groups, rulesIndependentSources: 1, modelIndependentSources: sources, rulesConfidence: 0.6, modelConfidence: conf,
      );
      for (final r in [row(groups: 2), row(sources: 4), row(conf: 0.6), row(conf: 0.5)]) {
        ev.scenarios
          ..clear()
          ..addAll([r, r, r, r, r]);
        expect(met(decideT07(ev, res.records, cfg()), '5'), isFalse);
      }
      ev.scenarios
        ..clear()
        ..addAll([row(), row(), row(), row(), row()]);
      expect(met(decideT07(ev, res.records, cfg()), '5'), isTrue);
    });

    test('sin escenarios de T08 se ofrece como opción pero NO se recomienda, y la conclusión dice qué falta', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.scenarios.removeWhere((s) => s.kind == 'corroboracion');
      var v = decideT07(ev, res.records, cfg());
      expect(v.offerAsOption, isTrue);
      expect(v.recommend, isFalse);
      expect(v.conclusion, contains('no (5)'));
      ev.scenarios.removeWhere((s) => s.kind == 'rumor');
      v = decideT07(ev, res.records, cfg());
      expect(v.conclusion, contains('no (5, 6)'));
    });

    test('(6) un rumor con 3 fuentes (el máximo permitido) pasa; si hay dos rumores y uno se pasa, no', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.scenarios
        ..clear()
        ..add(rumorRow(sources: 3, conf: 0.79));
      expect(met(decideT07(ev, res.records, cfg()), '6'), isTrue);
      ev.scenarios
        ..clear()
        ..addAll([rumorRow(), rumorRow(sources: 4)]);
      expect(met(decideT07(ev, res.records, cfg()), '6'), isFalse);
    });

    test('(6) rumor: no gana fuentes independientes por encima de las que tiene ni sube de 0,8 de confianza', () async {
      final (res, ev) = await run(_Oracle(truth));
      ev.scenarios
        ..clear()
        ..add(rumorRow());
      expect(met(decideT07(ev, res.records, cfg()), '6'), isTrue);
      ev.scenarios
        ..clear()
        ..add(rumorRow(sources: 4));
      expect(met(decideT07(ev, res.records, cfg()), '6'), isFalse);
      ev.scenarios
        ..clear()
        ..add(rumorRow(conf: 0.8));
      expect(met(decideT07(ev, res.records, cfg()), '6'), isFalse);
      ev.scenarios.clear();
      expect(met(decideT07(ev, res.records, cfg()), '6'), isFalse);
    });
  });

  group('informes', () {
    final data = [T07Dataset('s1', 'synth', fixture()), T07Dataset('corroboracion-1', 'corroboracion', generateCorroboration(sources: 5, seed: 1))];
    late T07ModelResult res;
    setUpAll(() async {
      res = await runT07Model(cfg(), _Oracle({...textToIncident(fixture()), ...textToIncident(data[1].reports)}), datasets: data);
    });

    test('el Markdown trae las tres variantes, la matriz del juez, uniones y vetos, T08, costes y LÍMITES; nunca una clave ni un texto', () {
      final md = renderT07Model(cfg(), res, data);
      for (final s in ['T07 con el juez semántico REAL', 'Sólo reglas', 'Reglas + modelo', 'sin veto', 'Matriz del juez', 'Uniones del modelo', 'Vetos del modelo', 'T08', 'Criterio de adopción', 'Lo que esta prueba NO dice', 'claude-sonnet-5-5']) {
        expect(md, contains(s), reason: s);
      }
      expect(md, isNot(contains('sk-ant')));
      expect(md, contains(kT07DecisionRule), reason: 'el criterio fijado de antemano va junto a los resultados');
      for (final d in data) {
        for (final r in d.reports) {
          if ((r.text ?? '').length > 12) expect(md, isNot(contains(r.text!)), reason: 'el informe no incluye el texto de los reportes');
        }
      }
    });

    test('con --criterion 2 el informe lleva la regla v2 (declarada como reescrita), el veredicto de decideT07V2 y la nota de las 5 fuentes retirada, y NO la regla v1', () {
      final c = cfg(criterion: 2, minConfidence: 0.85);
      final md = renderT07Model(c, res, data);
      expect(md, contains(kT07DecisionRuleV2));
      expect(md, isNot(contains(kT07DecisionRule)));
      expect(md, contains('### Criterio de adopción de la ronda 2 (REESCRITO tras ver la ronda 1: evidencia más débil)'), reason: 'el encabezado ya lo dice, no sólo el texto de la regla');
      expect(md, contains('criterio retirado'));
      final ev = evalT07(data, res.records, minConfidence: 0.85);
      expect(md, contains(decideT07V2(ev, res.records, c).conclusion));
      expect(md, isNot(contains('| 5. corroboración')), reason: 'el criterio 5 ya no figura en la tabla de criterios');
    });

    test('por omisión (criterio 1) el informe sigue siendo el de la ronda 1, sin mención al v2', () {
      final md = renderT07Model(cfg(), res, data);
      expect(md, contains(kT07DecisionRule));
      expect(md, isNot(contains(kT07DecisionRuleV2)));
    });

    test('el informe trae el veredicto del criterio, la evidencia disponible, la versión del código y NO llama «duro» al tope', () {
      final md = renderT07Model(cfg(), res, data, codeVersion: 'abc1234 (árbol limpio)');
      for (final s in ['Veredicto del criterio', 'comparten la calle escrita', 'abc1234 (árbol limpio)', 'no es estrictamente duro']) {
        expect(md, contains(s), reason: s);
      }
      expect(md, isNot(contains('tope duro')));
    });

    test('el informe pone cada porcentaje de evidencia en su sitio (calle 1 de 10, palabra 4 de 10)', () async {
      final rs = [
        rep('e1-1', inc: 0, text: 'carrera 16 con calle 39, hay heridos'),
        rep('e2-1', inc: 0, text: 'nadie herido, carrera 16 con calle 39', minutes: 1),
        rep('e3-1', inc: 0, text: 'mucha sangre', minutes: 2),
        rep('e5-1', inc: 0, text: 'carrera 16 con calle 40', minutes: 3),
        rep('e6-1', inc: 0, text: 'sangre por todos lados', minutes: 3),
      ];
      final d = [T07Dataset('s1', 'synth', rs)];
      final rsx = await runT07Model(cfg(), _Oracle(textToIncident(rs)), datasets: d);
      final md = renderT07Model(cfg(), rsx, d);
      expect(md, contains('**10.0 %** comparten la calle escrita y **40.0 %** alguna palabra de contenido'));
    });

    test('el informe incluye la conclusión del veredicto tal cual la calcula decideT07', () {
      final ev = evalT07(data, res.records, minConfidence: 0.8);
      final v = decideT07(ev, res.records, cfg());
      expect(renderT07Model(cfg(), res, data), contains('**${v.conclusion}**'));
    });

    test('la precisión de los «possible» se informa con SU número (aunque no cambien nada)', () async {
      final rsx = await runT07Model(cfg(), _Oracle(textToIncident(fixture()), mode: 'possible'), datasets: [data.first]);
      final md = renderT07Model(cfg(), rsx, [data.first]);
      final j = evalT07([data.first], rsx.records, minConfidence: 0.8).judgments;
      expect(j.possibleWhenSame, isNot(j.possibleWhenDifferent), reason: 'precondición: el número distingue «mismo» de «distinto»');
      final esperado = (100 * j.possibleWhenSame / (j.possibleWhenSame + j.possibleWhenDifferent)).toStringAsFixed(1);
      expect(md, contains('Precisión de los `possible`: $esperado %'));
      expect(md, contains('no cambian nada'));
    });

    test('el CSV es coherente con un oráculo perfecto: «same» ⇔ misma verdad', () {
      final lines = renderT07ModelCsv(data, res.records).trim().split('\n').skip(1).toList();
      expect(lines.any((l) => l.contains(',same,')), isTrue);
      expect(lines.any((l) => l.contains(',different,')), isTrue);
      for (final l in lines) {
        if (l.contains(',same,')) expect(l.endsWith(',true'), isTrue, reason: l);
        if (l.contains(',different,')) expect(l.endsWith(',false'), isTrue, reason: l);
      }
    });

    test('el CSV tiene una fila por par juzgado con la verdad, sin texto', () {
      final csv = renderT07ModelCsv(data, res.records);
      final lines = csv.trim().split('\n');
      expect(lines.first, 'dataset,a,b,verdict,confidence,truth_same');
      expect(lines.length - 1, res.records.fold<int>(0, (a, r) => a + r.judgments.length));
      for (final d in data) {
        for (final r in d.reports) {
          if ((r.text ?? '').length > 12) expect(csv, isNot(contains(r.text!)));
        }
      }
    });
  });
}
