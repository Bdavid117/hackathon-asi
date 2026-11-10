// T19 · tres nodos: relevo del modelo y convergencia (Reto 5).
//
//   dart run packages/sim/bin/t19_tres_nodos.dart [--reports 90] [--burst 30] [--seed 43] [--isolated-seconds 30]
//        [--port-a 8111] [--port-b 8112] [--port-c 8113] [--takeover 6] [--out docs/resultados/t19-tres-nodos.md]
//
// Qué mide. Tres nodos REALES (A, B, C), cada uno con SU modelo falso (A `ok`, B `cautious`, C `ok`) y en MALLA COMPLETA a través de
// seis proxies con interruptor (cada nodo tiene a los otros dos como pares). T12 midió el relevo del trabajo del modelo con DOS nodos
// («con más nodos el orden sigue el mismo hash, pero no se midió»): esto lo mide con tres.
//   Fase 1 · malla sana: entran reportes por los tres y se replican.
//   Fase 2 · RELEVO: una ráfaga de reportes con texto entra por A y se mata a C con `kill -9` AL INSTANTE (C era dueño de parte de
//            ellos por rendezvous): A y B deben acabar juzgándolos todos, tomando el relevo.
//   Fase 3 · se AÍSLA B (vivo, sin enlace con A; C sigue muerto): cada lado recibe reportes, dos coordinadores deciden a la vez y se
//            contradicen (Ana en A concede, Luis en B deniega).
//   Fase 4 · se reinicia C con su mismo disco y se restablecen TODOS los enlaces: se mide hasta que los tres nodos muestran lo mismo.
//
// CRITERIO (propio del diseño, NO del enunciado; escrito y commiteado ANTES de ejecutar; semilla 43, 90 reportes, ráfaga de 30):
//   (1) tras reiniciar C y restablecer los enlaces, las huellas de proyección de A, B y C coinciden en ≤ 90 s;
//   (2) RELEVO: los 30 reportes de la ráfaga acaban con juicio del modelo (de cualquier nodo) en ≤ 60 s desde el kill -9 de C, aunque
//       C fuera dueño de parte de ellos;
//   (3) 0 reportes acusados se pierden: todos están en la cola de los tres nodos al final;
//   (4) las dos decisiones contradictorias se conservan y los TRES nodos muestran «denegada» con la discrepancia marcada;
//   (5) ningún proceso muere por su cuenta (sólo el kill -9 deliberado de C).
// SE MIDEN Y SE INFORMAN, SIN CRITERIO: cuántos reportes de la ráfaga eran de C por rendezvous (los que dependían del relevo; se añadió tras
// la primera corrida, que lo daba por inferido del tiempo) y quién los juzgó (A o B = relevo; sólo C antes de morir = no es relevo), tiempo hasta cubrir la ráfaga, juicios duplicados (reportes juzgados por más de un nodo) y
// cuántos de ellos difieren en la urgencia, reparto del trabajo entre los nodos y tiempo real hasta converger.
//
// Límites que el informe debe decir, pase o no pase: nodos y modelos locales y sintéticos; el relevo se mide con una sola muerte; el
// aislamiento de B es total (no parcial); una sola corrida por semilla; criterios y montaje del mismo autor que el sistema.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_agents/sard_agents.dart' show rendezvousOwner;
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
const String _apiKey = 'clave-falsa-de-prueba';

String _opt(List<String> a, String k, String d) {
  final i = a.indexOf('--$k');
  return i >= 0 && i + 1 < a.length ? a[i + 1] : d;
}

Future<String> _git(List<String> args) async {
  try {
    return ((await Process.run('git', args)).stdout as String).trim();
  } on Object {
    return '?';
  }
}

String _s(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';

/// La clave de reporte que el nodo asigna a la trama `textReportFrame(n)`: el dispositivo en hexadecimal de 16 cifras, un guion y la secuencia.
String reportKeyOf(int n) => '${n.toRadixString(16).padLeft(16, '0')}-1';

Future<void> main(List<String> args) async {
  final seed = int.parse(_opt(args, 'seed', '43'));
  final total = int.parse(_opt(args, 'reports', '90'));
  final burst = int.parse(_opt(args, 'burst', '30'));
  final isolated = Duration(seconds: int.parse(_opt(args, 'isolated-seconds', '30')));
  final ports = {'A': int.parse(_opt(args, 'port-a', '8111')), 'B': int.parse(_opt(args, 'port-b', '8112')), 'C': int.parse(_opt(args, 'port-c', '8113'))};
  final takeover = _opt(args, 'takeover', '6');
  final outPath = _opt(args, 'out', 'docs/resultados/t19-tres-nodos.md');
  final repo = File.fromUri(Platform.script).parent.parent.parent.parent.path;
  final commit = await _git(['rev-parse', '--short', 'HEAD']);
  final dirty = (await _git(['status', '--porcelain', '--untracked-files=no'])).isNotEmpty;

  final client = http.Client();
  final probe = NodeProbe(client);
  final t0 = DateTime.now();
  final failures = <String>[];
  final lines = <String>[];
  void say(String s) => stdout.writeln('[${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1).padLeft(6)} s] $s');
  void verdict(bool ok, String what) {
    final line = '${ok ? '✓' : '✗'} $what';
    stdout.writeln(line);
    lines.add('- $line');
    if (!ok) failures.add(what);
  }

  final ids = ['A', 'B', 'C'];
  final urls = {for (final id in ids) id: Uri.parse('http://localhost:${ports[id]}')};
  final dirs = {for (final id in ids) id: Directory.systemTemp.createTempSync('sard-t19${id.toLowerCase()}-')};
  final fakes = {'A': await FakeClaudeServer.start(mode: FakeLlmMode.ok), 'B': await FakeClaudeServer.start(mode: FakeLlmMode.cautious), 'C': await FakeClaudeServer.start(mode: FakeLlmMode.ok)};
  // proxies[from][to]: por ahí `from` llega a `to`.
  final proxies = <String, Map<String, PartitionProxy>>{
    for (final from in ids) from: {for (final to in ids) if (to != from) to: await PartitionProxy.start(target: urls[to]!)},
  };
  final nodes = <String, NodeProcess?>{};
  Future<NodeProcess> start(String id) => NodeProcess.start(
    id: id,
    port: ports[id]!,
    dataDir: dirs[id]!.path,
    peers: [for (final to in ids) if (to != id) proxies[id]![to]!.url.toString()],
    extraArgs: ['--llm', 'on', '--llm-url', fakes[id]!.url.toString(), '--takeover', takeover, '--resources', '$repo/config/recursos.json'],
    environment: {'ANTHROPIC_API_KEY': _apiKey},
  );

  final acked = <int>{};
  Future<bool> send(String id, int n) async {
    try {
      final r = await client.post(urls[id]!.resolve('/frame'), body: textReportFrame(seed * 1000 + n, key)).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        acked.add(n);
        return true;
      }
    } on Object {
      // sin acuse
    }
    return false;
  }

  Future<List<Map<String, Object?>>> judgments(List<String> from) async {
    final out = <Map<String, Object?>>[];
    for (final id in from) {
      try {
        out.addAll(await probe.modelJudgments(urls[id]!, ids));
      } on Object {
        // ese nodo no contesta
      }
    }
    // Cada evento llega una vez por nodo consultado: sin deduplicar, el reparto salía multiplicado por el número de nodos.
    return NodeProbe.uniqueById(out);
  }

  var converged = false, killedC = false, aliveAllButC = true;
  Duration? convergence, coverageTime;
  var covered = 0, dupReports = 0, dupDiffer = 0;
  var ownedByC = <String>{}, relayedByAB = <String>{}, judgedOnlyByC = <String>{};
  final share = <Object?, int>{};
  var decisionsKept = false, lostFree = false;

  try {
    say('T19 · semilla $seed · $total reportes · ráfaga de $burst · commit $commit${dirty ? ' (ÁRBOL SUCIO)' : ''}');
    for (final id in ids) {
      nodes[id] = await start(id);
    }
    for (var i = 0; i < 60; i++) {
      var ok = true;
      for (final id in ids) {
        final peers = (await probe.nodes(urls[id]!))['peers']! as List;
        if (peers.length != 2 || peers.any((p) => (p as Map)['nodeId'] == null)) ok = false;
      }
      if (ok) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    say('Fase 1 · malla sana: los tres nodos se ven; entran reportes por los tres');
    final n1 = total - burst - 2 * (isolated.inSeconds ~/ 10);
    for (var i = 0; i < n1; i++) {
      await send(ids[i % 3], i);
    }
    for (final id in ids) {
      await probe.queue(urls[id]!, expect: n1, within: const Duration(seconds: 120));
    }
    say('   · $n1 reportes replicados en los tres nodos');

    say('Fase 2 · RELEVO: ráfaga de $burst reportes por A y kill -9 de C al instante');
    final burstKeys = <String>{};
    for (var i = 0; i < burst; i++) {
      final n = n1 + i;
      burstKeys.add(reportKeyOf(seed * 1000 + n));
      await send('A', n);
    }
    nodes['C']!.kill9();
    killedC = true;
    final tKill = DateTime.now();
    say('   · C muerto; se espera el relevo (takeover $takeover s)');
    final coverDeadline = tKill.add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(coverDeadline)) {
      final seen = {for (final e in await judgments(['A', 'B'])) e['reportKey']}..retainAll(burstKeys);
      covered = seen.length;
      if (covered >= burstKeys.length) {
        coverageTime = DateTime.now().difference(tKill);
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    say('   · ráfaga cubierta por el modelo: $covered de $burst${coverageTime == null ? '' : ' en ${_s(coverageTime)}'}');
    // Medición DIRECTA del relevo: «cubierta» cuenta también lo que C juzgó y replicó antes de morir, que NO es relevo.
    ownedByC = {for (final k in burstKeys) if (rendezvousOwner(k, ids) == 'C') k};
    final after = await judgments(['A', 'B']);
    relayedByAB = {for (final e in after) if (ownedByC.contains(e['reportKey'])) if (e['origin'] != 'C') e['reportKey']! as String};
    judgedOnlyByC = {for (final e in after) if (ownedByC.contains(e['reportKey']) && e['origin'] == 'C') e['reportKey']! as String}..removeAll(relayedByAB);
    say('   · de la ráfaga, ${ownedByC.length} eran de C por rendezvous: ${relayedByAB.length} los juzgó A o B (relevo), ${judgedOnlyByC.length} sólo C antes de morir, ${ownedByC.length - relayedByAB.length - judgedOnlyByC.length} sin juicio');

    say('Fase 3 · se AÍSLA B (vivo): cada lado recibe reportes y dos coordinadores se contradicen');
    for (final to in ['A', 'C']) {
      proxies['B']![to]!.cut();
      proxies[to]!['B']!.cut();
    }
    final inc = await probe.incidents(urls['A']!, within: const Duration(seconds: 60));
    final targets = [for (final i in inc) if ((i['recommendation'] as Map)['state'] == 'propuesta') i];
    if (targets.isEmpty) throw StateError('el montaje no produjo ningún incidente con propuesta que decidir');
    final target = targets.firstWhere((i) => i['urgency'] == 'P1', orElse: () => targets.first);
    final detail = (jsonDecode((await client.get(urls['A']!.resolve('/api/incidents/${Uri.encodeComponent(target['id']! as String)}'))).body) as Map).cast<String, Object?>();
    Future<int> decide(String id, bool granted, String who) async => (await client.post(
      urls[id]!.resolve('/api/approval'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'recommendationId': (target['recommendation'] as Map)['id'],
        'incidentId': target['id'],
        'members': (detail['members'] as List).cast<String>(),
        'decision': granted ? 'granted' : 'denied',
        'note': 'decisión de T19 con B aislado',
        'who': who,
      }),
    )).statusCode;
    final codes = await Future.wait([decide('A', true, 'Ana (nodo A)'), decide('B', false, 'Luis (nodo B)')]);
    var k = 0;
    final tIso = DateTime.now();
    var next = n1 + burst;
    while (DateTime.now().difference(tIso) < isolated) {
      await send('A', next++);
      await send('B', next++);
      k++;
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    say('   · B aislado ${_s(DateTime.now().difference(tIso))}; decisiones HTTP ${codes.join('/')}; $k tandas de reportes en cada lado');
    aliveAllButC = await probe.alive(urls['A']!) && await probe.alive(urls['B']!);

    say('Fase 4 · se reinicia C con su mismo disco y se restablecen TODOS los enlaces');
    for (final from in ids) {
      for (final px in proxies[from]!.values) {
        px.heal();
      }
    }
    nodes['C'] = await start('C');
    final tHeal = DateTime.now();
    final want = acked.length;
    final deadline = tHeal.add(const Duration(seconds: 240));
    while (DateTime.now().isBefore(deadline)) {
      final fps = [for (final id in ids) await probe.fingerprint(urls[id]!, reports: want, within: const Duration(seconds: 3))];
      if (fps.every((f) => f != null) && fps.toSet().length == 1) {
        converged = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    convergence = DateTime.now().difference(tHeal);
    say('   · ${converged ? 'convergen' : 'NO convergen'} tras ${_s(convergence)}');

    bool resolved(List<Map<String, Object?>> l) {
      final row = l.where((i) => i['id'] == target['id']);
      if (row.isEmpty) return false;
      final ap = row.first['approval'] as Map;
      return ap['status'] == 'denegada' && ap['discrepancy'] == true;
    }

    final qs = {for (final id in ids) id: await probe.queue(urls[id]!, expect: want)};
    final is_ = {for (final id in ids) id: await probe.incidents(urls[id]!, reports: want, until: resolved, within: const Duration(seconds: 30))};
    lostFree = ids.every((id) => qs[id]!.length == want && {for (final r in qs[id]!) r['reportKey']}.length == want);
    decisionsKept = codes.every((c) => c == 200) && ids.every((id) => resolved(is_[id]!));

    final all = await judgments(['A', 'B', 'C']);
    final by = <Object?, List<Map<String, Object?>>>{};
    for (final e in all) {
      (by[e['reportKey']] ??= []).add(e);
    }
    for (final judged in by.values) {
      for (final e in judged) {
        share[e['origin']] = (share[e['origin']] ?? 0) + 1;
      }
      if ({for (final e in judged) e['origin']}.length > 1) {
        dupReports++;
        if ({for (final e in judged) (e['body'] as Map)['urgency']}.length > 1) dupDiffer++;
      }
    }
    aliveAllButC = aliveAllButC && await probe.alive(urls['A']!) && await probe.alive(urls['B']!) && await probe.alive(urls['C']!);

    say('Resultados');
    verdict(converged && convergence <= const Duration(seconds: 90), 'huellas de A, B y C idénticas ${converged ? 'en ${_s(convergence)}' : 'NUNCA (en 240 s)'} tras reiniciar C y restablecer los enlaces (criterio 1: ≤ 90 s)');
    verdict(coverageTime != null && coverageTime <= const Duration(seconds: 60), 'relevo: $covered de $burst reportes de la ráfaga con juicio del modelo${coverageTime == null ? ' (no se cubrió en 60 s)' : ' en ${_s(coverageTime)}'} tras matar a C (criterio 2: ≤ 60 s)');
    verdict(lostFree, 'cero reportes acusados perdidos: ${acked.length} acusados y la cola de cada nodo tiene ${[for (final id in ids) qs[id]!.length].join(' / ')} (criterio 3)');
    verdict(decisionsKept, 'las dos decisiones contradictorias se conservan y los TRES nodos muestran «denegada» con la discrepancia marcada (criterio 4)');
    verdict(aliveAllButC && killedC, 'ningún proceso murió por su cuenta (sólo el kill -9 deliberado de C) (criterio 5)');
  } on Object catch (e, s) {
    failures.add('el recorrido no terminó: $e');
    stdout.writeln('✗ el recorrido no terminó: $e\n$s');
  } finally {
    for (final n in nodes.values) {
      await n?.stop();
    }
    for (final m in proxies.values) {
      for (final px in m.values) {
        await px.close();
      }
    }
    for (final f in fakes.values) {
      await f.close();
    }
    client.close();
    for (final d in dirs.values) {
      try {
        d.deleteSync(recursive: true);
      } on Object {
        // queda en /tmp
      }
    }
  }

  final report = StringBuffer()
    ..writeln('# T19 · tres nodos: relevo del modelo y convergencia')
    ..writeln()
    ..writeln('Fecha: ${DateTime.now().toIso8601String()} · commit `$commit`${dirty ? ' (**árbol sucio**)' : ' (árbol limpio)'} · semilla $seed · ${acked.length} reportes acusados (ráfaga de $burst) · `--takeover $takeover`.')
    ..writeln()
    ..writeln('Tres nodos reales (procesos `dart run`) en malla completa a través de seis proxies con interruptor, cada uno con su modelo FALSO (A `ok`, B `cautious`, C `ok`). '
        'Se mide el relevo del trabajo del modelo con TRES nodos (T12 lo midió con dos), el aislamiento de uno de ellos y la convergencia de los tres al reunirse.')
    ..writeln()
    ..writeln('## Criterio (propio del diseño, no del enunciado; commiteado antes de ejecutar)')
    ..writeln()
    ..writeln('1. huellas de A, B y C idénticas en ≤ 90 s tras reiniciar C y restablecer los enlaces; 2. la ráfaga de $burst reportes con texto acaba con juicio del modelo en ≤ 60 s desde el `kill -9` de C aunque C fuera dueño de parte; 3. 0 reportes acusados perdidos; 4. las decisiones contradictorias se conservan y los tres nodos muestran «denegada» con discrepancia; 5. ningún nodo muere por su cuenta.')
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
    ..writeln('- De los $burst reportes de la ráfaga, **${ownedByC.length}** eran de C por rendezvous (los que dependían del relevo). De ésos: **${relayedByAB.length}** los juzgó A o B (relevo de verdad), **${judgedOnlyByC.length}** sólo los juzgó C antes de morir (replicado, no es relevo) y **${ownedByC.length - relayedByAB.length - judgedOnlyByC.length}** no tienen juicio de ningún nodo.${ownedByC.isEmpty ? ' **Ninguno era de C: el relevo no se ejerció y el criterio 2 no lo demuestra.**' : ''}')
    ..writeln('- Tiempo hasta cubrir la ráfaga tras matar a C: **${coverageTime == null ? 'no se cubrió ($covered de $burst)' : _s(coverageTime)}**.')
    ..writeln('- Tiempo real hasta converger los tres: **${convergence == null ? 'n/d' : _s(convergence)}**.')
    ..writeln('- Juicios del modelo por nodo de origen: ${share.entries.map((e) => '${e.key}=${e.value}').join(', ')}. Reportes juzgados por MÁS DE UN nodo (cómputo duplicado): **$dupReports**; de ellos, con urgencia distinta: **$dupDiffer**.')
    ..writeln()
    ..writeln('## Lo que esto NO demuestra')
    ..writeln()
    ..writeln('- Nodos y modelos locales y sintéticos. El relevo se mide con UNA muerte; el aislamiento de B es total (no parcial); sólo una corrida por semilla; criterios y montaje del mismo autor que el sistema.')
    ..writeln('- El orden de relevo con más de tres nodos no se midió.')
    ..writeln()
    ..writeln('## Cómo reproducirlo')
    ..writeln()
    ..writeln('```bash')
    ..writeln('dart run packages/sim/bin/t19_tres_nodos.dart --reports $total --burst $burst --seed $seed   # desde la raíz, con el árbol limpio y la máquina sin carga')
    ..writeln('```');
  if (args.contains('--write') || (total >= 90 && burst >= 30)) {
    File(outPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(report.toString());
    stdout.writeln('Informe: $outPath');
  } else {
    stdout.writeln('(ensayo corto: no se escribe el informe; con --write sí)');
  }
  stdout.writeln(failures.isEmpty ? 'T19 OK' : 'T19 CON FALLOS: ${failures.length}');
  exit(failures.isEmpty ? 0 : 1);
}
