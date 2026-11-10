// T17 · contradicciones entre reportes (agente 3, sin modelo de lenguaje).
//
//   dart run packages/sim/bin/t17_contradicciones.dart [--out docs/resultados/t17-contradicciones.md]
//
// Qué mide. `detectContradictions` (negación explícita y personas incompatibles) sobre los sucesos REALES del generador
// sintético (agrupados por la verdad de referencia, no por el agrupamiento del nodo), con tres condiciones:
//   · NATURALES: los grupos tal como salen del generador. Aquí cualquier contradicción es un falso positivo (el
//     generador no inyecta contradicciones).
//   · INYECTADAS: en la mitad de los grupos que lo permiten, un reporte pasa a negar («sin heridos»…) una señal que OTRO
//     miembro afirma. Hay verdad de referencia: tiene que detectarse.
//   · SEÑUELOS (controles negativos adversariales): en otros grupos un reporte niega una señal que NADIE afirma. No es
//     una contradicción: NO debe detectarse.
//
// CRITERIO DE ADOPCIÓN (escrito y commiteado ANTES de ejecutar; las semillas 801–805 no se han usado para nada):
//   (1) recall sobre las inyectadas ≥ 95 %;
//   (2) falsos positivos sobre los grupos NATURALES ≤ 1 %;
//   (3) falsos positivos sobre los SEÑUELOS ≤ 1 %.
// Si falla alguno, la función NO se ofrece como «contradicciones evaluadas» en el nodo y se reporta como no cumplida.
//
// Límites que el informe debe decir, pase o no pase: los datos los generó el mismo autor que las reglas; el generador no
// trae cantidades de personas, así que NO se mide la clase «personas» (sólo sus pruebas unitarias); y se usan los grupos de
// la verdad de referencia, no los que arma el nodo (que casi no fusiona), por lo que NO se sabe cuántos grupos reales la
// dispararían en la práctica.
import 'dart:io';
import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';

const List<int> kSeeds = [801, 802, 803, 804, 805];
const double kMinRecall = 0.95;
const double kMaxFalsePositive = 0.01;

/// La negación que se inyecta para cada señal (las que el léxico sabe negar).
const Map<String, String> kNegation = {'herido': 'sin heridos', 'atrapado': 'no hay atrapados', 'incendio': 'sin fuego'};
const Map<String, int> kBit = {'herido': SituationFlags.herido, 'atrapado': SituationFlags.atrapado, 'incendio': SituationFlags.incendio};

/// Qué señales negables afirma un reporte (por bandera o por texto).
Set<String> asserted(SynthReport r) => {
  for (final e in kBit.entries)
    if (r.flags & e.value != 0) e.key,
  for (final s in textSignals(r.text ?? '')) if (kNegation.containsKey(s.code)) s.code,
};

class Tally {
  int groups = 0, naturalFlagged = 0, injected = 0, injectedDetected = 0, injectSkipped = 0, decoys = 0, decoyFlagged = 0, decoySkipped = 0;
}

ReportFacts facts(SynthReport r, {String? text}) => ReportFacts(reportKey: r.reportKey, flags: r.flags, text: text ?? r.text);

/// El veredicto del criterio, aplicado por código (no a ojo).
({bool recall, bool natural, bool decoy, bool all}) decideT17(Tally t) {
  final recall = t.injected > 0 && t.injectedDetected / t.injected >= kMinRecall;
  final natural = t.groups > 0 && t.naturalFlagged / t.groups <= kMaxFalsePositive;
  final decoy = t.decoys > 0 && t.decoyFlagged / t.decoys <= kMaxFalsePositive;
  return (recall: recall, natural: natural, decoy: decoy, all: recall && natural && decoy);
}

Tally measure(int seed) {
  final ds = generateDataset(SynthConfig(seed: seed, incidents: 80, reports: 1000, adversarialPairs: 20));
  final byIncident = <int, List<SynthReport>>{};
  for (final r in ds.reports) {
    (byIncident[r.trueIncident] ??= []).add(r);
  }
  final rnd = Random(seed);
  final t = Tally();
  for (final entry in byIncident.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    final members = [...entry.value]..sort((a, b) => a.reportKey.compareTo(b.reportKey));
    if (members.length < 2) continue;
    t.groups++;
    final natural = [for (final m in members) facts(m)];
    if (detectContradictions(natural).isNotEmpty) t.naturalFlagged++;

    final mode = rnd.nextInt(2); // 0: inyectar una contradicción verdadera; 1: un señuelo
    if (mode == 0) {
      // Una señal negable que afirma algún miembro B, y otro miembro A (≠ B) que pasa a negarla.
      String? signal;
      SynthReport? b;
      for (final s in kNegation.keys) {
        for (final m in members) {
          if (asserted(m).contains(s)) {
            signal = s;
            b = m;
            break;
          }
        }
        if (signal != null) break;
      }
      if (signal == null) {
        t.injectSkipped++;
        continue;
      }
      final a = members.firstWhere((m) => m.reportKey != b!.reportKey);
      final mutated = [for (final m in members) m.reportKey == a.reportKey ? facts(m, text: kNegation[signal]) : facts(m)];
      t.injected++;
      if (detectContradictions(mutated).any((c) => c.kind == 'negacion' && c.code == signal)) t.injectedDetected++;
    } else {
      // Señuelo: una señal negable que NINGÚN miembro afirma, negada por uno; no es una contradicción.
      final all = {for (final m in members) ...asserted(m)};
      final free = [for (final s in kNegation.keys) if (!all.contains(s)) s];
      if (free.isEmpty) {
        t.decoySkipped++;
        continue;
      }
      final signal = free[rnd.nextInt(free.length)];
      final a = members[rnd.nextInt(members.length)];
      final mutated = [for (final m in members) m.reportKey == a.reportKey ? facts(m, text: kNegation[signal]) : facts(m)];
      t.decoys++;
      if (detectContradictions(mutated).any((c) => c.kind == 'negacion')) t.decoyFlagged++;
    }
  }
  return t;
}

String pct(int a, int b) => b == 0 ? 'n/d' : '${(100 * a / b).toStringAsFixed(2).replaceAll('.', ',')} %';

void main(List<String> args) {
  final outIndex = args.indexOf('--out');
  final out = outIndex >= 0 ? args[outIndex + 1] : null;
  final rows = {for (final s in kSeeds) s: measure(s)};
  final total = Tally();
  for (final t in rows.values) {
    total
      ..groups += t.groups
      ..naturalFlagged += t.naturalFlagged
      ..injected += t.injected
      ..injectedDetected += t.injectedDetected
      ..injectSkipped += t.injectSkipped
      ..decoys += t.decoys
      ..decoyFlagged += t.decoyFlagged
      ..decoySkipped += t.decoySkipped;
  }
  final v = decideT17(total);
  final b = StringBuffer()
    ..writeln('# T17 · contradicciones entre reportes (sin modelo)')
    ..writeln()
    ..writeln('Semillas ${kSeeds.join(', ')} (nuevas: no se usaron para calibrar nada). Grupos = los sucesos reales del generador con ≥ 2 reportes.')
    ..writeln()
    ..writeln('| Semilla | Grupos | Naturales con contradicción (falsos +) | Inyectadas | Detectadas | Señuelos | Señuelos detectados (falsos +) |')
    ..writeln('|---|---|---|---|---|---|---|');
  for (final e in rows.entries) {
    final t = e.value;
    b.writeln('| ${e.key} | ${t.groups} | ${t.naturalFlagged} | ${t.injected} | ${t.injectedDetected} | ${t.decoys} | ${t.decoyFlagged} |');
  }
  b
    ..writeln('| **Total** | **${total.groups}** | **${total.naturalFlagged}** | **${total.injected}** | **${total.injectedDetected}** | **${total.decoys}** | **${total.decoyFlagged}** |')
    ..writeln()
    ..writeln('| Criterio (fijado antes de medir) | Resultado | ¿Cumple? |')
    ..writeln('|---|---|---|')
    ..writeln('| (1) recall sobre las inyectadas ≥ ${(kMinRecall * 100).round()} % | ${pct(total.injectedDetected, total.injected)} | ${v.recall ? 'sí' : 'NO'} |')
    ..writeln('| (2) falsos positivos sobre los grupos naturales ≤ ${(kMaxFalsePositive * 100).round()} % | ${pct(total.naturalFlagged, total.groups)} | ${v.natural ? 'sí' : 'NO'} |')
    ..writeln('| (3) falsos positivos sobre los señuelos ≤ ${(kMaxFalsePositive * 100).round()} % | ${pct(total.decoyFlagged, total.decoys)} | ${v.decoy ? 'sí' : 'NO'} |')
    ..writeln()
    ..writeln('**Veredicto aplicado por código: ${v.all ? 'cumple los tres criterios' : 'NO cumple todos los criterios'}.**')
    ..writeln()
    ..writeln('Omitidos por no poder montar el caso: ${total.injectSkipped} grupos sin ninguna señal negable afirmada (inyección) y ${total.decoySkipped} sin ninguna señal libre (señuelo).');
  final text = b.toString();
  stdout.write(text);
  if (out != null) File(out).writeAsStringSync(text);
}
