import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sard_protocol/sard_protocol.dart';

final Uint8List _key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

/// Un escenario FIJO y pequeño (10 tramas, 8 incidentes) para el tablero: un P1 con texto, un grupo de
/// dos reportes, un incendio sin ubicación, un texto que no se entiende, tres SOS sin detalle y un P3
/// informativo. Se envía por HTTP a un nodo en marcha. Los tiempos son los de [t0] (fijos: el
/// contenido no depende del día), no los de ahora.
Future<void> postScenario(Uri node, http.Client client, {int t0 = 1786370851}) async {
  var n = 0;
  Future<void> send(String device, int flags, {String? text, double? lat = 5.0703, double? lon = -75.5138, int people = 0, int at = 0, int rev = 0, int? refSeq, int? seq}) async {
    final s = seq ?? ++n;
    final f = encodeReportFrame(
      ReportFrame(
        deviceId: deviceIdFromHex(device),
        seq: s,
        rev: rev,
        refSeq: refSeq,
        prioHint: prioHintFromFlags(flags),
        incidentType: 1,
        flags: flags,
        peopleBucket: people,
        locQuality: lat == null ? LocQuality.none : LocQuality.within50m,
        lat: lat,
        lon: lon,
        capturedAt: t0 + at,
        batteryQ: 8,
        text: text,
      ),
      _key,
    );
    final r = await client.post(node.resolve('/frame'), body: f);
    if (r.statusCode != 200) throw StateError('el nodo rechazó una trama: ${r.statusCode}');
  }

  // 1) un P1: atrapados y heridos, con personas y una frase
  await send('00000000000000a1', SituationFlags.atrapado | SituationFlags.herido, people: 2, at: 0); // seq 1
  await send('00000000000000a1', SituationFlags.atrapado | SituationFlags.herido, people: 2, at: 20, rev: 1, refSeq: 1, text: 'mi mamá no puede salir del segundo piso, hay mucho polvo', seq: 2);
  // 2) un incidente de dos reportes (mismo lugar, mismo texto parecido)
  await send('00000000000000b1', SituationFlags.viaBloqueada, text: 'puente colapsado calle veinte carros abajo', lat: 5.0652, lon: -75.5095, at: 60, seq: 1);
  await send('00000000000000b2', SituationFlags.viaBloqueada, text: 'puente colapsado calle veinte carros gente', lat: 5.0653, lon: -75.5095, at: 90, seq: 1);
  // 3) un incendio sin ubicación (incertidumbre alta)
  await send('00000000000000c1', SituationFlags.incendio, lat: null, lon: null, at: 120, seq: 1);
  // 4) un texto que las reglas no entienden (a revisar)
  await send('00000000000000d1', 0, text: 'zzz qqq xxx www vvv', lat: 5.0810, lon: -75.4900, at: 150, seq: 1);
  // 5) SOS sin detalle (tres, en sitios distintos)
  await send('00000000000000e1', 0, lat: 5.0901, lon: -75.5301, at: 180, seq: 1);
  await send('00000000000000e2', 0, lat: 5.0411, lon: -75.4701, at: 200, seq: 1);
  await send('00000000000000e3', 0, lat: 5.0201, lon: -75.5601, at: 220, seq: 1);
  // 6) un P3 informativo
  await send('00000000000000f1', SituationFlags.menoresMayores, text: 'hay niños en la casa pero estamos bien', lat: 5.0350, lon: -75.4400, at: 240, seq: 1);
}
