// Genera docs/resultados/b2.md con las mediciones T02 (bytes), T03 (pérdida) y T04 (ventanas)
// en tiempo virtual. Uso:  dart run packages/sim/bin/transport_report.dart [ruta/de/salida.md]
import 'dart:io';

import 'package:sard_sim/sard_sim.dart';

String fmt(Duration d) {
  final s = d.inMilliseconds / 1000;
  if (s < 1) return '${d.inMilliseconds} ms';
  if (s < 120) return '${s.toStringAsFixed(1)} s';
  if (s < 7200) return '${(s / 60).toStringAsFixed(1)} min';
  return '${(s / 3600).toStringAsFixed(1)} h';
}

double mean(Iterable<num> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

Future<void> main(List<String> args) async {
  final out = args.isNotEmpty ? args.first : 'docs/resultados/b2.md';
  const seeds = [1, 2, 3, 4, 5];
  final b = StringBuffer()
    ..writeln('# Resultados de B2 · transporte (T02–T04)')
    ..writeln()
    ..writeln('Generado con `dart run packages/sim/bin/transport_report.dart` · tiempo **virtual** (el reloj salta al siguiente vencimiento), 5 semillas por fila, planificador con su espera real (2 s base, 300 s tope), cuota 1/5 y envejecimiento de 10 min.')
    ..writeln()
    ..writeln('El «nodo» es en memoria pero usa el protocolo real (decodifica, valida y responde un ACK real); no hay red ni radio de verdad.')
    ..writeln();

  // T02
  final t02 = await runLossScenario(loss: 0, reports: 20, seed: 1);
  b
    ..writeln('## T02 · bytes por reporte confirmado')
    ..writeln()
    ..writeln('| Caso | Resultado | Meta sugerida |')
    ..writeln('|---|---|---|')
    ..writeln('| SOS mínimo con ubicación, sin pérdida | **${t02.stats.bytesPerAcked!.toStringAsFixed(1)} B** (ida ${t02.stats.bytesOut ~/ t02.stats.acked} + vuelta ${t02.stats.bytesIn ~/ t02.stats.acked}) | trama ≤ 40 B |')
    ..writeln();

  // T03
  b
    ..writeln('## T03 · entrega bajo pérdida (20 reportes: 10 P1 y 10 P4)')
    ..writeln()
    ..writeln('Pérdida en la ida = `p`; en la respuesta, `p/2`; 5 % de duplicados. Horizonte: 6 h virtuales.')
    ..writeln()
    ..writeln('| Pérdida | Entregados | Tiempo hasta el último | P1 p50 / p95 | P4 p50 / p95 | Bytes por acuse |')
    ..writeln('|---|---|---|---|---|---|');
  for (final loss in [0.0, 0.3, 0.6, 0.9]) {
    final rs = [for (final s in seeds) await runLossScenario(loss: loss, reports: 20, seed: s)];
    final p1 = [for (final r in rs) ...r.p1Latencies];
    final p4 = [for (final r in rs) ...r.otherLatencies];
    b.writeln('| ${(loss * 100).round()} % | ${(mean(rs.map((r) => r.ratio)) * 100).toStringAsFixed(0)} % | ${fmt(Duration(milliseconds: mean(rs.map((r) => r.elapsed.inMilliseconds)).round()))} | ${fmt(percentile(p1, .5))} / ${fmt(percentile(p1, .95))} | ${fmt(percentile(p4, .5))} / ${fmt(percentile(p4, .95))} | ${mean(rs.map((r) => r.stats.bytesPerAcked ?? 0)).toStringAsFixed(1)} |');
  }
  b.writeln();

  // T04
  b
    ..writeln('## T04 · ventanas breves (3 s abiertas de cada 60 s; 100 SOS en instantes aleatorios)')
    ..writeln()
    ..writeln('«Primera ventana» = antes de que se cierre la primera ventana abierta en o después de crear el reporte.')
    ..writeln()
    ..writeln('| Pérdida dentro de la ventana | Libera esperas al abrirse | Salen en la primera ventana | Entregados al final | Latencia p50 / p95 |')
    ..writeln('|---|---|---|---|---|');
  for (final loss in [0.0, 0.3, 0.6]) {
    for (final release in [true, false]) {
      final rs = [for (final s in seeds) await runWindowScenario(reports: 100, seed: s, lossInWindow: loss, releaseBackoffOnOpen: release)];
      final lat = [for (final r in rs) ...r.latencies];
      b.writeln('| ${(loss * 100).round()} % | ${release ? 'sí' : 'no'} | ${(mean(rs.map((r) => r.firstWindowRatio)) * 100).toStringAsFixed(1)} % | ${(mean(rs.map((r) => r.deliveredEventually / r.total)) * 100).toStringAsFixed(0)} % | ${fmt(percentile(lat, .5))} / ${fmt(percentile(lat, .95))} |');
    }
  }
  b
    ..writeln()
    ..writeln('## Qué significan estas cifras (y qué no)')
    ..writeln()
    ..writeln('- Demuestran el **comportamiento del planificador y la bandeja** (prioridad, cuota, espera, liberación al volver la señal), no el rendimiento de una radio real.')
    ..writeln('- Los canales son simulados: pérdida independiente por trama y ventanas ideales. Una radio real pierde en ráfagas y las ventanas no son tan limpias.')
    ..writeln('- «Libera esperas = no» muestra lo que se perdería si el reintento de un reporte cayera fuera de la ventana: por eso la app libera las esperas al volver la conectividad.');
  final f = File(out)..parent.createSync(recursive: true);
  f.writeAsStringSync(b.toString());
  stdout.writeln('escrito $out');
}
