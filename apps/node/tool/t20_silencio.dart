// T20 · La capa «Silencio»: ¿cuántas zonas marcadas son de verdad un apagón? (Escenario 2).
//   dart run tool/t20_silencio.dart [--seeds 20] [--zones 60] [--first-seed 100] [--out ../../docs/resultados/t20-silencio.md]
//
// Se mide el detector REAL (`buildCoverage`, ventana de actividad 6 h y de silencio 30 min) contra una verdad definida APARTE de él: zonas que
// reportan como un proceso de Poisson y un 30 % de ellas sufre un apagón (su tasa cae al 5 %). Ver `silence_study.dart`.
//
// HIPÓTESIS (escritas y commiteadas ANTES de correr; propias del diseño, NO del enunciado; datos sintéticos de un modelo sencillo del mismo autor):
//   H1. Con la ventana de 30 min la PRECISIÓN global es menor que 80 %: la capa marca también zonas que sólo estaban callando un rato.
//   H2. En zonas poco habladoras (λ < 1 reporte/h) la precisión es menor que 50 %.
//   H3. Para apagones de 60 min o más en zonas habladoras (λ ≥ 4/h) la EXHAUSTIVIDAD es de al menos 80 %.
//   H4. Los apagones de menos de 30 min no se marcan (salvo casualidad): no es un fallo, es la definición de la ventana.
//   H5. Subir la ventana de silencio (15 → 30 → 60 → 120 min) sube la precisión y baja la exhaustividad: la ventana es un COMPROMISO, no una
//       verdad (por eso los 30 min son una elección).
// Si una hipótesis no se cumple, el informe lo dice. Una sola familia de semillas; sin ajustar nada tras ver los resultados.
// DESPUÉS de ver que H4 NO se cumplía se añadió el «Diagnóstico de H4» (rotulado así en el informe): no cambia ninguna hipótesis ni ningún número.
import 'dart:io';
import 'dart:math';

import 'silence_study.dart';

String pct(double? v) => v == null ? 'n/d' : '${(v * 100).toStringAsFixed(1).replaceAll('.', ',')} %';

void main(List<String> args) {
  String opt(String name, String dflt) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : dflt;
  }

  final seeds = int.parse(opt('seeds', '20'));
  final zonesPerSeed = int.parse(opt('zones', '60'));
  final first = int.parse(opt('first-seed', '100'));
  final out = opt('out', '');
  const windows = [15, 30, 60, 120];

  final all = <StudyZone>[];
  final perSeedPrecision = <double>[];
  final markedByWindow = {for (final w in windows) w: <int>{}}; // índices globales
  var offset = 0;
  for (var s = 0; s < seeds; s++) {
    final zs = generateStudyZones(Random(first + s), zones: zonesPerSeed);
    for (final w in windows) {
      for (final i in markedSilent(zs, silenceMinutes: w)) {
        markedByWindow[w]!.add(offset + i);
      }
    }
    final c = confusionOf(zs, markedSilent(zs));
    if (c.precision != null) perSeedPrecision.add(c.precision!);
    for (final z in zs) {
      all.add(StudyZone(index: offset + z.index, rate: z.rate, blackoutAtMinute: z.blackoutAtMinute, reportMinutes: z.reportMinutes));
    }
    offset += zonesPerSeed;
  }

  Confusion over(bool Function(StudyZone) where, int window) => confusionOf(all.where(where), markedByWindow[window]!);

  final overall = over((_) => true, 30);
  final buckets = <String, bool Function(StudyZone)>{
    'λ < 1 reporte/h': (z) => z.rate < 1,
    '1 ≤ λ < 4': (z) => z.rate >= 1 && z.rate < 4,
    'λ ≥ 4 reportes/h': (z) => z.rate >= 4,
  };
  final dark = <String, bool Function(StudyZone)>{
    'apagada hace menos de 30 min': (z) => z.blackout && z.darkForMinutes! < 30,
    'apagada hace 30–60 min': (z) => z.blackout && z.darkForMinutes! >= 30 && z.darkForMinutes! < 60,
    'apagada hace 1–3 h': (z) => z.blackout && z.darkForMinutes! >= 60 && z.darkForMinutes! < 180,
    'apagada hace 3 h o más': (z) => z.blackout && z.darkForMinutes! >= 180,
  };

  final h1 = overall.precision != null && overall.precision! < 0.8;
  final lowRate = over((z) => z.rate < 1, 30);
  final h2 = lowRate.precision != null && lowRate.precision! < 0.5;
  final loud = over((z) => z.blackout && z.darkForMinutes! >= 60 && z.rate >= 4, 30);
  final h3 = loud.recall != null && loud.recall! >= 0.8;
  final fresh = over(dark['apagada hace menos de 30 min']!, 30);
  final h4 = fresh.recall != null && fresh.recall! < 0.1;
  final precs = [for (final w in windows) over((_) => true, w).precision ?? 0.0];
  final recs = [for (final w in windows) over((_) => true, w).recall ?? 0.0];
  var h5 = true;
  for (var i = 1; i < windows.length; i++) {
    if (precs[i] < precs[i - 1] - 1e-9 || recs[i] > recs[i - 1] + 1e-9) h5 = false;
  }

  final nBlackout = all.where((z) => z.blackout).length;
  final lines = <String>[
    '# T20 · La capa «Silencio»: ¿cuántas zonas marcadas son de verdad un apagón?',
    '',
    'Fecha: ${DateTime.now().toIso8601String()} · $seeds semillas (de la $first) × $zonesPerSeed zonas = ${all.length} zonas, de ellas $nBlackout con apagón · datos SINTÉTICOS de un modelo propio.',
    '',
    '**Qué se mide.** El detector real de zonas en silencio (ventana de actividad 6 h, de silencio 30 min) frente a una verdad definida **aparte**: cada zona reporta como un proceso de Poisson de tasa λ (log-uniforme entre 0,3 y 12 reportes/h), y el 30 % sufre un **apagón** en un minuto al azar tras el cual su tasa cae al 5 % (el enunciado habla de «el 95 % de los teléfonos apagados»). La verdad no usa las ventanas del detector, así que **la medición puede salir mal**.',
    '',
    '**Qué NO es.** No mide si la capa ayuda a decidir (no hubo coordinadores), ni con reportes reales: las llegadas de verdad vienen en ráfagas y no son un proceso de Poisson, y la tasa residual del 5 % es una elección. Mide cuánto confunde el detector un **rato de calma** con un **apagón** en un modelo sencillo.',
    '',
    '## Resultado general (ventana de 30 min)',
    '',
    '| | Zonas |',
    '|---|---|',
    '| Marcadas en silencio | ${overall.marked} |',
    '| …de ellas, un apagón de verdad (aciertos) | ${overall.tp} |',
    '| …de ellas, una zona que sólo estaba callada (falsas alarmas) | ${overall.fp} |',
    '| Apagones visibles que NO se marcaron | ${overall.fn} |',
    '| Apagones **invisibles** (ni un reporte en 6 h: el detector no puede verlos) | ${overall.invisibleBlackout} |',
    '| **Precisión** (de las marcadas, cuántas eran un apagón) | **${pct(overall.precision)}** (por semilla: ${pct(perSeedPrecision.reduce(min))} a ${pct(perSeedPrecision.reduce(max))}) |',
    '| **Exhaustividad** (de los apagones visibles, cuántos se marcaron) | **${pct(overall.recall)}** |',
    '',
    '## Por cuánto habla la zona (precisión y falsas alarmas)',
    '',
    '| Zona | Marcadas | Precisión | Zonas normales marcadas (falsa alarma) |',
    '|---|---|---|---|',
    for (final e in buckets.entries)
      () {
        final c = over(e.value, 30);
        final normals = c.fp + c.tn;
        return '| ${e.key} | ${c.marked} | ${pct(c.precision)} | ${pct(normals == 0 ? null : c.fp / normals)} (${c.fp} de $normals) |';
      }(),
    '',
    '## Por cuánto lleva apagada (exhaustividad)',
    '',
    '| Apagón | Visibles | Marcadas | Exhaustividad |',
    '|---|---|---|---|',
    for (final e in dark.entries)
      () {
        final c = over(e.value, 30);
        return '| ${e.key} | ${c.blackouts} | ${c.tp} | ${pct(c.recall)} |';
      }(),
    '',
    '## La ventana de silencio es un compromiso, no una verdad',
    '',
    '| Ventana de silencio | Marcadas | Precisión | Exhaustividad |',
    '|---|---|---|---|',
    for (var i = 0; i < windows.length; i++) '| ${windows[i]} min${windows[i] == 30 ? ' (la elegida)' : ''} | ${over((_) => true, windows[i]).marked} | ${pct(precs[i])} | ${pct(recs[i])} |',
    '',
    '## Las hipótesis, escritas antes de correr',
    '',
    '| | Hipótesis | Resultado |',
    '|---|---|---|',
    '| H1 | Precisión global < 80 % con 30 min | ${h1 ? '✓ se cumple' : '✗ NO se cumple'} (${pct(overall.precision)}) |',
    '| H2 | Precisión < 50 % en zonas con λ < 1/h | ${h2 ? '✓ se cumple' : '✗ NO se cumple'} (${pct(lowRate.precision)}) |',
    '| H3 | Exhaustividad ≥ 80 % en apagones de ≥ 60 min con λ ≥ 4/h | ${h3 ? '✓ se cumple' : '✗ NO se cumple'} (${pct(loud.recall)}) |',
    '| H4 | Los apagones de < 30 min casi no se marcan (< 10 %) | ${h4 ? '✓ se cumple' : '✗ NO se cumple'} (${pct(fresh.recall)}) |',
    '| H5 | Más ventana ⇒ más precisión y menos exhaustividad (monótono) | ${h5 ? '✓ se cumple' : '✗ NO se cumple'} |',
    '',
    '## Diagnóstico de H4 (añadido DESPUÉS de ver que no se cumplía)',
    '',
    'H4 esperaba que un apagón de menos de 30 min casi no se marcara. Se marcó el ${pct(fresh.recall)}: no porque el detector «vea» el apagón, sino porque esas zonas **ya estaban calladas** (su último reporte era anterior). Según cuánto hablaba la zona antes de apagarse:',
    '',
    '| Apagón de menos de 30 min en una zona con… | Visibles | Marcadas | % marcadas |',
    '|---|---|---|---|',
    for (final e in buckets.entries)
      () {
        final c = over((z) => z.blackout && z.darkForMinutes! < 30 && e.value(z), 30);
        return '| ${e.key} | ${c.blackouts} | ${c.tp} | ${pct(c.recall)} |';
      }(),
    '',
    'Es decir: la «detección» de un apagón reciente es en buena parte **coincidencia con una zona que ya callaba**, no un aviso del apagón; y la capa necesita al menos lo que dura su ventana para poder decir algo de un apagón nuevo. **Muestra pequeña** (${fresh.blackouts} apagones recientes visibles en total): léase como indicio, no como cifra.',
    '',
    '## Qué dice esto del producto',
    '',
    'La capa **no distingue un apagón de un rato de calma**: la precisión depende de cuánto hable la zona (arriba). Por eso el rótulo empieza por «el silencio no es seguridad» y cada zona dice cuántos reportes tuvo: una marca sobre una zona poco habladora es una **pregunta** para el coordinador, no una conclusión. Y una zona sin marca puede ser un apagón que el detector no ve (los invisibles, los recientes y los que conservan el 5 % que todavía reporta).',
    '',
    '## Límites',
    '',
    '- Un modelo sencillo del mismo autor (Poisson; apagón con tasa residual fija); lo real viene en ráfagas y con otras correlaciones espaciales.',
    '- Una zona = una celda, sin cruce de fronteras de celda; una sola familia de semillas; los umbrales de las hipótesis son míos.',
    '- No mide utilidad para el coordinador ni el coste de una falsa alarma frente a un apagón perdido.',
    '',
    '## Cómo se reproduce',
    '',
    '```',
    'cd apps/node && dart run tool/t20_silencio.dart --seeds $seeds --zones $zonesPerSeed --first-seed $first --out ../../docs/resultados/t20-silencio.md',
    '```',
    '',
  ];
  final text = lines.join('\n');
  stdout.writeln(text);
  if (out.isNotEmpty) File(out).writeAsStringSync(text);
}
