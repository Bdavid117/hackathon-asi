import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

/// Clave de los vectores de oro.
final Uint8List testKey = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

/// Bytes de un vector de oro del oráculo de Python (generados en `packages/protocol/test/vectors`).
Uint8List vectorBytes(String name) {
  final all = jsonDecode(File('../../packages/protocol/test/vectors/vectors.json').readAsStringSync()) as List<Object?>;
  final v = all.cast<Map<String, Object?>>().firstWhere((x) => x['name'] == name);
  return bytesFromHex(v['hex']! as String);
}

/// Un reporte nuevo (rev 0) válido con el `seq` indicado.
Uint8List sosFrame(int seq, {String deviceHex = '9a3c51e07b2d44f1', int flags = 0x80}) => encodeReportFrame(
      ReportFrame(
        deviceId: deviceIdFromHex(deviceHex), seq: seq, rev: 0, prioHint: prioHintFromFlags(flags), incidentType: 3,
        flags: flags, peopleBucket: 1, locQuality: LocQuality.within50m, lat: 5.07, lon: -75.51,
        capturedAt: 1786370851, batteryQ: 3,
      ),
      testKey,
    );
