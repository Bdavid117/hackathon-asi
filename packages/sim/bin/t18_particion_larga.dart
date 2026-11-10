// T18 · partición larga REAL con dos nodos (Reto 5).
//
//   dart run packages/sim/bin/t18_particion_larga.dart [--partition-seconds 600] [--reports 90] [--seed 42]
//        [--port-a 8101] [--port-b 8102] [--takeover 6] [--out docs/resultados/t18-particion-larga.md]
//
// Qué mide. Dos nodos REALES (procesos) con el modelo falso encendido, cada uno con SU modelo y los dos configurados como pares del otro
// a través de un proxy con interruptor (`PartitionProxy`). Se corta el enlace de verdad: el replicador de cada nodo sigue intentando y
// recibe errores de conexión. (La demostración `demo.dart` arranca los nodos SIN pares: ahí 600 s sólo esperan y no ejercitan nada.)
//   Fase 1 · con el enlace sano entran reportes por los dos nodos y se replican.
//   Fase 2 · se CORTA el enlace durante `--partition-seconds` (por omisión 600 = 10 min): cada lado recibe reportes que el otro no ve
//            (más un goteo de uno por lado cada 15 s, para que un corte largo no sea esperar con los nodos ociosos), dos coordinadores
//            deciden a la vez y se contradicen (uno en cada lado) y a mitad del corte se mata a B con `kill -9` y se reinicia con su
//            mismo disco.
//   Fase 3 · se RESTABLECE el enlace y se mide hasta cuándo las proyecciones de los dos nodos son idénticas.
// Los dos modelos falsos contestan DISTINTO a propósito (A `ok` sube a P1 lo que dice «encerrados»; B `cautious` nunca sube nada): si
// durante el corte cada lado fue dueño de todo y tras reconectar los dos juzgan el mismo reporte, los juicios duplicados difieren y
// los nodos deben converger igual (esa es la parte donde podría haber un defecto real).
//
// CRITERIO (propio del diseño, NO del enunciado; escrito y commiteado ANTES de ejecutar; semilla 42, 90 reportes, 600 s):
//   (1) tras restablecer el enlace, las huellas de proyección de A y B (cola + incidentes, como T10/T15) coinciden en ≤ 60 s;
//   (2) 0 reportes acusados se pierden: todos los acusados están en la cola de los dos nodos tras converger;
//   (3) las dos decisiones contradictorias tomadas cada una en su lado se conservan las dos y tras converger ambos nodos muestran
//       «denegada» con la discrepancia marcada;
//   (4) ningún proceso de nodo muere por su cuenta durante el corte (sólo el kill -9 deliberado de B);
//   (5) el replicador de cada nodo registró errores de conexión durante el corte (prueba de que el corte fue real y no «sin pares»).
// SE MIDEN Y SE INFORMAN, SIN CRITERIO: juicios del modelo duplicados (reportes con juicio de los dos nodos), cuántos de ellos difieren
// en la urgencia, tiempo real hasta converger, y lo que cada nodo ve del otro en /api/nodes durante el corte.
//
// Límites que el informe debe decir, pase o no pase: nodos y modelos locales y sintéticos (no hay red ni modelo reales); un corte total
// y simétrico (no hay cortes parciales ni asimétricos); un solo `kill -9`; una sola corrida por semilla; los criterios y el montaje
// son del mismo autor que el sistema.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
const String _apiKey = 'clave-falsa-de-prueba';

String _opt(List<String> a, String k, String d) {
  final i = a.indexOf('--$k');
  return i >= 0 && i + 1 < a.length ? a[i + 1] : d;
}

Future<String> _git(List<String> args) async {
  try {
    final r = await Process.run('git', args);
    return (r.stdout as String).trim();
  } on Object {
    return '?';
  }
}

String _s(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';

Future<void> main(List<String> args) async {
  final seed = int.parse(_opt(args, 'seed', '42'));
  final total = int.parse(_opt(args, 'reports', '90'));
  final partition = Duration(seconds: int.parse(_opt(args, 'partition-seconds', '600')));
  final pa = int.parse(_opt(args, 'port-a', '8101')), pb = int.parse(_opt(args, 'port-b', '8102'));
  final takeover = _opt(args, 'takeover', '6');
  final outPath = _opt(args, 'out', 'docs/resultados/t18-particion-larga.md');
  final repo = File.fromUri(Platform.script).parent.parent.parent.parent.path;
  final commit = await _git(['rev-parse', '--short', 'HEAD']);
  final dirty = (await _git(['status', '--porcelain', '--untracked-files=no'])).isNotEmpty; // sólo lo rastreado: un archivo local sin versionar no cuenta

  final client = http.Client();
  final probe = NodeProbe(client);
  final t0 = DateTime.now();
  final failures = <String>[];
  final lines = <String>[];
  void say(String s) {
    final line = '[${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1).padLeft(6)} s] $s';
    stdout.writeln(line);
  }

  void verdict(bool ok, String what) {
    final line = '${ok ? '✓' : '✗'} $what';
    stdout.writeln(line);
    lines.add('- $line');
    if (!ok) failures.add(what);
  }

  final dirA = Directory.systemTemp.createTempSync('sard-t18a-'), dirB = Directory.systemTemp.createTempSync('sard-t18b-');
  final fakeA = await FakeClaudeServer.start(mode: FakeLlmMode.ok);
  final fakeB = await FakeClaudeServer.start(mode: FakeLlmMode.cautious);
  final urlA = Uri.parse('http://localhost:$pa'), urlB = Uri.parse('http://localhost:$pb');
  final proxyAtoB = await PartitionProxy.start(target: urlB); // por aquí A llega a B
  final proxyBtoA = await PartitionProxy.start(target: urlA); // por aquí B llega a A
  NodeProcess? a, b;
  List<String> extra(FakeClaudeServer fake) => ['--llm', 'on', '--llm-url', fake.url.toString(), '--takeover', takeover, '--resources', '$repo/config/recursos.json'];

  Future<NodeProcess> startA() => NodeProcess.start(id: 'A', port: pa, dataDir: dirA.path, peers: [proxyAtoB.url.toString()], extraArgs: extra(fakeA), environment: {'ANTHROPIC_API_KEY': _apiKey});
  Future<NodeProcess> startB() => NodeProcess.start(id: 'B', port: pb, dataDir: dirB.path, peers: [proxyBtoA.url.toString()], extraArgs: extra(fakeB), environment: {'ANTHROPIC_API_KEY': _apiKey});

  final acked = <int>{};
  Future<bool> send(Uri node, int n) async {
    try {
      final r = await client.post(node.resolve('/frame'), body: textReportFrame(seed * 1000 + n, key)).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        acked.add(n);
        return true;
      }
    } on Object {
      // sin acuse: no cuenta como acusado
    }
    return false;
  }

  // Durante el corte sigue llegando un reporte por lado cada 15 s (goteo): un corte largo con los dos nodos ociosos no ejercita nada.
  var extraN = total + 100;
  Future<void> trickleUntil(DateTime until, {required bool bUp}) async {
    while (DateTime.now().isBefore(until)) {
      await send(urlA, extraN++);
      if (bUp) await send(urlB, extraN++);
      final left = until.difference(DateTime.now());
      if (left > Duration.zero) await Future<void>.delayed(left < const Duration(seconds: 15) ? left : const Duration(seconds: 15));
    }
  }

  Map<String, Object?> peerOf(Map<String, Object?> nodes) => ((nodes['peers']! as List).first as Map).cast<String, Object?>();
  String? mid, end;
  var killedAndBack = false;
  var errorsAtA = false, errorsAtB = false;
  Duration? convergence;
  var converged = false;
  var aliveAll = true;
  final noted = <String, Object?>{};
  late List<Map<String, Object?>> qa, qb, ia, ib;
  var dupReports = 0, dupDiffer = 0, withModel = 0;

  try {
    say('T18 · semilla $seed · $total reportes · partición de ${partition.inSeconds} s · commit $commit${dirty ? ' (ÁRBOL SUCIO)' : ''}');
    a = await startA();
    b = await startB();
    for (var i = 0; i < 40; i++) {
      final na = peerOf(await probe.nodes(urlA)), nb = peerOf(await probe.nodes(urlB));
      if (na['nodeId'] == 'B' && nb['nodeId'] == 'A') break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    say('Fase 1 · enlace sano: los dos nodos se ven; entran reportes por los dos');
    final n1 = total ~/ 3, n2 = total ~/ 3, n3 = total - n1 - n2;
    for (var i = 0; i < n1; i++) {
      await send(i.isEven ? urlA : urlB, i);
    }
    final q1 = await probe.queue(urlA, expect: n1, within: const Duration(seconds: 90));
    await probe.queue(urlB, expect: n1, within: const Duration(seconds: 90));
    say('   · ${q1.length} reportes replicados en los dos nodos');

    final inc1 = await probe.incidents(urlA, reports: n1, within: const Duration(seconds: 90));
    final targets = [for (final i in inc1) if ((i['recommendation'] as Map)['state'] == 'propuesta') i];
    if (targets.isEmpty) throw StateError('el montaje no produjo ningún incidente con propuesta que decidir (¿recursos sin cargar?)');
    final target = targets.firstWhere((i) => i['urgency'] == 'P1', orElse: () => targets.first);
    final detail = (jsonDecode((await client.get(urlA.resolve('/api/incidents/${Uri.encodeComponent(target['id']! as String)}'))).body) as Map).cast<String, Object?>();

    say('Fase 2 · SE CORTA el enlace (los pares siguen configurados): ${partition.inSeconds} s');
    proxyAtoB.cut();
    proxyBtoA.cut();
    final tCut = DateTime.now();
    for (var i = 0; i < n2; i++) {
      await send(urlA, n1 + i); // sólo A los ve
    }
    for (var i = 0; i < n3 ~/ 2; i++) {
      await send(urlB, n1 + n2 + i); // sólo B los ve
    }
    Future<int> decide(Uri node, bool granted, String who) async => (await client.post(
      node.resolve('/api/approval'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'recommendationId': (target['recommendation'] as Map)['id'],
        'incidentId': target['id'],
        'members': (detail['members'] as List).cast<String>(),
        'decision': granted ? 'granted' : 'denied',
        'note': 'decisión de T18 durante el corte',
        'who': who,
      }),
    )).statusCode;
    final codes = await Future.wait([decide(urlA, true, 'Ana (nodo A)'), decide(urlB, false, 'Luis (nodo B)')]);
    say('   · decisiones contradictorias, una en cada lado: HTTP ${codes.join('/')}');

    final half = tCut.add(partition ~/ 2);
    await trickleUntil(half, bUp: true);
    final nodesA = await probe.nodes(urlA), nodesB = await probe.nodes(urlB);
    mid = 'A ve a B: ${peerOf(nodesA)['state']} (último error: ${peerOf(nodesA)['lastError']}) · B ve a A: ${peerOf(nodesB)['state']} (último error: ${peerOf(nodesB)['lastError']})';
    errorsAtA = peerOf(nodesA)['lastError'] != null;
    errorsAtB = peerOf(nodesB)['lastError'] != null;
    say('   · a mitad del corte: $mid');

    say('   · kill -9 de B a mitad del corte y reinicio con su mismo disco');
    b.kill9();
    b = await startB();
    killedAndBack = true;
    for (var i = 0; i < n3 - n3 ~/ 2; i++) {
      await send(urlB, n1 + n2 + n3 ~/ 2 + i);
    }

    final endOfCut = tCut.add(partition);
    await trickleUntil(endOfCut, bUp: true);
    aliveAll = await probe.alive(urlA) && await probe.alive(urlB);
    final nodesA2 = await probe.nodes(urlA), nodesB2 = await probe.nodes(urlB);
    end = 'A ve a B: ${peerOf(nodesA2)['state']} · B ve a A: ${peerOf(nodesB2)['state']}';
    errorsAtA = errorsAtA && peerOf(nodesA2)['lastError'] != null;
    errorsAtB = errorsAtB && peerOf(nodesB2)['lastError'] != null;
    say('   · al final del corte: $end · los dos procesos responden: $aliveAll · reenviado/rechazado por los proxies: A→B ${proxyAtoB.forwarded}/${proxyAtoB.refused}, B→A ${proxyBtoA.forwarded}/${proxyBtoA.refused}');

    say('Fase 3 · SE RESTABLECE el enlace y se mide hasta que las proyecciones coinciden');
    proxyAtoB.heal();
    proxyBtoA.heal();
    final tHeal = DateTime.now();
    final fullDeadline = tHeal.add(const Duration(seconds: 180));
    final want = acked.length;
    String? fa, fb;
    while (DateTime.now().isBefore(fullDeadline)) {
      fa = await probe.fingerprint(urlA, reports: want, within: const Duration(seconds: 3));
      fb = await probe.fingerprint(urlB, reports: want, within: const Duration(seconds: 3));
      if (fa != null && fa == fb) {
        converged = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    convergence = DateTime.now().difference(tHeal);
    say('   · ${converged ? 'convergen' : 'NO convergen'} tras ${_s(convergence)}');

    qa = await probe.queue(urlA, expect: want);
    qb = await probe.queue(urlB, expect: want);
    bool resolved(List<Map<String, Object?>> l) {
      final row = l.where((i) => i['id'] == target['id']);
      if (row.isEmpty) return false;
      final ap = row.first['approval'] as Map;
      return ap['status'] == 'denegada' && ap['discrepancy'] == true;
    }

    ia = await probe.incidents(urlA, reports: want, until: resolved, within: const Duration(seconds: 30));
    ib = await probe.incidents(urlB, reports: want, until: resolved, within: const Duration(seconds: 30));

    final events = await probe.modelJudgments(urlA, ['A', 'B']);
    final byReport = <Object?, List<Map<String, Object?>>>{};
    for (final e in events) {
      (byReport[e['reportKey']] ??= []).add(e);
    }
    withModel = byReport.length;
    for (final judged in byReport.values) {
      final origins = {for (final e in judged) e['origin']};
      if (origins.length > 1) {
        dupReports++;
        if ({for (final e in judged) (e['body'] as Map)['urgency']}.length > 1) dupDiffer++;
      }
    }
    noted['codes'] = codes;
    say('Resultados');
    verdict(converged && convergence <= const Duration(seconds: 60), 'huellas de A y B idénticas ${converged ? 'en ${_s(convergence)} tras restablecer el enlace' : 'NUNCA (en 180 s)'} (criterio 1: ≤ 60 s)');
    final keysA = {for (final r in qa) r['reportKey']}, keysB = {for (final r in qb) r['reportKey']};
    verdict(qa.length == want && qb.length == want && keysA.length == want && keysB.length == want, 'cero reportes acusados perdidos: ${acked.length} acusados, ${qa.length} en la cola de A y ${qb.length} en la de B (criterio 2)');
    verdict(codes.every((c) => c == 200) && resolved(ia) && resolved(ib), 'las dos decisiones contradictorias se conservan y ambos nodos muestran «denegada» con la discrepancia marcada (criterio 3)');
    verdict(aliveAll && killedAndBack, 'ningún proceso murió por su cuenta durante el corte (sólo el kill -9 deliberado de B) (criterio 4)');
    verdict(errorsAtA && errorsAtB, 'el replicador de cada nodo registró errores de conexión durante el corte: el corte fue real, no «sin pares» (criterio 5)');
  } on Object catch (e, s) {
    failures.add('el recorrido no terminó: $e');
    stdout.writeln('✗ el recorrido no terminó: $e\n$s');
  } finally {
    await a?.stop();
    await b?.stop();
    await proxyAtoB.close();
    await proxyBtoA.close();
    await fakeA.close();
    await fakeB.close();
    client.close();
    for (final d in [dirA, dirB]) {
      try {
        d.deleteSync(recursive: true);
      } on Object {
        // se queda en /tmp
      }
    }
  }

  final report = StringBuffer()
    ..writeln('# T18 · partición larga real con dos nodos')
    ..writeln()
    ..writeln('Fecha: ${DateTime.now().toIso8601String()} · commit `$commit`${dirty ? ' (**árbol sucio**)' : ' (árbol limpio)'} · semilla $seed · $total reportes con texto (más el goteo del corte: ${acked.length - total} adicionales) · corte de **${partition.inSeconds} s** · `--takeover $takeover`.')
    ..writeln()
    ..writeln('Dos nodos reales (procesos `dart run`), cada uno con su modelo FALSO y los dos configurados como pares del otro a través de un proxy con interruptor. '
        'A usa un modelo `ok` (sube a P1 lo que dice «encerrados») y B uno `cautious` (nunca sube nada): contestan DISTINTO a propósito. '
        'Se corta el enlace de verdad (el replicador sigue intentando y recibe errores de conexión), cada lado recibe reportes que el otro no ve, dos coordinadores deciden a la vez y se contradicen, '
        'y a mitad del corte se mata a B con `kill -9` y se reinicia con su mismo disco. Después se restablece el enlace.')
    ..writeln()
    ..writeln('## Criterio (propio del diseño, no del enunciado; commiteado antes de ejecutar)')
    ..writeln()
    ..writeln('1. huellas de A y B idénticas en ≤ 60 s tras restablecer; 2. 0 reportes acusados perdidos; 3. las decisiones contradictorias se conservan y ambos muestran «denegada» con discrepancia; 4. ningún nodo muere por su cuenta durante el corte; 5. el replicador registró errores de conexión durante el corte.')
    ..writeln()
    ..writeln('## Resultado')
    ..writeln();
  for (final l in lines) {
    report.writeln(l);
  }
  report
    ..writeln()
    ..writeln('**Veredicto: ${failures.isEmpty ? 'cumple los cinco criterios' : 'NO cumple todos los criterios (${failures.length})'}.**')
    ..writeln()
    ..writeln('## Lo que se mide sin criterio')
    ..writeln()
    ..writeln('- Tiempo real hasta converger tras restablecer: **${convergence == null ? 'n/d' : _s(convergence)}** (la réplica sondea cada 3 s).')
    ..writeln('- Reportes con juicio del modelo: $withModel; con juicio de LOS DOS nodos (cómputo duplicado): **$dupReports**; de ellos, con urgencia distinta: **$dupDiffer**.')
    ..writeln('- Lo que cada nodo veía del otro durante el corte — a mitad: ${mid ?? 'n/d'}; al final: ${end ?? 'n/d'}.')
    ..writeln()
    ..writeln('## Lo que esto NO demuestra')
    ..writeln()
    ..writeln('- Nodos y modelos locales y sintéticos: no hay red, radio ni modelo reales. El corte es total y simétrico (no hay cortes parciales ni asimétricos) y se mató a un solo nodo una vez.')
    ..writeln('- Una sola corrida por semilla; los criterios y el montaje son del mismo autor que el sistema.')
    ..writeln('- Que un corte de 10 minutos converja no dice nada de uno de horas (el log de cada nodo crece sin tope mientras tanto).')
    ..writeln()
    ..writeln('## Cómo reproducirlo')
    ..writeln()
    ..writeln('```bash')
    ..writeln('dart run packages/sim/bin/t18_particion_larga.dart --partition-seconds ${partition.inSeconds} --reports $total --seed $seed   # desde la raíz, con el árbol limpio y la máquina sin carga')
    ..writeln('```');
  if (!(partition.inSeconds < 300) || args.contains('--write')) {
    File(outPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(report.toString());
    stdout.writeln('Informe: $outPath');
  } else {
    stdout.writeln('(ensayo corto: no se escribe el informe; con --write sí)');
  }
  stdout.writeln(failures.isEmpty ? 'T18 OK' : 'T18 CON FALLOS: ${failures.length}');
  exit(failures.isEmpty ? 0 : 1);
}
