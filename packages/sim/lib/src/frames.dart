import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

import 'synth.dart';

/// Una trama de un reporte sintético, con la clave con la que la verá el nodo.
class SynthFrame {
  const SynthFrame(this.reportKey, this.bytes, this.source);
  final String reportKey; // «<dispositivo>-<seq>», como la calcula el nodo
  final Uint8List bytes;
  final SynthReport source;
}

/// Convierte reportes sintéticos en tramas SARD-WIRE válidas (rev 0), numerando la secuencia por
/// dispositivo en el orden dado. Determinista: los mismos reportes dan las mismas tramas y claves.
/// El texto vacío (que el generador puede producir) se envía como «sin texto».
List<SynthFrame> synthFrames(List<SynthReport> reports, Uint8List key) {
  final seqs = <String, int>{};
  return [
    for (final r in reports)
      () {
        final seq = seqs[r.deviceId] = (seqs[r.deviceId] ?? 0) + 1;
        final text = (r.text == null || r.text!.isEmpty) ? null : r.text;
        final bytes = encodeReportFrame(
          ReportFrame(
            deviceId: deviceIdFromHex(r.deviceId),
            seq: seq,
            rev: 0,
            prioHint: prioHintFromFlags(r.flags),
            incidentType: r.incidentType,
            flags: r.flags,
            peopleBucket: 0,
            locQuality: r.locQuality,
            lat: r.lat,
            lon: r.lon,
            capturedAt: (r.capturedAtMs ~/ 1000).clamp(0, 4294967295),
            batteryQ: 8,
            text: text,
          ),
          key,
        );
        return SynthFrame('${r.deviceId}-$seq', bytes, r);
      }(),
  ];
}

/// Una trama de un SOS con texto, DETERMINISTA por [n] (usada por T12, T18 y T19): las pares dicen «quedamos encerrados» (el modelo
/// falso `ok` las sube a P1) y las impares no. Cada [n] es un dispositivo distinto, con ubicación a ±50 m y la hora de [n].
Uint8List textReportFrame(int n, Uint8List key) => encodeReportFrame(
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
