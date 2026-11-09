// Banco de ráfaga (T11): N reportes por HTTP contra el PROCESO REAL del nodo.
//
//   dart run packages/sim/bin/burst.dart [--reports 10000] [--concurrency 16] [--seed 1]
//        [--port 8093] [--max-seconds 600] [--label etapa0] [--out docs/resultados/b5-rafaga.md]
//
// Mide, con el nodo bajo carga: latencia de ACK (p50/p95/máx), capacidad de respuesta del nodo
// (latencia de /api/health durante la ráfaga), cuánto tarda en verse en la cola un P1 y un P4
// plantados a mitad de la ráfaga, y que ningún reporte acusado falte en la cola al final.
// Se ejecuta al terminar CADA etapa y deja una sección por ejecución para comparar.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

double pct(List<num> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()].toDouble();
}

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    o[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final n = int.parse(o['reports'] ?? '10000');
  final conc = int.parse(o['concurrency'] ?? '16');
  final seed = int.parse(o['seed'] ?? '1');
  final port = int.parse(o['port'] ?? '8093');
  final maxSeconds = int.parse(o['max-seconds'] ?? '600');
  final label = o['label'] ?? 'sin etiqueta';
  final out = o['out'] ?? 'docs/resultados/b5-rafaga.md';

  // ---- reportes sintéticos → tramas (dispositivos fijos, secuencia por dispositivo)
  final ds = generateDataset(SynthConfig(seed: seed, incidents: max(10, n ~/ 12), reports: n, adversarialPairs: 0));
  final seqs = <String, int>{};
  Uint8List frame(SynthReport r, {int? flagsOverride, String? textOverride}) {
    final seq = seqs[r.deviceId] = (seqs[r.deviceId] ?? 0) + 1;
    final flags = flagsOverride ?? r.flags;
    return encodeReportFrame(
      ReportFrame(
        deviceId: deviceIdFromHex(r.deviceId),
        seq: seq,
        rev: 0,
        prioHint: prioHintFromFlags(flags),
        incidentType: r.incidentType,
        flags: flags,
        peopleBucket: 0,
        locQuality: r.locQuality,
        lat: r.lat,
        lon: r.lon,
        capturedAt: (r.capturedAtMs ~/ 1000).clamp(0, 4294967295),
        batteryQ: 8,
        // el generador de B3 a veces da '' en vez de null (ver el libro de registro); la trama exige 1..140 B
        text: (textOverride ?? r.text)?.isEmpty ?? true ? null : (textOverride ?? r.text),
      ),
      key,
    );
  }

  final reports = ds.reports.take(n).toList();
  final base = reports.first;
  const p1Device = '00000000000000a1', p4Device = '00000000000000a4';
  final p1Key = '$p1Device-1', p4Key = '$p4Device-1';
  SynthReport marker(String dev, int flags, String? text) => SynthReport(
    reportKey: '$dev-1', deviceId: dev, incidentType: 1, flags: flags, lat: 5.07, lon: -75.52, locQuality: LocQuality.within10m,
    capturedAtMs: base.capturedAtMs, text: text, sourceClass: 'app', trueIncident: -1, trueUrgency: base.trueUrgency, subgroup: 'no_p1', tags: const {},
  );
  final p1Frame = frame(marker(p1Device, SituationFlags.atrapado | SituationFlags.herido, null));
  final p4Frame = frame(marker(p4Device, 0, 'se cayó un árbol, sin heridos'));
  final frames = [for (final r in reports) frame(r)];

  final dir = Directory.systemTemp.createTempSync('sard-burst-');
  final node = await NodeProcess.start(id: 'A', port: port, dataDir: dir.path);
  final client = http.Client();
  final base0 = node.url;
  final started = DateTime.now();
  var aborted = false;

  final ackMs = <int>[];
  final healthMs = <int>[];
  var okCount = 0, failCount = 0, next = 0;
  final plantedAt = <String, DateTime>{};
  final visibleAfter = <String, int>{};
  final plantIndex = n ~/ 2;
  var posting = true;

  Future<void> post(Uint8List f) async {
    final sw = Stopwatch()..start();
    try {
      final r = await client.post(base0.resolve('/frame'), body: f).timeout(const Duration(seconds: 60));
      sw.stop();
      if (r.statusCode == 200) {
        okCount++;
        ackMs.add(sw.elapsedMilliseconds);
      } else {
        failCount++;
      }
    } on Object {
      failCount++;
    }
  }

  Future<void> worker() async {
    while (posting) {
      final i = next++;
      if (i >= frames.length) return;
      if (DateTime.now().difference(started).inSeconds > maxSeconds) {
        aborted = true;
        return;
      }
      if (i == plantIndex) {
        plantedAt[p1Key] = DateTime.now();
        plantedAt[p4Key] = DateTime.now();
        await post(p1Frame);
        await post(p4Frame);
      }
      await post(frames[i]);
      if (i % 1000 == 0 && i > 0) stderr.writeln('  … $i tramas, ${DateTime.now().difference(started).inSeconds} s');
    }
  }

  // Monitor: la capacidad de respuesta del nodo y la visibilidad de los marcadores en la cola.
  final monitor = Future<void>(() async {
    while (posting) {
      final sw = Stopwatch()..start();
      try {
        await client.get(base0.resolve('/api/health')).timeout(const Duration(seconds: 30));
        healthMs.add(sw.elapsedMilliseconds);
      } on Object {
        healthMs.add(30000);
      }
      if (plantedAt.isNotEmpty && visibleAfter.length < plantedAt.length) {
        try {
          final r = await client.get(base0.resolve('/api/queue')).timeout(const Duration(seconds: 60));
          final keys = {for (final i in (jsonDecode(r.body) as List)) (i as Map)['reportKey'] as String};
          for (final e in plantedAt.entries) {
            if (keys.contains(e.key) && !visibleAfter.containsKey(e.key)) {
              visibleAfter[e.key] = DateTime.now().difference(e.value).inMilliseconds;
            }
          }
        } on Object {
          // seguirá intentando
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  });

  await Future.wait([for (var i = 0; i < conc; i++) worker()]);
  final burstSeconds = DateTime.now().difference(started).inMilliseconds / 1000;
  posting = false;
  await monitor;

  // ---- tras la ráfaga: ¿tarda el nodo en mostrar todo? ¿falta algo acusado?
  final settleStart = DateTime.now();
  var inQueue = 0;
  Set<String> keysNow = {};
  final expected = okCount;
  final settleDeadline = DateTime.now().add(const Duration(seconds: 180));
  while (DateTime.now().isBefore(settleDeadline)) {
    try {
      final r = await client.get(base0.resolve('/api/queue')).timeout(const Duration(seconds: 120));
      final list = (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
      keysNow = {for (final i in list) i['reportKey']! as String};
      inQueue = keysNow.length;
      if (inQueue >= expected) break;
    } on Object {
      // reintenta
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  final settleSeconds = DateTime.now().difference(settleStart).inMilliseconds / 1000;
  for (final e in plantedAt.entries) {
    if (keysNow.contains(e.key) && !visibleAfter.containsKey(e.key)) {
      visibleAfter[e.key] = DateTime.now().difference(e.value).inMilliseconds;
    }
  }
  Map<String, Object?>? health;
  try {
    health = (jsonDecode((await client.get(base0.resolve('/api/health'))).body) as Map).cast<String, Object?>();
  } on Object {
    health = null;
  }
  await node.stop();
  client.close();

  String ms(double v) => '${v.toStringAsFixed(0)} ms';
  final b = StringBuffer()
    ..writeln('## Ráfaga · $label')
    ..writeln()
    ..writeln('- Fecha: ${DateTime.now().toIso8601String()} · reportes pedidos: $n · concurrencia: $conc · semilla: $seed · tope: $maxSeconds s')
    ..writeln('- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).')
    ..writeln()
    ..writeln(aborted ? '**⚠️ ABORTADA por el tope de tiempo ($maxSeconds s): sólo se enviaron ${okCount + failCount} de $n tramas.**' : '- Ráfaga completa en ${burstSeconds.toStringAsFixed(1)} s (${(okCount / burstSeconds).toStringAsFixed(0)} tramas/s).')
    ..writeln()
    ..writeln('| Medida | Valor |')
    ..writeln('|---|---|')
    ..writeln('| Tramas acusadas / fallidas | $okCount / $failCount |')
    ..writeln('| Latencia del ACK p50 / p95 / máx | ${ms(pct(ackMs, .5))} / ${ms(pct(ackMs, .95))} / ${ms(pct(ackMs, 1))} |')
    ..writeln('| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | ${ms(pct(healthMs, .5))} / ${ms(pct(healthMs, .95))} / ${ms(pct(healthMs, 1))} |')
    ..writeln('| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | ${visibleAfter.containsKey(p1Key) ? '${(visibleAfter[p1Key]! / 1000).toStringAsFixed(1)} s' : '**no apareció**'} |')
    ..writeln('| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | ${visibleAfter.containsKey(p4Key) ? '${(visibleAfter[p4Key]! / 1000).toStringAsFixed(1)} s' : '**no apareció**'} |')
    ..writeln('| Reportes en la cola al final / acusados | $inQueue / $expected |')
    ..writeln('| Tiempo extra hasta ver todo tras la última trama | ${settleSeconds.toStringAsFixed(1)} s |')
    ..writeln('| Eventos en el log del nodo | ${health?['events'] ?? '—'} |')
    ..writeln();
  final f = File(out);
  if (!f.existsSync()) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('# T11 · Cola bajo ráfaga — ejecuciones\n\nUna sección por ejecución, para comparar entre etapas. Datos sintéticos; un solo nodo; ver «Qué mide y qué no» en `b5.md`.\n\n');
  }
  f.writeAsStringSync(b.toString(), mode: FileMode.append);
  stdout.writeln(b.toString());
  exit(aborted || inQueue < expected ? 1 : 0);
}
