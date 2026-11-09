// Demostración con UNA condición adversa, reproducible con un comando y una semilla (entregable 7;
// T09, T10, T15). Dos nodos REALES (procesos), partición, kill -9 en pleno procesamiento, conmutación,
// reinicio con RTO medido, reconexión y comparación de huellas.
//
//   dart run packages/sim/bin/demo.dart [--seed 42] [--reports 120] [--partition-seconds 20]
//        [--port-a 8095] [--port-b 8096] [--json /ruta/resumen.json]
//
// Imprime una línea «HUELLA: <sha256>»: con la misma semilla debe ser siempre la misma (T15).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    o[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final seed = int.parse(o['seed'] ?? '42');
  final n = int.parse(o['reports'] ?? '120');
  final partition = Duration(seconds: int.parse(o['partition-seconds'] ?? '20'));
  final pa = int.parse(o['port-a'] ?? '8095'), pb = int.parse(o['port-b'] ?? '8096');
  final jsonOut = o['json'];

  final ds = generateDataset(SynthConfig(seed: seed, incidents: n ~/ 10, reports: n, adversarialPairs: 2));
  final frames = synthFrames(ds.reports, key);
  final total = frames.length;
  final dir = Directory.systemTemp.createTempSync('sard-demo-');
  final client = http.Client();
  final t0 = DateTime.now();
  final failures = <String>[];
  void check(bool ok, String what) {
    stdout.writeln('${ok ? '✓' : '✗'} $what');
    if (!ok) failures.add(what);
  }

  String stamp() => '${DateTime.now().difference(t0).inMilliseconds / 1000}'.padLeft(5);
  void say(String s) => stdout.writeln('[${stamp()} s] $s');

  Uri urlOf(NodeProcess? x, int port) => Uri.parse('http://localhost:$port');
  final urlA = urlOf(null, pa), urlB = urlOf(null, pb);

  say('DEMO semilla=$seed · $total reportes sintéticos (${ds.incidents.length} sucesos) · partición de ${partition.inSeconds} s');
  say('Fase 0 · dos nodos A y B SIN pares: la red está partida');
  var a = await NodeProcess.start(id: 'A', port: pa, dataDir: '${dir.path}/A');
  var b = await NodeProcess.start(id: 'B', port: pb, dataDir: '${dir.path}/B');

  final acked = <String>{};
  final ackedByA = <String>{};
  // El golpe cae cuando A ya acusó `killAfter` reportes de la ráfaga y le quedan otros en vuelo.
  const killAfter = 5;
  var stormActive = false, killed = false, stormAcks = 0;
  DateTime? tKillAt;
  var a0 = a;
  Future<bool> send(Uri node, SynthFrame f) async {
    try {
      final r = await client.post(node.resolve('/frame'), body: f.bytes).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) {
        acked.add(f.reportKey);
        if (node == urlA) {
          ackedByA.add(f.reportKey);
          if (stormActive && !killed && ++stormAcks >= killAfter) {
            killed = true;
            tKillAt = DateTime.now();
            a0.kill9(); // sin avisar, con la ráfaga a medias
          }
        }
        return true;
      }
    } on Object {
      // el nodo no respondió: el teléfono prueba con el otro (conmutación)
    }
    return false;
  }

  // Un «teléfono»: prueba primero su nodo y, si no responde, el otro (como FailoverChannel).
  Future<void> phone(SynthFrame f, {required bool preferA}) async {
    final order = preferA ? [urlA, urlB] : [urlB, urlA];
    for (var attempt = 0; attempt < 6; attempt++) {
      if (await send(order[attempt % 2], f)) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  final cut1 = total * 4 ~/ 10, cut2 = total * 6 ~/ 10;
  say('Fase 1 · $cut1 reportes repartidos entre A y B (cada nodo sólo ve los suyos)');
  for (var i = 0; i < cut1; i++) {
    await phone(frames[i], preferA: i.isEven);
  }
  final beforeKillA = {...ackedByA};

  say('Fase 2 · kill -9 de A EN PLENO PROCESAMIENTO (${cut2 - cut1} reportes en ráfaga hacia A)');
  a0 = a;
  stormActive = true;
  // Ráfaga con concurrencia LIMITADA (4 «teléfonos» a la vez): cuando A muere quedan reportes sin
  // enviar y otros en vuelo, que tienen que conmutar a B. Con todos lanzados a la vez, el nodo ya los
  // habría procesado antes del golpe y la caída no interrumpiría nada.
  var nextStorm = cut1;
  Future<void> stormWorker() async {
    while (nextStorm < cut2) {
      final i = nextStorm++;
      await phone(frames[i], preferA: true);
    }
  }

  await Future.wait([for (var w = 0; w < 4; w++) stormWorker()]);
  stormActive = false;
  final tKill = tKillAt ?? DateTime.now();
  final stormAckedByA = ackedByA.difference(beforeKillA);
  final failedOver = (cut2 - cut1) - stormAckedByA.length;
  check(killed && failedOver > 0, 'el kill -9 cayó con la ráfaga a medias: A acusó ${stormAckedByA.length} de ${cut2 - cut1} antes de morir y los otros $failedOver tuvieron que conmutar a B');
  say('   · ráfaga terminada: ${acked.length} reportes acusados en total');

  say('Fase 3 · se reinicia A con su mismo disco');
  a = await NodeProcess.start(id: 'A', port: pa, dataDir: '${dir.path}/A');
  final rtoHealth = DateTime.now().difference(tKill);
  Future<List<Map<String, Object?>>> freshQueue(Uri node, {int? expect}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    List<Map<String, Object?>> last = const [];
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await client.get(node.resolve('/api/queue')).timeout(const Duration(seconds: 30));
        last = (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
        final fresh = r.headers['x-queue-stale'] == 'false';
        if (fresh && (expect == null || last.length >= expect)) return last;
      } on Object {
        // reintenta
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last;
  }

  final mustSurvive = {...beforeKillA, ...stormAckedByA};
  final queueAfterRestart = await freshQueue(urlA, expect: mustSurvive.length);
  final rtoQueue = DateTime.now().difference(tKill);
  final keysA = {for (final i in queueAfterRestart) i['reportKey']! as String};
  check(mustSurvive.every(keysA.contains), 'A conserva TODOS los reportes que acusó antes de morir, incluidos los de la ráfaga (${mustSurvive.length} de ${mustSurvive.length}) — T09');
  say('   · RTO: el nodo vuelve a responder en ${rtoHealth.inMilliseconds} ms y su cola está completa en ${rtoQueue.inMilliseconds} ms');

  say('Fase 4 · el resto (${total - cut2} reportes) sigue repartiéndose entre A y B');
  for (var i = cut2; i < total; i++) {
    await phone(frames[i], preferA: i.isEven);
  }
  check(acked.length == total, 'los $total reportes quedaron acusados por algún nodo (${acked.length})');

  final elapsed = DateTime.now().difference(t0);
  if (elapsed < partition) {
    say('   · se mantiene la partición hasta completar ${partition.inSeconds} s…');
    await Future<void>.delayed(partition - elapsed);
  }

  say('Fase 5 · se restablece la red: A y B se reinician con sus pares (como al volver la conectividad)');
  await a.stop();
  await b.stop();
  a = await NodeProcess.start(id: 'A', port: pa, dataDir: '${dir.path}/A', peers: [urlB.toString()]);
  b = await NodeProcess.start(id: 'B', port: pb, dataDir: '${dir.path}/B', peers: [urlA.toString()]);
  final tReconnect = DateTime.now();
  Future<Map<String, Object?>> health(Uri n) async => (jsonDecode((await client.get(n.resolve('/api/health'))).body) as Map).cast<String, Object?>();
  var converged = false;
  final convDeadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(convDeadline)) {
    final ha = await health(urlA), hb = await health(urlB);
    if (jsonEncode(ha['versionVector']) == jsonEncode(hb['versionVector']) && ha['events'] == hb['events']) {
      converged = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  final convergence = DateTime.now().difference(tReconnect);
  check(converged, 'los logs convergen tras reconectar (${convergence.inMilliseconds} ms) — T10');

  final qa = await freshQueue(urlA, expect: total), qb = await freshQueue(urlB, expect: total);
  final keysAll = {...{for (final i in qa) i['reportKey']! as String}, ...{for (final i in qb) i['reportKey']! as String}};
  check(acked.every(keysAll.contains), 'cero reportes acusados perdidos: ${acked.length} acusados, ${keysAll.length} en las colas — T09');
  check(qa.length == total && qb.length == total, 'ambas colas tienen $total reportes (A=${qa.length}, B=${qb.length}) sin duplicados');
  final fa = projectionFingerprint(qa), fb = projectionFingerprint(qb);
  check(fa == fb, 'A y B muestran EXACTAMENTE las mismas proyecciones tras la partición (huellas idénticas) — T10');

  final groups = {for (final i in qa) i['group'] as String}.length;
  say('   · ${qa.length} reportes en $groups grupos; ${qa.where((i) => i['urgency'] == 'P1').length} P1');
  stdout.writeln('HUELLA: $fa');
  stdout.writeln('RTO_HEALTH_MS: ${rtoHealth.inMilliseconds}');
  stdout.writeln('RTO_COLA_MS: ${rtoQueue.inMilliseconds}');
  stdout.writeln('CONVERGENCIA_MS: ${convergence.inMilliseconds}');

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(jsonEncode({
      'seed': seed,
      'reportes': total,
      'huella': fa,
      'rtoHealthMs': rtoHealth.inMilliseconds,
      'rtoColaMs': rtoQueue.inMilliseconds,
      'convergenciaMs': convergence.inMilliseconds,
      'acusados': acked.length,
      'grupos': groups,
      'fallos': failures,
    }));
  }
  await a.stop();
  await b.stop();
  client.close();
  stdout.writeln(failures.isEmpty ? 'DEMO OK' : 'DEMO CON FALLOS: ${failures.length}');
  exit(failures.isEmpty ? 0 : 1);
}
