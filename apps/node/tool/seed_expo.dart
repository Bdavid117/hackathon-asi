// Siembra un nodo con el escenario de EXPOSICIÓN (datos sintéticos, seis horas de historia) ANTES de arrancarlo:
//   dart run tool/seed_expo.dart --data DIRECTORIO [--id A] [--seed 7]
// Cada reporte pasa por el MISMO camino que uno real (trama firmada → `Ingest` → agentes de reglas), pero con el reloj fijado en la hora que
// tuvo en la historia: así «hace 3 h» y las zonas en silencio de la capa del mapa son las de verdad, no un adorno. No usa el modelo de
// lenguaje ni la red. Se niega a mezclar datos con un directorio que ya tenga reportes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'expo_scenario.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final data = opt('data');
  if (data == null) {
    stderr.writeln('Uso: dart run tool/seed_expo.dart --data DIRECTORIO [--id A] [--seed 7]');
    exit(64);
  }
  final id = opt('id') ?? 'A';
  final seed = int.tryParse(opt('seed') ?? '7') ?? 7;
  Directory(data).createSync(recursive: true);

  final now = DateTime.now();
  var cursor = now;
  final log = EventLog.open(p.join(data, 'log.db'), nodeId: id, clock: () => cursor);
  try {
    if (log.count() > 0) {
      stderr.writeln('El directorio $data ya tiene ${log.count()} eventos: no se mezclan datos de exposición con otros. Use un directorio vacío.');
      exit(65);
    }
    final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
    final ingest = Ingest(log: log, key: key, clock: () => cursor);
    final pipeline = PipelineRunner(log);
    final scenario = buildExpoScenario(seed: seed);
    for (final r in scenario) {
      cursor = now.subtract(Duration(minutes: r.minutesAgo));
      final frame = encodeReportFrame(
        ReportFrame(
          deviceId: deviceIdFromHex(r.device),
          seq: 1,
          rev: 0,
          refSeq: null,
          prioHint: prioHintFromFlags(r.flags),
          incidentType: 1,
          flags: r.flags,
          peopleBucket: r.people,
          locQuality: LocQuality.within50m,
          lat: r.lat,
          lon: r.lon,
          capturedAt: cursor.millisecondsSinceEpoch ~/ 1000 - 20,
          batteryQ: 8,
          text: r.text,
        ),
        key,
      );
      final result = ingest.handleFrame(frame, channel: 'expo');
      if (result.outcome != IngestOutcome.stored) throw StateError('el nodo no guardó un reporte del escenario: ${result.outcome}');
      pipeline.run(result.event!);
    }
    cursor = now;
    stdout.writeln('Escenario de exposición sembrado en $data: ${scenario.length} reportes sintéticos de las últimas ${kExpoWindowMinutes ~/ 60} h (semilla $seed), ${log.count()} eventos.');
    for (final z in kExpoZones) {
      final n = scenario.where((r) => r.zone == z.name).length;
      stdout.writeln('  ${z.name.padRight(11)} $n reportes · ${z.silentSinceMinutes == null ? 'sigue reportando' : 'EN SILENCIO desde hace ~${z.silentSinceMinutes} min'}');
    }
    stdout.writeln('Las zonas «siguen reportando» pasarán a silencio por sí solas 30 min después de arrancar: el escenario es una foto de AHORA.');
  } finally {
    log.close();
  }
}
