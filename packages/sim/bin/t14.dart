// T14 · indicador ESTRUCTURAL del tablero (entregable del plan B4+B5; no es la prueba con personas del PDF).
//
//   dart run packages/sim/bin/t14.dart [--seeds 401,402,403] [--reports 1000] [--incidents 80]
//        [--port 8094] [--out docs/resultados/t14.md]
//
// Por semilla: genera un conjunto sintético (por omisión 1 000 reportes en ~80 sucesos), lo envía por HTTP
// a un nodo REAL y mide, sobre lo que el nodo sirve:
//   · elementos a revisar, de arriba abajo, para haber visto TODOS los P1 en tres presentaciones:
//       (a) mensajes en orden de llegada (la línea base: un chat),
//       (b) reportes ordenados por urgencia pero sin agrupar,
//       (c) incidentes de la vista corta (lo que muestra el tablero);
//   · P1 que quedan FUERA de la vista inicial (el criterio del PDF: 0);
//   · clics hasta ver un P1 y hasta abrir su detalle.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

class Row {
  Row(this.seed, this.reports, this.incidents, this.p1Reports, this.p1Incidents, this.arrivalScan, this.flatScan, this.shortScan, this.shortRows, this.bareAggregated, this.p1Outside, this.followUp, this.p2Outside, this.trueIncidents, this.oracleP1);
  final int seed, reports, incidents, p1Reports, p1Incidents, arrivalScan, flatScan, shortScan, shortRows, bareAggregated, p1Outside, followUp, p2Outside, trueIncidents, oracleP1;
}

Future<Row> measure(int seed, int n, int incidents, int port) async {
  final ds = generateDataset(SynthConfig(seed: seed, incidents: incidents, reports: n, adversarialPairs: 0));
  final frames = synthFrames(ds.reports, key);
  final dir = Directory.systemTemp.createTempSync('sard-t14-');
  final node = await NodeProcess.start(id: 'A', port: port, dataDir: dir.path);
  final client = http.Client();
  try {
    // llegada: el orden en que se envían (secuencial: define el orden de llegada)
    final arrival = <String, int>{};
    for (var i = 0; i < frames.length; i++) {
      final r = await client.post(node.url.resolve('/frame'), body: frames[i].bytes);
      if (r.statusCode != 200) throw StateError('trama rechazada (${r.statusCode})');
      arrival[frames[i].reportKey] = i;
    }
    // el tablero lee tras un instante (la proyección se calcula al leer)
    Future<Map<String, Object?>> getJson(String path) async {
      for (var tries = 0; tries < 60; tries++) {
        final r = await client.get(node.url.resolve(path)).timeout(const Duration(seconds: 60));
        final fresh = r.headers['x-queue-stale'] == 'false';
        final body = (jsonDecode(r.body) as Map).cast<String, Object?>();
        if (fresh) return body;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw StateError('la vista no se puso al día');
    }

    final queueRaw = await client.get(node.url.resolve('/api/queue')).timeout(const Duration(seconds: 60));
    final queue = (jsonDecode(queueRaw.body) as List).cast<Map<String, Object?>>();
    final shortEnv = await getJson('/api/incidents');
    final allEnv = await getJson('/api/incidents?view=all&limit=1000');
    final shortItems = (shortEnv['items']! as List).cast<Map<String, Object?>>();
    final allItems = (allEnv['items']! as List).cast<Map<String, Object?>>();
    final counters = (shortEnv['counters']! as Map).cast<String, Object?>();

    // (a) mensajes en orden de llegada: posición (1-based) del último reporte P1
    final p1Reports = [for (final q in queue) if (q['urgency'] == 'P1') q['reportKey']! as String];
    final arrivalScan = p1Reports.isEmpty ? 0 : p1Reports.map((k) => arrival[k]! + 1).reduce(max);
    // (b) reportes por urgencia, sin agrupar: los P1 van primero, así que basta contarlos
    final flatScan = p1Reports.length;
    // (c) incidentes de la vista corta: los P1 son la cabecera; basta llegar a la última fila P1
    var shortScan = 0;
    for (var i = 0; i < shortItems.length; i++) {
      if (shortItems[i]['urgency'] == 'P1') shortScan = i + 1;
    }
    final p1All = allItems.where((i) => i['urgency'] == 'P1').map((i) => i['id']).toSet();
    final p1Short = shortItems.where((i) => i['urgency'] == 'P1').map((i) => i['id']).toSet();
    final p2All = allItems.where((i) => i['urgency'] == 'P2').map((i) => i['id']).toSet();
    final p2Short = shortItems.where((i) => i['urgency'] == 'P2').map((i) => i['id']).toSet();
    // Techo con agrupamiento PERFECTO (verdad del generador): sucesos reales que son P1 de verdad.
    final trueP1 = {for (final r in ds.reports) if (r.trueUrgency.name == 'p1') r.trueIncident};
    final trueAll = {for (final r in ds.reports) r.trueIncident};
    return Row(seed, queue.length, allItems.length, p1Reports.length, p1All.length, arrivalScan, flatScan, shortScan, shortItems.length, counters['bareSos']! as int, p1All.difference(p1Short).length, counters['followUp']! as int, p2All.difference(p2Short).length, trueAll.length, trueP1.length);
  } finally {
    await node.stop();
    client.close();
    dir.deleteSync(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    o[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final seeds = (o['seeds'] ?? '401,402,403,404,405').split(',').map(int.parse).toList();
  final n = int.parse(o['reports'] ?? '1000');
  final inc = int.parse(o['incidents'] ?? '80');
  final port = int.parse(o['port'] ?? '8094');
  final out = o['out'] ?? 'docs/resultados/t14.md';

  final rows = <Row>[];
  for (final s in seeds) {
    stdout.writeln('· semilla $s…');
    rows.add(await measure(s, n, inc, port));
  }
  final b = StringBuffer()
    ..writeln('# T14 · indicador estructural del tablero')
    ..writeln()
    ..writeln('Fecha: ${DateTime.now().toIso8601String()} · $n reportes sintéticos en ~$inc sucesos por semilla · nodo real por HTTP · semillas ${seeds.join(', ')} (generadas después de congelar el código; no se usaron para calibrar).')
    ..writeln()
    ..writeln('**Qué mide y qué NO.** Cuenta *elementos que hay que recorrer de arriba abajo* para haber visto todos los P1 que el sistema detecta, y cuántos P1 quedan fuera de la vista inicial. Es una medida **estructural** sobre datos sintéticos: no sustituye la prueba del PDF con personas (tiempo y errores de un coordinador), que **no se hizo**.')
    ..writeln()
    ..writeln('| Semilla | Reportes | Incidentes que arma el agente (sucesos reales) | P1 (reportes) | P1 (incidentes) | (a) mensajes en orden de llegada | (b) reportes por urgencia sin agrupar | (c) vista corta del tablero | filas de la vista corta | **P1 fuera de la vista** |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|');
  for (final r in rows) {
    b.writeln('| ${r.seed} | ${r.reports} | ${r.incidents} (${r.trueIncidents}) | ${r.p1Reports} | ${r.p1Incidents} | ${r.arrivalScan} | ${r.flatScan} | **${r.shortScan}** | ${r.shortRows} (+1 fila agregada con ${r.bareAggregated} SOS sin detalle) | **${r.p1Outside}** |');
  }
  double mean(Iterable<int> xs) => xs.isEmpty ? 0 : xs.reduce((a, c) => a + c) / xs.length;
  b
    ..writeln()
    ..writeln('Promedios: (a) ${mean(rows.map((r) => r.arrivalScan)).toStringAsFixed(0)} · (b) ${mean(rows.map((r) => r.flatScan)).toStringAsFixed(0)} · (c) ${mean(rows.map((r) => r.shortScan)).toStringAsFixed(0)} elementos para cubrir todos los P1. **Techo con agrupamiento perfecto** (sucesos que son P1 de verdad, según la verdad del generador): ${mean(rows.map((r) => r.oracleP1)).toStringAsFixed(0)}.')
    ..writeln()
    ..writeln('- **P1 fuera de la vista inicial:** ${rows.map((r) => r.p1Outside).fold<int>(0, (a, c) => a + c)} en total (criterio del PDF: 0). P2 fuera de la vista: ${rows.map((r) => r.p2Outside).fold<int>(0, (a, c) => a + c)} (la vista corta incluye todos los P1 y P2 por definición).')
    ..writeln('- **Clics hasta ver un P1:** 0 (los P1 son las primeras filas de la lista); **hasta abrir su detalle:** 1; **hasta listar sólo los P1:** 1 (tocar «P1» en la barra de triaje).')
    ..writeln('- «En seguimiento fuera de la vista» (P3/P4 informativos que la vista corta no lista): ${rows.map((r) => r.followUp).join(', ')} por semilla; siguen contados y a un clic con «Ver todo».')
    ..writeln()
    ..writeln('## Cómo leerlo y sus límites')
    ..writeln()
    ..writeln('- **De dónde sale la mejora, dicho sin adornos:** de **ordenar por urgencia** ((a) → (b): de ~${mean(rows.map((r) => r.arrivalScan)).toStringAsFixed(0)} a ~${mean(rows.map((r) => r.flatScan)).toStringAsFixed(0)}). **No** viene de agrupar ((b) → (c): ~${mean(rows.map((r) => r.flatScan)).toStringAsFixed(0)} a ~${mean(rows.map((r) => r.shortScan)).toStringAsFixed(0)}), porque el agrupamiento determinista **casi no fusiona** (B3: 0,43 % de los pares verdaderos con el umbral calibrado; aquí ~${mean(rows.map((r) => r.incidents)).toStringAsFixed(0)} incidentes para ${rows.first.trueIncidents} sucesos reales). Un agrupamiento perfecto llevaría (c) a ~${mean(rows.map((r) => r.oracleP1)).toStringAsFixed(0)}: la diferencia con (c) es lo que el agrupamiento actual no logra y que el PDF reserva al modelo y a la persona.')
    ..writeln('- Con estos datos sintéticos una parte importante de los sucesos es P1 (el generador no pretende imitar una emergencia real): con una mezcla real habría menos P1 y (c) sería menor. No se afirma una cifra para el mundo real.')
    ..writeln('- «P1» es el que **el sistema** asigna (reglas), no la verdad: lo que mide la calidad del triaje es `docs/resultados/b3.md`.')
    ..writeln('- Un P1 mal agrupado (el anti-puente evita fusionar dos sucesos) aparece como dos incidentes P1: cuenta como dos elementos.');
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(b.toString());
  stdout.writeln(b);
  final outside = rows.fold<int>(0, (a, r) => a + r.p1Outside);
  exit(outside == 0 ? 0 : 1);
}
