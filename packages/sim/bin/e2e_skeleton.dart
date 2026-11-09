// Recorrido de punta a punta con pérdida de un nodo (hito H1 del plan B0/B1).
//
//   dart run packages/sim/bin/e2e_skeleton.dart [--seed 42] [--reports 60] [--loss 0.3]
//
// Arranca dos nodos reales (A y B) como procesos, envía reportes desde un cliente con
// pérdida y duplicados, mata a A con `kill -9` a mitad, lo reinicia, y comprueba que lo
// acusado está en la cola de AMBOS nodos, sin duplicados y en el mismo orden.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    opts[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final seed = int.parse(opts['seed'] ?? '42');
  final total = int.parse(opts['reports'] ?? '60');
  final loss = double.parse(opts['loss'] ?? '0.3');
  final portA = int.parse(opts['port-base'] ?? '8081');
  final portB = portA + 1;

  final data = Directory.systemTemp.createTempSync('sard-e2e-');
  final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
  final urlA = Uri.parse('http://localhost:$portA');
  final urlB = Uri.parse('http://localhost:$portB');
  final client = http.Client();
  final started = Stopwatch()..start();
  NodeProcess? a;
  NodeProcess? b;
  var exitCode = 0;

  Future<List<Map<String, Object?>>> queue(Uri node) async {
    final r = await client.get(node.resolve('/api/queue'));
    return (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
  }

  Future<Map<String, Object?>> health(Uri node) async =>
      (jsonDecode((await client.get(node.resolve('/api/health'))).body) as Map).cast<String, Object?>();


  /// Todos los eventos de un nodo (de todos los orígenes), paginando.
  Future<List<Map<String, Object?>>> allEvents(Uri node) async {
    final vv = ((await health(node))['versionVector']! as Map).cast<String, int>();
    final out = <Map<String, Object?>>[];
    for (final origin in vv.keys) {
      var after = 0;
      while (true) {
        final r = await client.get(node.resolve('/api/events?origin=$origin&after=$after&limit=1000'));
        final page = (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
        if (page.isEmpty) break;
        out.addAll(page);
        after = page.last['seq']! as int;
      }
    }
    return out;
  }

  // Recursos declarados sintéticos (el agente 6 sólo puede nombrar estos).
  final repoRoot = File.fromUri(Platform.script).parent.parent.parent.parent.path;
  final nodeArgs = ['--resources', '$repoRoot/config/recursos.json'];
  try {
    a = await NodeProcess.start(id: 'A', port: portA, dataDir: '${data.path}/A', peers: [urlB.toString()], extraArgs: nodeArgs);
    b = await NodeProcess.start(id: 'B', port: portB, dataDir: '${data.path}/B', peers: [urlA.toString()], extraArgs: nodeArgs);

    final outbox = Outbox.open(':memory:', key: key);
    Channel link(Uri node, int s) =>
        LossyChannel(HttpChannel(node, client, timeout: const Duration(seconds: 2)), seed: s, lossRequest: loss, lossResponse: loss / 2, duplicate: 0.05);
    final scheduler = SendScheduler(
      outbox: outbox,
      channel: FailoverChannel([link(urlA, seed), link(urlB, seed + 1)]),
      key: key,
      rng: Random(seed),
      backoffBase: const Duration(milliseconds: 100),
      backoffCap: const Duration(seconds: 1),
    );

    // Reportes variados; uno de cada cinco recibe además una revisión con texto.
    final rng = Random(seed);
    const flagSets = [
      SituationFlags.atrapado | SituationFlags.herido,
      SituationFlags.atrapado,
      SituationFlags.incendio,
      SituationFlags.viaBloqueada,
      SituationFlags.dificultadRespiratoria,
      0,
    ];
    final reportKeys = <String>[];
    for (var i = 0; i < total; i++) {
      final flags = flagSets[rng.nextInt(flagSets.length)];
      final withLoc = i % 3 != 0;
      final e = outbox.enqueueSos(
        NewReport(
          incidentType: 1, flags: flags, peopleBucket: rng.nextInt(5), batteryQ: 15,
          locQuality: withLoc ? LocQuality.within50m : LocQuality.none,
          lat: withLoc ? 5.0 + rng.nextDouble() / 100 : null,
          lon: withLoc ? -75.5 + rng.nextDouble() / 100 : null,
        ),
        now: DateTime.now(),
      );
      reportKeys.add(e.reportKey);
      if (i % 5 == 0) {
        outbox.enqueueRevision(
          e.reportKey,
          NewReport(incidentType: 1, flags: flags, peopleBucket: 2, batteryQ: 15, locQuality: LocQuality.none, text: 'detalle del reporte $i'),
          now: DateTime.now(),
        );
      }
    }

    // Envía hasta vaciar la bandeja; a mitad mata A y 3 s después lo reinicia.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var killed = false;
    DateTime? restartAt;
    var restarted = false;
    while (outbox.all().any((e) => e.state != OutboxState.sent)) {
      if (DateTime.now().isAfter(deadline)) throw StateError('la bandeja no se vació en 90 s');
      await scheduler.pump();
      final sentCount = outbox.all().where((e) => e.state == OutboxState.sent).length;
      if (!killed && sentCount >= outbox.all().length ~/ 2) {
        a?.kill9();
        killed = true;
        try {
          await client.get(urlA.resolve('/api/health')).timeout(const Duration(seconds: 1));
          throw StateError('el nodo A sigue respondiendo tras kill -9');
        } on http.ClientException {
          // esperado: el nodo está caído
        } on TimeoutException {
          // esperado
        } on SocketException {
          // esperado
        }
        restartAt = DateTime.now().add(const Duration(seconds: 3));
        stdout.writeln('· kill -9 al nodo A con $sentCount/${outbox.all().length} tramas acusadas');
      }
      if (killed && !restarted && DateTime.now().isAfter(restartAt!)) {
        a = await NodeProcess.start(id: 'A', port: portA, dataDir: '${data.path}/A', peers: [urlB.toString()], extraArgs: nodeArgs);
        restarted = true;
        stdout.writeln('· nodo A reiniciado (misma carpeta de datos)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!restarted) {
      a = await NodeProcess.start(id: 'A', port: portA, dataDir: '${data.path}/A', peers: [urlB.toString()], extraArgs: nodeArgs);
    }

    // Espera a que ambos nodos converjan (mismos eventos).
    final convergeBy = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final ha = await health(urlA);
      final hb = await health(urlB);
      if (jsonEncode(ha['versionVector']) == jsonEncode(hb['versionVector']) && ha['events'] == hb['events']) break;
      if (DateTime.now().isAfter(convergeBy)) throw StateError('los nodos no convergieron en 30 s: $ha vs $hb');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final qa = await queue(urlA);
    final qb = await queue(urlB);
    final keysA = [for (final i in qa) i['reportKey']! as String];
    final keysB = [for (final i in qb) i['reportKey']! as String];
    void check(bool ok, String what) {
      stdout.writeln('${ok ? '✓' : '✗'} $what');
      if (!ok) exitCode = 1;
    }

    check(reportKeys.every(keysA.contains) && reportKeys.every(keysB.contains), 'cada reporte acusado está en la cola de A y de B');
    check(keysA.toSet().length == keysA.length && keysB.toSet().length == keysB.length, 'ninguna cola tiene duplicados');
    check(jsonEncode(keysA) == jsonEncode(keysB), 'ambas colas tienen el mismo orden');
    // La cola declara su frescura (con más de 300 reportes se calcula en otro isolate y puede servirse una
    // versión anterior marcada como tal).
    final raw = await client.get(urlA.resolve('/api/queue'));
    check(
      raw.headers['x-queue-stale'] != null && int.tryParse(raw.headers['x-queue-age-ms'] ?? '') != null,
      'la cola declara su frescura (x-queue-stale=${raw.headers['x-queue-stale']}, x-queue-age-ms=${raw.headers['x-queue-age-ms']})',
    );
    // El grupo se calcula al leer sobre los reportes fusionados: tras replicar y tras un kill -9, los dos
    // nodos deben mostrar los MISMOS grupos (identificador, tamaño, fuentes y urgencia del grupo).
    Map<String, String> groupsOf(List<Map<String, Object?>> q) => {
      for (final i in q) i['reportKey']! as String: '${i['group']}|${i['groupSize']}|${i['sources']}|${i['groupUrgency']}',
    };
    check(jsonEncode(groupsOf(qa)) == jsonEncode(groupsOf(qb)), 'ambas colas muestran los mismos grupos (${qa.map((i) => i['group']).toSet().length} grupos)');
    check(keysA.length == total && keysB.length == total, 'ambas colas tienen exactamente $total reportes (A=${keysA.length}, B=${keysB.length})');
    final withText = (total + 4) ~/ 5;
    check(qa.where((i) => i['text'] != null).length == withText, 'las $withText revisiones con texto se fundieron con su reporte');

    // ── Incidentes, recomendación y aprobación (Etapas 2 y 3) sobre los dos procesos reales ──
    Future<List<Map<String, Object?>>> incidents(Uri node) async =>
        ((jsonDecode((await client.get(node.resolve('/api/incidents?view=all&limit=1000'))).body) as Map)['items'] as List).cast<Map<String, Object?>>();
    final ia = await incidents(urlA), ib = await incidents(urlB);
    String view(List<Map<String, Object?>> l) => jsonEncode([
      for (final i in l) [i['id'], i['urgency'], i['size'], (i['recommendation']! as Map)['id'], (i['recommendation']! as Map)['state']],
    ]);
    check(view(ia) == view(ib), 'ambos nodos muestran los mismos incidentes y las mismas recomendaciones (${ia.length} incidentes)');
    check(ia.fold<int>(0, (n, i) => n + (i['size']! as int)) == total, 'cada reporte está en exactamente un incidente');
    final shortEnv = (jsonDecode((await client.get(urlA.resolve('/api/incidents'))).body) as Map).cast<String, Object?>();
    final shortIds = {for (final i in shortEnv['items']! as List) (i as Map)['id']};
    check(ia.where((i) => i['urgency'] == 'P1').every((i) => shortIds.contains(i['id'])), 'ningún P1 queda fuera de la vista corta (${ia.where((i) => i['urgency'] == 'P1').length} P1)');
    final counters = (shortEnv['counters']! as Map).cast<String, Object?>();
    check(counters['incidents'] == ia.length && counters['reports'] == total, 'los contadores son sobre el total real (${counters['incidents']} incidentes, ${counters['reports']} reportes)');
    final proposed = ia.where((i) => (i['recommendation']! as Map)['state'] == 'propuesta').toList();
    check(proposed.isNotEmpty, 'hay incidentes con recomendación propuesta (${proposed.length})');
    final declared = (jsonDecode(File('$repoRoot/config/recursos.json').readAsStringSync()) as Map)['resources'] as List;
    final declaredIds = {for (final r in declared) (r as Map)['id'] as String};
    check(
      proposed.every((i) => ((i['recommendation']! as Map)['resourceIds'] as List).every(declaredIds.contains)),
      'toda recomendación nombra sólo recursos declarados',
    );
    check(
      !(await allEvents(urlA)).any((e) => (e['type'] as String).startsWith('approval.')),
      '0 aprobaciones automáticas: ningún evento de aprobación existe sin que una persona lo pida',
    );

    // Una persona aprueba en A; la decisión se replica y B la ve aprobada.
    if (proposed.isNotEmpty) {
      final target = proposed.first;
      final detail = jsonDecode((await client.get(urlA.resolve('/api/incidents/${Uri.encodeComponent(target['id']! as String)}'))).body) as Map;
      check((detail['recommendation'] as Map)['requires_approval'] == true, 'la recomendación exige aprobación humana');
      final body = jsonEncode({
        'recommendationId': (target['recommendation'] as Map)['id'],
        'incidentId': target['id'],
        'members': (detail['members'] as List).cast<String>(),
        'decision': 'granted',
        'note': 'prueba H1',
        'who': 'coordinación de prueba',
      });
      final wrong = await client.post(urlA.resolve('/api/approval'), headers: {'content-type': 'text/plain'}, body: body);
      check(wrong.statusCode == 415, 'sin content-type JSON la aprobación se rechaza con 415 (${wrong.statusCode})');
      final okResp = await client.post(urlA.resolve('/api/approval'), headers: {'content-type': 'application/json'}, body: body);
      check(okResp.statusCode == 200, 'la aprobación en A se registra (${okResp.statusCode})');
      String? seenOnB;
      final until = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(until)) {
        final row = (await incidents(urlB)).firstWhere((i) => i['id'] == target['id'], orElse: () => const {});
        seenOnB = row.isEmpty ? null : (row['approval']! as Map)['status'] as String?;
        if (seenOnB == 'aprobada') break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      check(seenOnB == 'aprobada', 'la aprobación registrada en A se replica y B la ve «aprobada» (vio: $seenOnB)');
    }

    // Estado de los nodos: tras convergir, A ve a B sincronizado y la vista no es parcial.
    Map<String, Object?>? nodesA;
    final nodesBy = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(nodesBy)) {
      nodesA = (jsonDecode((await client.get(urlA.resolve('/api/nodes'))).body) as Map).cast<String, Object?>();
      if (nodesA['partialView'] == false) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final peerStates = [for (final p in (nodesA?['peers'] as List? ?? const [])) '${(p as Map)['state']}'];
    check(nodesA?['partialView'] == false && peerStates.every((st) => st == 'sincronizado'), 'A ve a sus pares sincronizados y sin «vista parcial» (pares: $peerStates)');

    // Recepciones por (reporte, revisión): cada nodo que recibe una trama escribe la suya, así que
    // tras un reintento con failover puede haber una por nodo. La proyección las funde.
    final receipts = <String, int>{};
    for (final e in await allEvents(urlA)) {
      if (e['type'] == 'report.received') {
        final k = '${e['reportKey']}#${e['rev']}';
        receipts[k] = (receipts[k] ?? 0) + 1;
      }
    }
    final multi = receipts.values.where((n) => n > 1).length;
    final maxMult = receipts.values.fold<int>(0, max);
    stdout.writeln('· recepciones duplicadas entre nodos: $multi de ${receipts.length} (reporte, rev) con más de una (máx. $maxMult); la cola las funde');
    check(maxMult <= 2, 'ninguna trama se recibe en más de 2 nodos (hay 2 nodos)');

    final retries = outbox.all().fold<int>(0, (s, e) => s + e.attempts);
    stdout.writeln('resumen: ${outbox.all().length} tramas, $retries reintentos, semilla $seed, pérdida $loss, ${started.elapsed.inSeconds} s');
    outbox.close();
    if (exitCode == 0) stdout.writeln('H1 OK');
  } catch (e, st) {
    stderr.writeln('H1 FALLÓ: $e\n$st');
    exitCode = 1;
  } finally {
    await a?.stop();
    await b?.stop();
    client.close();
    data.deleteSync(recursive: true);
  }
  exit(exitCode);
}
