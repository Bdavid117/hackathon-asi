// Proceso hijo de T01: abre la bandeja del teléfono y encola SOS (y alguna revisión) a toda velocidad,
// imprimiendo «OK <n>» DESPUÉS de que `enqueue*` volvió (es decir, tras el commit con synchronous=FULL).
// El padre lo mata con kill -9 en un punto cualquiera.
//   dart run test/support/t01_child.dart <ruta-de-la-bandeja> <cuántos>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

void main(List<String> args) {
  final path = args[0];
  final n = int.parse(args[1]);
  final outbox = Outbox.open(path, key: Uint8List.fromList(utf8.encode('clave-de-ejemplo')));
  var keys = <String>[];
  for (var i = 1; i <= n; i++) {
    final e = outbox.enqueueSos(
      NewReport(
        incidentType: 1,
        flags: i.isEven ? SituationFlags.atrapado : SituationFlags.herido,
        peopleBucket: i % 6,
        batteryQ: 8,
        locQuality: LocQuality.within50m,
        lat: 5.07 + i * 0.0001,
        lon: -75.51,
        text: i % 3 == 0 ? 'texto del reporte $i' : null,
      ),
      now: DateTime.fromMillisecondsSinceEpoch(1786370851000 + i * 1000),
    );
    keys.add(e.reportKey);
    // cada cuatro SOS se añade una revisión del anterior: también es una escritura que no puede perderse
    if (i % 4 == 0) {
      outbox.enqueueRevision(
        keys[keys.length - 2],
        NewReport(incidentType: 1, flags: 0, peopleBucket: 2, batteryQ: 8, locQuality: LocQuality.none),
        now: DateTime.fromMillisecondsSinceEpoch(1786370851000 + i * 1000 + 500),
      );
      stdout.writeln('REV $i');
    }
    stdout.writeln('OK $i');
  }
  stdout.writeln('FIN');
  outbox.close();
}
