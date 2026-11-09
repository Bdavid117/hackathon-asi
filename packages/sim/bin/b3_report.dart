// Mide T06, T07 y T08 y escribe docs/resultados/b3.md.
//
//   dart run packages/sim/bin/b3_report.dart [docs/resultados/b3.md]
//
// Reglas que se impuso este informe:
//  · los umbrales se calibran con las semillas 1–5 y se reporta con semillas NO vistas;
//  · las semillas 101–105 se usaron para la PRIMERA medición (diseño tal como estaba en el PDF) y
//    por tanto ya no son «no vistas». Las 201–205 se usaron MIENTRAS SE AFINABA el diseño revisado (se
//    leyeron sus cifras y después se cambiaron umbrales, política de bloqueo y regla anti-puente), así que
//    tampoco son «no vistas». La cifra principal sale de 301–305, generadas DESPUÉS de congelar el código;
//  · nunca se toca el generador ni el léxico del triaje para que una cifra salga mejor;
//  · si un criterio no se cumple, se dice.
import 'dart:io';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';

const List<int> calibrationSeeds = [1, 2, 3, 4, 5];
const List<int> firstSeeds = [101, 102, 103, 104, 105]; // primera medición (diseño v1)
const List<int> tuneSeeds = [201, 202, 203, 204, 205]; // usadas mientras se afinaba (ya vistas)
const List<int> reportSeeds = [301, 302, 303, 304, 305]; // nunca vistas: generadas con el código congelado
const List<double> hiGrid = [0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95];
const List<double> noLocGrid = [0.85, 0.90, 0.92, 0.95, 0.98];

String pct(double x, {int d = 1}) => '${(100 * x).toStringAsFixed(d)} %';
String f2(double x) => x.toStringAsFixed(2);

class SeedRun {
  SeedRun(this.seed, this.ds, this.obs, this.links, this.keys, this.truth);
  final int seed;
  final SynthDataset ds;
  final List<Observation> obs;
  final List<Link> links;
  final List<String> keys;
  final Map<String, int> truth;
}

SeedRun run(int seed) {
  final ds = generateDataset(SynthConfig(seed: seed));
  final obs = [for (final r in ds.reports) r.toObservation()];
  final res = computeLinks(obs);
  return SeedRun(seed, ds, obs, res.links, [for (final o in obs) o.reportKey], {for (final r in ds.reports) r.reportKey: r.trueIncident});
}

typedef Sum = ({int tp, int fp, int fn, int groups, int mixed});

Sum sumPairs(List<SeedRun> runs, double hi, double noLoc) {
  var tp = 0, fp = 0, fn = 0, g = 0, mx = 0;
  for (final r in runs) {
    final m = pairMetrics(groupsAt(r.obs, r.links, hi, noLoc), r.truth);
    tp += m.tp;
    fp += m.fp;
    fn += m.fn;
    g += m.groups;
    mx += m.mixedGroups;
  }
  return (tp: tp, fp: fp, fn: fn, groups: g, mixed: mx);
}

double recallOf(Sum s) => s.tp + s.fn == 0 ? 0 : s.tp / (s.tp + s.fn);
double precOf(Sum s) => s.tp + s.fp == 0 ? 0 : s.tp / (s.tp + s.fp);
double fmOf(Sum s) => s.tp + s.fp == 0 ? 0 : s.fp / (s.tp + s.fp);
double f1Of(Sum s) => precOf(s) + recallOf(s) == 0 ? 0 : 2 * precOf(s) * recallOf(s) / (precOf(s) + recallOf(s));

String table(List<String> head, List<List<String>> rows) {
  final b = StringBuffer()
    ..writeln('| ${head.join(' | ')} |')
    ..writeln('|${head.map((_) => '---').join('|')}|');
  for (final r in rows) {
    b.writeln('| ${r.join(' | ')} |');
  }
  return b.toString();
}

void main(List<String> args) {
  final out = args.isNotEmpty ? args.first : 'docs/resultados/b3.md';
  final sw = Stopwatch()..start();
  stderr.writeln('generando y puntuando semillas…');
  final calib = [for (final s in calibrationSeeds) run(s)];
  final held = [for (final s in reportSeeds) run(s)];
  final tuned = [for (final s in tuneSeeds) run(s)];
  stderr.writeln('puntuado en ${sw.elapsed.inSeconds} s');
  final nReports = held.fold<int>(0, (a, r) => a + r.ds.reports.length);

  // ------------------------------------------------------------------ T06
  Map<String, TriageResult> predict(SeedRun r) => {
    for (final x in r.ds.reports) x.reportKey: triage(x.flags, text: x.text, hasLocation: x.lat != null && x.locQuality.hasCoordinates),
  };
  List<TriageSample> samples(SeedRun r, Map<String, TriageResult> pred) => [
    for (final x in r.ds.reports)
      TriageSample(
        truth: x.trueUrgency,
        predicted: pred[x.reportKey]!.urgency,
        escalate: pred[x.reportKey]!.escalateToHuman,
        subgroup: (x.trueUrgency == Urgency.p1 && x.subgroup == 'no_p1') ? 'gemelo_p1' : x.subgroup,
        incident: x.trueIncident + 100000 * r.seed,
        tags: x.tags,
      ),
  ];
  final preds = {for (final r in held) r.seed: predict(r)};
  final allSamples = [for (final r in held) ...samples(r, preds[r.seed]!)];
  final t06 = evalTriage(allSamples);
  final perSeedRecall = [for (final r in held) evalTriage(samples(r, preds[r.seed]!)).global.recall];
  final minSeed = perSeedRecall.reduce((a, b) => a < b ? a : b), maxSeed = perSeedRecall.reduce((a, b) => a > b ? a : b);
  final t06Pass = t06.global.recall >= 0.95;
  final p1Total = t06.global.truth;
  final noInfo = (t06.bySubgroup['sin_pistas']?.truth ?? 0) + (t06.bySubgroup['banderas_equivocadas']?.truth ?? 0);

  // ------------------------------------------------------------------ T07: calibración (semillas 1–5)
  ({double hi, double noLoc, double recall, double fm})? best;
  final calibRows = <List<String>>[];
  for (final hi in hiGrid) {
    for (final nl in noLocGrid) {
      final s = sumPairs(calib, hi, nl);
      final ok = fmOf(s) <= 0.01 && s.tp > 0;
      if (nl == 0.92) calibRows.add([f2(hi), pct(precOf(s)), pct(recallOf(s), d: 2), pct(fmOf(s), d: 2), ok ? 'sí' : 'no']);
      if (ok && (best == null || recallOf(s) > best.recall)) best = (hi: hi, noLoc: nl, recall: recallOf(s), fm: fmOf(s));
    }
  }
  const defaults = (hi: 0.80, noLoc: 0.92); // el valor INICIAL del PDF (no el que usa el nodo)
  final calibFound = best != null;
  final chosen = best != null ? (hi: best.hi, noLoc: best.noLoc) : defaults;
  // El titular del informe debe ser la configuración que EJECUTA el nodo: si no coinciden, se avisa.
  final shipped = const Weights();
  final shippedMatches = chosen.hi == shipped.thetaHi && chosen.noLoc == shipped.thetaHiNoLoc;

  // ------------------------------------------------------------------ T07: reporte (semillas nuevas)
  final atDefault = sumPairs(held, defaults.hi, defaults.noLoc);
  final atChosen = sumPairs(held, chosen.hi, chosen.noLoc);
  final perSeedFm = [for (final r in held) pairMetrics(groupsAt(r.obs, r.links, chosen.hi, chosen.noLoc), r.truth).falseMergeRate];
  final fmMax = perSeedFm.reduce((a, b) => a > b ? a : b), fmMin = perSeedFm.reduce((a, b) => a < b ? a : b);
  final curveRows = <List<String>>[];
  for (final hi in hiGrid) {
    final s = sumPairs(held, hi, chosen.noLoc);
    curveRows.add([f2(hi), pct(precOf(s)), pct(recallOf(s), d: 2), pct(fmOf(s), d: 2), '${s.mixed}', '${s.groups}']);
  }
  final t07Pass = fmOf(atChosen) <= 0.01;
  final atChosenTuned = sumPairs(tuned, chosen.hi, chosen.noLoc);
  final perSeedFmTuned = [for (final r in tuned) pairMetrics(groupsAt(r.obs, r.links, chosen.hi, chosen.noLoc), r.truth).falseMergeRate];
  final fmTunedMax = perSeedFmTuned.reduce((a, b) => a > b ? a : b), fmTunedMin = perSeedFmTuned.reduce((a, b) => a < b ? a : b);
  final overOnePct = perSeedFm.where((x) => x > 0.01).length;
  // Estabilidad con los umbrales del PDF: una sola unión de dos gemelos cambia mucho la cifra.
  final calibDefault = sumPairs(calib, defaults.hi, defaults.noLoc);
  final perSeedFmDefault = [for (final r in held) pairMetrics(groupsAt(r.obs, r.links, defaults.hi, defaults.noLoc), r.truth).falseMergeRate];
  final fmDefMax = perSeedFmDefault.reduce((a, b) => a > b ? a : b), fmDefMin = perSeedFmDefault.reduce((a, b) => a < b ? a : b);
  final trueIncidents = held.first.ds.incidents.length;

  LinkCoverage coverage(double hi, double noLoc) {
    var tpairs = 0, same = 0, sameOk = 0, poss = 0, possOk = 0;
    for (final r in held) {
      final c = linkCoverage(rethreshold(r.links, hi, noLoc), r.truth);
      tpairs += c.truePairs;
      same += c.same;
      sameOk += c.sameCorrect;
      poss += c.possible;
      possOk += c.possibleCorrect;
    }
    return LinkCoverage(tpairs, same, sameOk, poss, possOk);
  }

  final covDefault = coverage(defaults.hi, defaults.noLoc);
  final covChosen = coverage(chosen.hi, chosen.noLoc);

  var mixedTwin = 0, mixedOther = 0;
  for (final r in held) {
    final twinOf = {for (final i in r.ds.incidents.values) if (i.twinOf != null) i.id: i.twinOf!};
    for (final g in groupsAt(r.obs, r.links, chosen.hi, chosen.noLoc)) {
      final labels = {for (final k in g) r.truth[k]!}..remove(-1);
      if (labels.length <= 1) continue;
      final isTwin = labels.any((l) => twinOf.containsKey(l) && labels.contains(twinOf[l]));
      if (isTwin) {
        mixedTwin++;
      } else {
        mixedOther++;
      }
    }
  }

  // Coste de la «revisión humana»: cuántos reportes se escalan y cuántos de ellos lo merecían.
  var nAll = 0, nEsc = 0, escP1 = 0, escHigh = 0, escNoText = 0;
  for (final r in held) {
    for (final x in r.ds.reports) {
      nAll++;
      if (!preds[r.seed]![x.reportKey]!.escalateToHuman) continue;
      nEsc++;
      if (x.trueUrgency == Urgency.p1) escP1++;
      if (x.trueUrgency.index <= Urgency.p2.index) escHigh++;
      if (x.text == null) escNoText++;
    }
  }

  // Cobertura de las sugerencias cuando NINGUNO de los dos reportes lleva texto: lo que produce la app
  // real (hoy no tiene campo de texto).
  LinkCoverage noTextCoverage(double hi, double noLoc) {
    var tpairs = 0, same = 0, sameOk = 0, poss = 0, possOk = 0;
    for (final r in held) {
      final text = {for (final x in r.ds.reports) x.reportKey: x.text};
      final c = linkCoverage(rethreshold(r.links, hi, noLoc), r.truth, where: (a, b) => text[a] == null && text[b] == null);
      tpairs += c.truePairs;
      same += c.same;
      sameOk += c.sameCorrect;
      poss += c.possible;
      possOk += c.possibleCorrect;
    }
    return LinkCoverage(tpairs, same, sameOk, poss, possOk);
  }

  final covNoText = noTextCoverage(chosen.hi, chosen.noLoc);

  // P1 tal como lo ve la cola (urgencia del grupo = la más alta)
  double visible(double hi, double noLoc) {
    var p1 = 0, vis = 0;
    for (final r in held) {
      final groups = groupsAt(r.obs, r.links, hi, noLoc);
      final pr = {for (final e in preds[r.seed]!.entries) e.key: e.value.urgency};
      final tr = {for (final x in r.ds.reports) x.reportKey: x.trueUrgency};
      final n = tr.values.where((u) => u == Urgency.p1).length;
      p1 += n;
      vis += (groupVisibleRecallP1(groups, pr, tr) * n).round();
    }
    return p1 == 0 ? 0 : vis / p1;
  }

  final visDefault = visible(defaults.hi, defaults.noLoc);
  final visChosen = visible(chosen.hi, chosen.noLoc);

  // ------------------------------------------------------------------ T08
  final t08Rows = <List<String>>[];
  for (final (copies, sources) in [(10, 1), (100, 3), (1000, 3), (1000, 10)]) {
    final rumor = [for (final x in generateRumor(copies: copies, sources: sources, seed: 1)) x.toObservation()];
    final groups = groupObservations(rumor);
    final a = assessGroup(rumor);
    t08Rows.add(['rumor', '$copies copias de $sources fuente(s)', '${groups.length}', '${a.independentSources}', f2(a.confidence), a.uncertainty.join(', ')]);
  }
  for (final n in [2, 3, 5, 8]) {
    final c = [for (final x in generateCorroboration(sources: n, seed: 1)) x.toObservation()];
    final groups = groupObservations(c);
    final a = assessGroup(c);
    t08Rows.add(['corroboración', '$n fuentes independientes', '${groups.length}', '${a.independentSources}', f2(a.confidence), a.uncertainty.isEmpty ? '—' : a.uncertainty.join(', ')]);
  }
  final rumor1000 = assessGroup([for (final x in generateRumor(copies: 1000, sources: 3, seed: 1)) x.toObservation()]);
  final corro5obs = [for (final x in generateCorroboration(sources: 5, seed: 1)) x.toObservation()];
  final corro5 = assessGroup(corro5obs);
  final corro5Groups = groupObservations(corro5obs).length;
  final t08Pass = rumor1000.confidence < corro5.confidence;

  // ------------------------------------------------------------------ Escritura
  final b = StringBuffer();
  b.writeln('# B3 · Resultados de T06, T07 y T08 (agentes 2 y 3)');
  b.writeln();
  b.writeln('Generado con `dart run packages/sim/bin/b3_report.dart`. Datos **sintéticos**; léase «Qué demuestra y qué no» antes de citar una cifra.');
  b.writeln();
  b.writeln('| Prueba | Criterio del PDF | Resultado (diseño final, semillas nunca vistas 301–305) | ¿Cumple? |');
  b.writeln('|---|---|---|---|');
  b.writeln('| **T06** triaje | recall de P1 ≥ 95 % | recall **${pct(t06.global.recall)}** por reporte (${pct(minSeed)}–${pct(maxSeed)} por semilla); ${pct(t06.global.recallWithEscalation)} si se cuenta «revisión humana» como acierto, **a costa de escalar el ${pct(nEsc / nAll)} de todos los reportes** (y el tablero aún no muestra ese aviso) | **${t06Pass ? 'sí' : 'NO'}** |');
  b.writeln('| **T07** deduplicación | falsa fusión ≤ 1 % | **${pct(fmOf(atChosen), d: 2)}** con θ calibrado, que es el que usa el nodo (${pct(fmMin, d: 2)}–${pct(fmMax, d: 2)} por semilla), **a costa de agrupar sólo el ${pct(recallOf(atChosen), d: 2)} de los pares verdaderos**; con los umbrales del PDF: ${pct(fmOf(atDefault), d: 2)} de falsa fusión y ${pct(recallOf(atDefault), d: 2)} de recall, **pero inestable**: ${pct(fmDefMin, d: 2)}–${pct(fmDefMax, d: 2)} según la semilla y ${pct(fmOf(calibDefault), d: 2)} en las semillas de calibración | **${t07Pass ? (overOnePct == 0 ? 'sí (trivialmente: casi no agrupa)' : 'sí en conjunto, pero NO en $overOnePct de ${reportSeeds.length} semillas, y sólo trivialmente (casi no agrupa)') : 'NO'}** |');
  b.writeln('| **T08** rumor frente a corroboración | confianza(rumor) < confianza(corroborado) | ${f2(rumor1000.confidence)} frente a ${f2(corro5.confidence)} sobre grupos dados; **de punta a punta las 5 fuentes independientes forman $corro5Groups grupos, no uno** | **${t08Pass ? 'sí (sobre grupos dados)' : 'NO'}** |');
  b.writeln();
  b.writeln('Semillas de calibración ${calibrationSeeds.join(', ')}; cifras del diseño final con las semillas **nunca vistas** ${reportSeeds.join(', ')} (generadas con el código congelado; las ${tuneSeeds.join(', ')} se usaron al afinar) ($nReports reportes). Léase primero la sección siguiente.');
  b.writeln();

  b.writeln('## Historial: qué se midió, qué falló y qué se cambió');
  b.writeln();
  b.writeln('**1. Primera medición (el agente 3 exactamente como lo describe el PDF, semillas 101–105).** Medida antes de cambiar nada; cifras copiadas de esa ejecución:');
  b.writeln();
  b.writeln(table(
    ['Criterio', 'Resultado', '¿Cumple?'],
    [
      ['T06 recall de P1 por reporte', '77.0 % (73.2 %–81.6 % por semilla)', 'NO'],
      ['T07 falsa fusión con θ del PDF (0.80 / 0.92)', '3.55 % de los pares dentro de un grupo; recall de pares 2.3 %; 13 grupos mezclados (7 gemelos, 6 de otro tipo)', 'NO'],
      ['T07 con calibración (semillas 1–5)', 'ningún umbral de la rejilla llegó a ≤ 1 %', 'NO'],
      ['T08 rumor < corroboración', '0.20 frente a 0.99 (sobre grupos dados)', 'sí'],
    ],
  ));
  b.writeln();
  b.writeln('**2. Diagnóstico** (sólo con las semillas de calibración 1–5, sin tocar las de reporte):');
  b.writeln();
  b.writeln('- En los pares verdaderos la **mediana del término de texto es 0**: si a uno de los dos reportes le falta el texto, el término vale 0. El texto es opcional (y la app actual no tiene campo de texto), así que un par de SOS de un toque **no puede pasar de 0,70 y nunca es `same`**: sólo el 1,5 % de los pares verdaderos llegaba a `same` y el 23,4 %, a `possible`.');
  b.writeln('- **Todos los falsos que no eran gemelos** eran pares sin ubicación con una frase genérica en ambos («edificio a punto de caer», «varios heridos», «hay un incendio»). Una similitud con una sola palabra de contenido no es evidencia: «no hay atrapados» y «estoy atrapado» puntuaban 1,0 de similitud.');
  b.writeln('- Los falsos que sí eran **gemelos adversariales** (otro suceso a 60–250 m, misma calle, casi misma hora) tenían puntajes de 0,86 o más: con espacio, tiempo y tipo no hay forma determinista de separarlos de un duplicado verdadero. Se probó una ruta «sólo espacio y tiempo» para ganar recall en los reportes sin texto: **se descartó**, porque casi todos sus falsos eran gemelos y subir el umbral apenas los reducía.');
  b.writeln();
  b.writeln('**3. Cambio hecho:** la similitud de texto se pondera por la **masa de evidencia** (`mín(1, palabras compartidas / 5)`): coincidir en una frase genérica casi no cuenta; coincidir en cinco o más palabras, sí. No se cambiaron pesos, umbrales por defecto, ni el generador, ni el léxico del triaje.');
  b.writeln();
  b.writeln('**4. Medición del diseño revisado.** Tras la primera medición se hicieron más cambios mirando resultados (umbral por omisión, política de bloqueo, regla anti-puente, umbral sin ubicación, motivos de caída del modelo). Las semillas 101–105 y 201–205 **ya se vieron y se usaron al afinar: no son «no vistas»**. Con el código **congelado** se generaron las semillas **301–305**, que nadie había visto: las cifras principales de este documento salen de ellas, y se muestran al lado las de 201–205 para ver cuánto optimismo había.');
  b.writeln();

  b.writeln('## T06 · Calidad del triaje (agente 2, reglas)');
  b.writeln();
  b.writeln('Todos los reportes de las semillas nunca vistas, evaluados **uno por uno** (lo que sabría el nodo de cada reporte): banderas + texto, sin modelo de lenguaje. El léxico del triaje es el mismo de la primera medición.');
  b.writeln();
  b.writeln(table(
    ['Medida', 'Valor'],
    [
      ['Reportes con verdad P1', '$p1Total'],
      ['Recall de P1 (clasificado como P1)', pct(t06.global.recall)],
      ['Precisión de P1', pct(t06.global.precision)],
      ['Exactitud global (4 niveles; se reporta aparte)', pct(t06.accuracy)],
      ['Recall de P1 **contando «revisión humana» como acierto** (afirmación distinta)', pct(t06.global.recallWithEscalation)],
      ['**Coste de ese acierto:** reportes que el triaje escala a revisión humana', '$nEsc de $nAll (${pct(nEsc / nAll)}); de ellos ${pct(escHigh / nEsc)} eran de verdad P1 o P2 y ${pct(escP1 / nEsc)} P1; ${pct(escNoText / nEsc)} no llevaban texto'],
      ['Recall de P1 «tal como lo ve la cola» (un reporte cuenta si su grupo se muestra P1), umbral calibrado', '${pct(visChosen)} — **no es un beneficio del agrupamiento**: sale casi igual que el recall por reporte porque casi nada se agrupa'],
      ['Ídem con los umbrales del PDF', pct(visDefault)],
      ['Recall **a nivel de suceso** (sucesos P1 con algún reporte clasificado P1; usa la verdad de agrupamiento)', pct(t06.incidentRecallP1)],
      ['**Techo por construcción:** P1 de los subgrupos «sin pistas» y «banderas equivocadas» (no traen nada que lo delate)', '${pct(noInfo / p1Total)} de los reportes P1 → el recall por reglas no puede pasar de ${pct(1 - noInfo / p1Total)}'],
    ],
  ));
  b.writeln();
  b.writeln('### Por subgrupo (reportes cuya verdad es P1)');
  b.writeln();
  final subOrder = ['banderas_coherentes', 'parcial_con_texto', 'sin_banderas_con_texto', 'sin_pistas', 'banderas_equivocadas', 'gemelo_p1'];
  b.writeln(table(
    ['Subgrupo', 'Reportes P1', 'Recall', 'Recall contando revisión humana'],
    [
      for (final k in subOrder)
        if (t06.bySubgroup[k] != null && t06.bySubgroup[k]!.truth > 0) [k, '${t06.bySubgroup[k]!.truth}', pct(t06.bySubgroup[k]!.recall), pct(t06.bySubgroup[k]!.recallWithEscalation)],
    ],
  ));
  b.writeln();
  b.writeln('### Por etiqueta (reportes cuya verdad es P1)');
  b.writeln();
  final tagOrder = ['con_texto', 'sin_texto', 'parafraseado', 'con_faltas', 'sin_ubicacion', 'ubicacion_imprecisa', 'reloj_desfasado', 'repetido'];
  b.writeln(table(
    ['Etiqueta', 'Reportes P1', 'Recall', 'Recall contando revisión humana'],
    [
      for (final k in tagOrder)
        if (t06.byTag[k] != null && t06.byTag[k]!.truth > 0) [k, '${t06.byTag[k]!.truth}', pct(t06.byTag[k]!.recall), pct(t06.byTag[k]!.recallWithEscalation)],
    ],
  ));
  b.writeln();
  b.writeln('### Matriz de confusión (filas = verdad, columnas = predicción)');
  b.writeln();
  b.writeln(table(
    ['verdad \\ predicción', 'P1', 'P2', 'P3', 'P4'],
    [for (var i = 0; i < 4; i++) ['P${i + 1}', ...t06.confusion[i].map((x) => '$x')]],
  ));
  b.writeln();
  b.writeln('**Lectura honesta:** el criterio de T06 **no se cumple por reglas**. Casi todo el recall que falta está en dos sitios: (1) reportes que **no traen información** (sin banderas ni texto, o con banderas equivocadas): ningún triaje por reglas puede acertarlos, sólo escalarlos a revisión humana —lo que hace— y eso se reporta aparte; (2) reportes con **texto parafraseado** que el léxico no reconoce: es la brecha que el puerto del modelo de lenguaje debería cerrar y que aquí **no está medida** (no se probó con un modelo real). La precisión de P1 es alta: el triaje casi no inventa urgencias.');
  b.writeln();

  b.writeln('## T07 · Deduplicación semántica (agente 3, determinista)');
  b.writeln();
  b.writeln('Cada conjunto: 1 000 reportes en 80 sucesos + 20 sucesos gemelos adversariales de 5 reportes (otro suceso, a 60–250 m, casi a la misma hora, misma calle y mismo tipo) = $trueIncidents sucesos reales. El agrupamiento se mide **sobre los grupos finales** (componentes), no sobre vínculos: un solo vínculo falso fusiona dos sucesos enteros.');
  b.writeln();
  b.writeln('**Calibración** (diseño revisado, semillas ${calibrationSeeds.join(', ')}): se barrió θhi y θhi-sin-ubicación y se eligió el par con **mayor recall con falsa fusión ≤ 1 %** (el criterio del PDF, priorizando no fusionar casos distintos). ${calibFound ? 'Elegido: **θhi = ${f2(chosen.hi)}**, **θhi sin ubicación = ${f2(chosen.noLoc)}** (por defecto del PDF: 0.80 y 0.92).' : '**Ningún umbral de la rejilla cumplió falsa fusión ≤ 1 % en calibración;** se reportan los valores por defecto del PDF.'}');
  b.writeln();
  b.writeln(table(['θhi (θ sin ubicación = 0.92)', 'Precisión de pares', 'Recall de pares', 'Falsa fusión', '¿≤ 1 % y agrupa algo?'], calibRows));
  b.writeln();
  b.writeln('**Resultado con las semillas nunca vistas** (${reportSeeds.join(', ')}):');
  b.writeln();
  b.writeln(table(
    ['Configuración', 'Precisión de pares', 'Recall de pares', 'F1', 'Falsa fusión', 'Grupos', 'Grupos mezclados'],
    [
      ['PDF: θhi 0.80 / sin ubicación 0.92', pct(precOf(atDefault)), pct(recallOf(atDefault), d: 2), pct(f1Of(atDefault), d: 2), pct(fmOf(atDefault), d: 2), '${atDefault.groups}', '${atDefault.mixed}'],
      ['Calibrado: θhi ${f2(chosen.hi)} / sin ubicación ${f2(chosen.noLoc)}', pct(precOf(atChosen)), pct(recallOf(atChosen), d: 2), pct(f1Of(atChosen), d: 2), pct(fmOf(atChosen), d: 2), '${atChosen.groups}', '${atChosen.mixed}'],
    ],
  ));
  b.writeln();
  b.writeln('Sucesos reales por conjunto: $trueIncidents (suma de ${held.length} conjuntos: ${trueIncidents * held.length}); reportes: $nReports. Con el umbral calibrado hay **${atChosen.groups} grupos** para ${trueIncidents * held.length} sucesos reales: **el agente casi no agrupa**. Grupos mezclados (más de un suceso real): **${atChosen.mixed}**, de ellos **$mixedTwin** unen un suceso con su gemelo adversarial y **$mixedOther** son otros.');
  b.writeln();
  b.writeln(shippedMatches
      ? 'El umbral calibrado (θhi ${f2(chosen.hi)}, sin ubicación ${f2(chosen.noLoc)}) **es el valor por omisión del nodo** (`Weights`): las cifras de «Calibrado» son las de lo que se ejecuta. El valor inicial del PDF (0.80) se mide aparte, como referencia.'
      : '⚠️ **El umbral calibrado (${f2(chosen.hi)} / ${f2(chosen.noLoc)}) NO coincide con el valor por omisión del nodo (${f2(shipped.thetaHi)} / ${f2(shipped.thetaHiNoLoc)}):** las cifras de «Calibrado» no describen lo que se ejecuta.');
  b.writeln();
  b.writeln('**Lo que sí hace: sugerir.** Los vínculos `possible` no agrupan, pero se muestran al coordinador como «reportes que podrían ser el mismo suceso» (y son lo que un modelo o una persona resolvería):');
  b.writeln();
  b.writeln(table(
    ['Umbrales', 'Pares verdaderos', 'Agrupa (`same`)', 'Al menos sugiere (`same` + `possible`)', 'Sugerencias totales', 'Precisión de las sugerencias `possible`'],
    [
      ['PDF 0.80 / 0.92', '${covDefault.truePairs}', pct(covDefault.recallGrouped, d: 2), pct(covDefault.recallSuggested), '${covDefault.possible}', pct(covDefault.precisionPossible)],
      ['Calibrado ${f2(chosen.hi)} / ${f2(chosen.noLoc)}', '${covChosen.truePairs}', pct(covChosen.recallGrouped, d: 2), pct(covChosen.recallSuggested), '${covChosen.possible}', pct(covChosen.precisionPossible)],
    ],
  ));
  b.writeln();
  b.writeln('**Sólo con pares sin texto en ninguno de los dos reportes** (lo que produce la app real, que hoy no tiene campo de texto): de los ${covNoText.truePairs} pares verdaderos así, el agente agrupa ${pct(covNoText.recallGrouped, d: 2)} y sugiere (`same` + `possible`) ${pct(covNoText.recallSuggested)}, con **${pct(covNoText.precisionPossible)} de precisión en lo sugerido** (${covNoText.possible} sugerencias). La cifra general de sugerencias (arriba) mezcla reportes con y sin texto; para la app tal como está, ésta es la que cuenta.');
  b.writeln();
  b.writeln('**Curva** falsa fusión frente a recall (semillas nunca vistas, θ sin ubicación = ${f2(chosen.noLoc)}):');
  b.writeln();
  b.writeln(table(['θhi', 'Precisión', 'Recall', 'Falsa fusión', 'Grupos mezclados', 'Grupos'], curveRows));
  b.writeln();
  b.writeln('**Cuánto optimismo había:** misma configuración (la que usa el nodo), dos conjuntos de semillas.');
  b.writeln();
  b.writeln(table(
    ['Semillas', 'Falsa fusión (todas juntas)', 'Falsa fusión por semilla', 'Recall de pares', 'Grupos mezclados'],
    [
      ['${tuneSeeds.join(', ')} — usadas al afinar (ya vistas)', pct(fmOf(atChosenTuned), d: 2), '${pct(fmTunedMin, d: 2)}–${pct(fmTunedMax, d: 2)}', pct(recallOf(atChosenTuned), d: 2), '${atChosenTuned.mixed}'],
      ['${reportSeeds.join(', ')} — nunca vistas', pct(fmOf(atChosen), d: 2), '${pct(fmMin, d: 2)}–${pct(fmMax, d: 2)}', pct(recallOf(atChosen), d: 2), '${atChosen.mixed}'],
    ],
  ));
  b.writeln();
  b.writeln(overOnePct == 0
      ? 'Ninguna de las semillas nunca vistas supera el 1 % de falsa fusión. **Pero** un solo vínculo entre gemelos mueve la cifra varios puntos (con los umbrales del PDF se vio de 0 % a 1,8 % según la semilla): un 0,00 % con 5 semillas no garantiza un 0,00 % con otras.'
      : '⚠️ **$overOnePct de ${reportSeeds.length} semillas nunca vistas superan el 1 % de falsa fusión** (hasta ${pct(fmMax, d: 2)}): el criterio **no** se sostiene con datos nuevos.');
  b.writeln();
  b.writeln('**Estabilidad:** con los umbrales del PDF la falsa fusión por semilla va de ${pct(fmDefMin, d: 2)} a ${pct(fmDefMax, d: 2)} en las semillas nunca vistas y es ${pct(fmOf(calibDefault), d: 2)} en las de calibración: depende de si un único vínculo une un suceso con su gemelo (un vínculo falso fusiona decenas de pares). Por eso el umbral se calibró hacia el lado conservador y aun así no hay garantía.\n\n**Lectura honesta:** el criterio «falsa fusión ≤ 1 %» **se cumple sólo porque el agente casi no fusiona nada**; un sistema que no agrupa jamás lo cumpliría igual. El criterio es necesario pero no suficiente: por eso se reporta también el recall. El agente determinista **no puede** separar un duplicado verdadero de un suceso vecino casi idéntico (gemelo adversarial) usando sólo espacio, tiempo, tipo y texto léxico; el PDF reserva esa franja `possible` para el modelo y para el coordinador, y en B3 el modelo no se usa en la correlación.');
  b.writeln();

  b.writeln('## T08 · Rumor frente a corroboración');
  b.writeln();
  b.writeln(table(['Caso', 'Entrada', 'Grupos que forma el agente 3', 'Fuentes independientes', 'Confianza', 'Incertidumbre'], t08Rows));
  b.writeln();
  b.writeln('Criterio: confianza(1 000 copias de 3 fuentes) = **${f2(rumor1000.confidence)}** < confianza(5 fuentes independientes) = **${f2(corro5.confidence)}** → **${t08Pass ? 'cumple' : 'NO cumple'}**, **pero** sobre un grupo ya armado a mano. De punta a punta, las copias del rumor sí forman un solo grupo (casi idénticas), mientras que las cinco fuentes independientes —cada una con sus propias palabras— **no se agrupan entre sí** (forman $corro5Groups grupos): la similitud léxica no reconoce que dos personas distintas describen el mismo suceso. La confianza usa credibilidades base **supuestas** (app 0.6, radio 0.2), no calibradas con datos reales. Con 8 fuentes el generador sólo tiene 6 textos distintos y repite dos, de ahí la incertidumbre `fuente_no_independiente`.');
  b.writeln();

  b.writeln('## Qué demuestra y qué no');
  b.writeln();
  b.writeln('- **Los datos son sintéticos y los escribió la misma persona que las reglas.** Un generador y un léxico del mismo autor comparten vocabulario: las cifras de T06 miden qué tan bien las reglas reconocen *este* generador, no a personas reales. Se intentó que no fuera circular (paráfrasis, faltas de ortografía, textos sin pistas, banderas equivocadas, GPS con ruido, reloj desfasado), pero eso no lo elimina.');
  b.writeln('- **Las fracciones de casos difíciles son supuestos** (de los reportes de sucesos P1: 55 % banderas coherentes, 20 % parciales con texto, 10 % sin banderas con texto, 10 % sin pistas, 5 % banderas equivocadas). Se fijaron en la prueba del generador **antes** de escribir las reglas. Con otras fracciones el recall cambia.');
  b.writeln('- **El diseño del agente 3 se revisó después de ver resultados** (ver «Historial»). Lo revisado se midió finalmente con semillas nunca vistas (301–305), pero el diagnóstico y los ajustes salieron de datos del mismo generador.');
  b.writeln('- **T07: ≤ 1 % de falsa fusión no es una buena noticia por sí sola** (ver la lectura honesta). **T08 se cumple sobre grupos dados**, no de punta a punta para fuentes independientes.');
  b.writeln('- **El agrupamiento es léxico y determinista:** no hay modelo de lenguaje en la correlación, por lo que las **contradicciones quedan «no evaluadas»** y los pares `possible` sólo se sugieren.');
  b.writeln('- **El texto de los reportes es dato no confiable** y no cambia la urgencia más allá de los términos del léxico (probado con inyección de instrucciones).');
  b.writeln('- **Nada se midió con un modelo de lenguaje.** El puerto del modelo (si se implementa) está probado sólo contra un contrato simulado, sin acceso a la API real.');
  b.writeln();
  b.writeln('Tiempo de ejecución de este informe: ${sw.elapsed.inSeconds} s.');
  File(out).writeAsStringSync(b.toString());
  stdout.writeln('escrito $out');
}
