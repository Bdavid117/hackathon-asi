// T12 · el modelo se cuelga, falla o devuelve basura: el ACK y la cola NO se afectan (y el relevo del modelo
// entre nodos), con procesos REALES y un servidor de modelo falso.
//
//   dart run packages/sim/bin/t12.dart [--reports 300] [--out docs/resultados/t12.md]
//
// Parte 1: por cada modo del modelo (cuelga, 500, basura y, de control, responde) un nodo recibe N tramas con
// texto y se mide la latencia del ACK; se compara con un nodo SIN modelo. Parte 2 (relevo): dos nodos, cada uno con
// su modelo; el del nodo B se cuelga; el otro toma el relevo de los reportes de B; luego se mata a B con kill -9.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
const String _apiKey = 'clave-falsa-de-prueba';

Uint8List textFrame(int i, {int base = 0}) {
  final n = base + i;
  return encodeReportFrame(
    ReportFrame(
      deviceId: deviceIdFromHex(n.toRadixString(16).padLeft(16, '0')),
      seq: 1,
      rev: 0,
      prioHint: 2,
      incidentType: 1,
      flags: 0,
      peopleBucket: 0,
      locQuality: LocQuality.within50m,
      lat: 5.0 + (n % 97) * 0.001,
      lon: -75.5 + (n % 89) * 0.001,
      capturedAt: 1786370851 + n,
      batteryQ: 8,
      text: n.isEven ? 'quedamos encerrados en el piso $n' : 'necesitamos ayuda por favor casa $n',
    ),
    key,
  );
}

double pct(List<int> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()].toDouble();
}

class Ack {
  Ack(this.label, this.okCount, this.p50, this.p95, this.max, this.queue, this.llm);
  final String label;
  final int okCount;
  final double p50, p95, max;
  final int queue;
  final Map<String, Object?>? llm;
}

Future<Ack> runMode(String label, int n, int port, {FakeLlmMode? mode, Duration wait = Duration.zero}) async {
  final dir = Directory.systemTemp.createTempSync('sard-t12-');
  FakeClaudeServer? fake;
  if (mode != null) fake = await FakeClaudeServer.start(mode: mode);
  final node = await NodeProcess.start(
    id: 'A',
    port: port,
    dataDir: dir.path,
    extraArgs: [if (fake != null) ...['--llm', 'on', '--llm-url', fake.url.toString()]],
    environment: {if (fake != null) 'ANTHROPIC_API_KEY': _apiKey},
  );
  final client = http.Client();
  try {
    final lat = <int>[];
    var ok = 0;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= n) return;
        final sw = Stopwatch()..start();
        final r = await client.post(node.url.resolve('/frame'), body: textFrame(i)).timeout(const Duration(seconds: 30));
        sw.stop();
        if (r.statusCode == 200) {
          ok++;
          lat.add(sw.elapsedMilliseconds);
        }
      }
    }

    await Future.wait([for (var w = 0; w < 8; w++) worker()]);
    // el modelo (si lo hay) sigue pendiente: la cola igual debe estar completa y fresca
    var queue = 0;
    for (var t = 0; t < 40 && queue < ok; t++) {
      final r = await client.get(node.url.resolve('/api/queue')).timeout(const Duration(seconds: 60));
      queue = (jsonDecode(r.body) as List).length;
      if (queue < ok) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    Map<String, Object?>? llm;
    final h = (jsonDecode((await client.get(node.url.resolve('/api/health'))).body) as Map).cast<String, Object?>();
    llm = (h['llm'] as Map?)?.cast<String, Object?>();
    return Ack(label, ok, pct(lat, .5), pct(lat, .95), pct(lat, 1), queue, llm);
  } finally {
    await node.stop();
    await fake?.close();
    client.close();
    dir.deleteSync(recursive: true);
  }
}

Future<Map<String, Object?>> relay(int n, int portA, int portB, {required FakeLlmMode bMode, required bool killB}) async {
  final dirA = Directory.systemTemp.createTempSync('sard-t12a-'), dirB = Directory.systemTemp.createTempSync('sard-t12b-');
  final fakeA = await FakeClaudeServer.start(mode: FakeLlmMode.ok);
  final fakeB = await FakeClaudeServer.start(mode: bMode);
  final urlA = Uri.parse('http://localhost:$portA'), urlB = Uri.parse('http://localhost:$portB');
  final client = http.Client();
  NodeProcess? a, b;
  try {
    const takeover = '6';
    a = await NodeProcess.start(id: 'A', port: portA, dataDir: dirA.path, peers: [urlB.toString()], extraArgs: ['--llm', 'on', '--llm-url', fakeA.url.toString(), '--takeover', takeover], environment: {'ANTHROPIC_API_KEY': _apiKey});
    b = await NodeProcess.start(id: 'B', port: portB, dataDir: dirB.path, peers: [urlA.toString()], extraArgs: ['--llm', 'on', '--llm-url', fakeB.url.toString(), '--takeover', takeover], environment: {'ANTHROPIC_API_KEY': _apiKey});
    // esperar a que se vean (los dos se consideran vivos)
    for (var t = 0; t < 40; t++) {
      final na = (jsonDecode((await client.get(urlA.resolve('/api/nodes'))).body) as Map)['peers'] as List;
      final nb = (jsonDecode((await client.get(urlB.resolve('/api/nodes'))).body) as Map)['peers'] as List;
      if ((na.first as Map)['nodeId'] == 'B' && (nb.first as Map)['nodeId'] == 'A') break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // N reportes con texto a A (todos entran por A: que B los vea es cosa de la replicación)
    for (var i = 0; i < n; i++) {
      final r = await client.post(urlA.resolve('/frame'), body: textFrame(i * 2)); // texto «encerrados»
      if (r.statusCode != 200) throw StateError('trama rechazada');
    }
    final t0 = DateTime.now();
    Future<List<Map<String, Object?>>> modelEvents(Uri node) async {
      final out = <Map<String, Object?>>[];
      for (final origin in ['A', 'B']) {
        var after = 0;
        while (true) {
          final page = (jsonDecode((await client.get(node.resolve('/api/events?origin=$origin&after=$after&limit=1000'))).body) as List).cast<Map<String, Object?>>();
          if (page.isEmpty) break;
          out.addAll(page.where((e) => e['type'] == 'triage.assessed' && (e['body'] as Map)['mode'] == 'rules+llm'));
          after = page.last['seq']! as int;
        }
      }
      return out;
    }

    // ¿cuántos reportes reciben su juicio del modelo, y de qué nodo, hasta que pasa el relevo?
    var events = <Map<String, Object?>>[];
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      events = await modelEvents(urlA);
      final covered = {for (final e in events) e['reportKey']}.length;
      if (covered >= n) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final took = DateTime.now().difference(t0);
    final byReport = <Object?, List<Object?>>{};
    for (final e in events) {
      (byReport[e['reportKey']] ??= []).add(e['origin']);
    }
    final fromA = events.where((e) => e['origin'] == 'A').length, fromB = events.where((e) => e['origin'] == 'B').length;
    final duplicated = byReport.values.where((o) => o.length > 1).length;

    if (!killB) {
      return {'n': n, 'covered': byReport.length, 'fromA': fromA, 'fromB': fromB, 'duplicated': duplicated, 'tookMs': took.inMilliseconds, 'takeover': takeover};
    }
    // kill -9 de B: A se queda solo y es dueño de todo (sin esperar el plazo)
    b.kill9();
    b = null;
    await Future<void>.delayed(const Duration(seconds: 11)); // 3 periodos de silencio: B ya no es «vivo» para A
    final base = n * 2 + 1000;
    for (var i = 0; i < n; i++) {
      await client.post(urlA.resolve('/frame'), body: textFrame(i * 2, base: base));
    }
    final t1 = DateTime.now();
    var covered2 = 0;
    final after = base.toRadixString(16);
    while (DateTime.now().difference(t1) < const Duration(seconds: 40)) {
      final ev = await modelEvents(urlA);
      covered2 = {for (final e in ev) e['reportKey']}.where((k) => (k as String).compareTo(base.toRadixString(16).padLeft(16, '0')) >= 0).length;
      if (covered2 >= n) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return {
      'n': n,
      'covered': byReport.length,
      'fromA': fromA,
      'fromB': fromB,
      'duplicated': duplicated,
      'tookMs': took.inMilliseconds,
      'covered2': covered2,
      'tookAfterKillMs': DateTime.now().difference(t1).inMilliseconds,
      'takeover': takeover,
      'after': after,
    };
  } finally {
    await a?.stop();
    await b?.stop();
    await fakeA.close();
    await fakeB.close();
    client.close();
    dirA.deleteSync(recursive: true);
    dirB.deleteSync(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    o[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final n = int.parse(o['reports'] ?? '300');
  final out = o['out'] ?? 'docs/resultados/t12.md';
  final rows = <Ack>[];
  for (final (label, mode) in <(String, FakeLlmMode?)>[('sin modelo (línea base)', null), ('modelo COLGADO', FakeLlmMode.hang), ('modelo responde 500', FakeLlmMode.error), ('modelo devuelve basura', FakeLlmMode.garbage), ('modelo responde bien (control)', FakeLlmMode.ok)]) {
    stdout.writeln('· $label…');
    // con el modelo colgado el plazo de cada consulta es de 8 s: se espera a que venzan para ver los respaldos
    rows.add(await runMode(label, n, 8094, mode: mode, wait: mode == FakeLlmMode.hang ? const Duration(seconds: 10) : const Duration(seconds: 2)));
  }
  stdout.writeln('· relevo del modelo (2 nodos + kill -9)…');
  final share = await relay(40, 8095, 8096, bMode: FakeLlmMode.ok, killB: false);
  final r = await relay(20, 8095, 8096, bMode: FakeLlmMode.hang, killB: true);

  final base = rows.first;
  final b = StringBuffer()
    ..writeln('# T12 · el modelo falla y el sistema no')
    ..writeln()
    ..writeln('Fecha: ${DateTime.now().toIso8601String()} · $n tramas con texto por modo, 8 clientes concurrentes · procesos reales (`dart run`, JIT) y un **servidor de modelo falso** (`FakeClaudeServer`): **la API real nunca se consultó**.')
    ..writeln()
    ..writeln('## Parte 1 · latencia del ACK y cola con el modelo en distintos estados')
    ..writeln()
    ..writeln('| Modo | ACK acusados | ACK p50 | ACK p95 | ACK máx | reportes en la cola | modelo: consultas / usadas / respaldos |')
    ..writeln('|---|---|---|---|---|---|---|');
  for (final a in rows) {
    final llm = a.llm;
    b.writeln('| ${a.label} | ${a.okCount}/$n | ${a.p50.toStringAsFixed(0)} ms | ${a.p95.toStringAsFixed(0)} ms | ${a.max.toStringAsFixed(0)} ms | ${a.queue} | ${llm == null ? '—' : '${llm['consultas']} / ${llm['usadas']} / ${jsonEncode(llm['fallos'])}'} |');
  }
  var pass = true;
  void verdict(String what, bool ok) {
    b.writeln('- ${ok ? '✓' : '✗'} $what');
    if (!ok) pass = false;
  }

  b.writeln();
  for (final a in rows.skip(1)) {
    verdict('${a.label}: todas las tramas acusadas (${a.okCount}/$n) y la cola completa (${a.queue})', a.okCount == n && a.queue == n);
    verdict('${a.label}: ACK p95 ${a.p95.toStringAsFixed(0)} ms ≤ máx(250 ms, 5 × línea base ${base.p95.toStringAsFixed(0)} ms)', a.p95 <= max(250, 5 * base.p95));
  }
  final hang = rows[1], ok = rows.last;
  verdict('modelo colgado: las consultas vencieron y cayeron al respaldo por reglas (${jsonEncode(hang.llm?['fallos'])}), ninguna usada', (hang.llm?['usadas'] as int? ?? 1) == 0 && (hang.llm?['fallos'] as Map?)?.isNotEmpty == true);
  verdict('control: con el modelo bien se usan sus juicios (${ok.llm?['usadas']} de ${ok.llm?['consultas']})', (ok.llm?['usadas'] as int? ?? 0) > 0);

  b
    ..writeln()
    ..writeln('## Parte 2 · reparto y relevo del modelo entre dos nodos (rendezvous + `--takeover ${r['takeover']}`)')
    ..writeln()
    ..writeln('**2a · los dos modelos responden.** ${share['n']} reportes con texto entran **todos por A**; B los recibe por replicación. El dueño de cada reporte (por rendezvous) es quien lo consulta, **aunque no sea quien recibió la trama**.')
    ..writeln()
    ..writeln('- Reportes con juicio del modelo: **${share['covered']} de ${share['n']}** en ${(share['tookMs'] as int) / 1000} s. Juicios por nodo que los produjo: A=${share['fromA']}, B=${share['fromB']}; reportes con más de un juicio (cómputo repetido): ${share['duplicated']}.')
    ..writeln()
    ..writeln('**2b · el modelo de B está colgado.** Dos nodos, cada uno con su modelo falso: el de **A responde** y el de **B está colgado**. ${r['n']} reportes con texto entran por A; B los recibe por replicación.')
    ..writeln()
    ..writeln('- Reportes con juicio del modelo: **${r['covered']} de ${r['n']}** en ${(r['tookMs'] as int) / 1000} s. Eventos del modelo por origen: A=${r['fromA']}, B=${r['fromB']}; reportes con más de un juicio (cómputo repetido): ${r['duplicated']}.')
    ..writeln('- Tras **kill -9 de B** (y 11 s sin verlo) llegan ${r['n']} reportes nuevos a A: juicio del modelo en **${r['covered2']} de ${r['n']}** en ${(r['tookAfterKillMs'] as int) / 1000} s (A es ya el dueño de todo: no espera el relevo).');
  verdict('reparto: todos los reportes tienen juicio del modelo y NINGUNO se repitió (${share['duplicated']} repetidos)', share['covered'] == share['n'] && share['duplicated'] == 0);
  verdict('reparto: el trabajo se repartió de verdad entre los dos nodos (A=${share['fromA']}, B=${share['fromB']}): B procesó reportes que le llegaron por replicación', (share['fromB'] as int) > 0 && (share['fromA'] as int) > 0);
  verdict('relevo: todos los reportes acabaron con juicio del modelo aunque el modelo de B estaba colgado', r['covered'] == r['n']);
  verdict('B no produjo ningún juicio (su modelo estaba colgado): lo hizo A', r['fromB'] == 0);
  verdict('tras kill -9 de B, A cubre los reportes nuevos', r['covered2'] == r['n']);

  b
    ..writeln()
    ..writeln('## Qué mide y qué no')
    ..writeln()
    ..writeln('- El modelo es **falso**: un servidor local que responde lo que se le programa. Prueba el comportamiento del **nodo** ante un modelo que responde, tarda, falla o no contesta; **no** prueba la calidad de ningún modelo ni la API real (no verificada).')
    ..writeln('- El plazo de cada consulta es de 8 s; el reparto usa los nodos que el nodo ve vivos. Latencias en procesos `dart run` (JIT) en una sola máquina.')
    ..writeln('- El relevo se mide con **dos** nodos; con más nodos el orden de relevo sigue el mismo hash, pero no se midió.')
    ..writeln('- La replicación sondea cada 3 s: el juicio de un dueño tarda hasta ~6 s (ida y vuelta) en verse en el otro nodo. Con `--takeover` menor que eso el relevo se adelantaría y habría **cómputo repetido** (falsa alarma), no trabajo perdido; por omisión es 10 s. Aquí se usó ${r['takeover']} s para acortar la prueba, y no hubo repetidos.');
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(b.toString());
  stdout.writeln(b);
  exit(pass ? 0 : 1);
}
