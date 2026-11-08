import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

import 'vectors/vectors.g.dart';

/// Clave de los vectores de oro.
final Uint8List testKey = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

/// Vectores generados por el oráculo de Python (`docs/src/tools/frame_size.py`).
List<Map<String, Object?>> vectors({String? kind}) {
  final all = (jsonDecode(kVectorsJson) as List<Object?>).cast<Map<String, Object?>>();
  return kind == null ? all : all.where((v) => v['kind'] == kind).toList();
}

Map<String, Object?> vector(String name) => vectors().firstWhere((v) => v['name'] == name);

Uint8List hexBytes(String hex) => bytesFromHex(hex);

/// Construye un [ReportFrame] a partir de la entrada JSON de un vector.
ReportFrame frameFromInput(Map<String, Object?> i) => ReportFrame(
      deviceId: deviceIdFromHex(i['device_id']! as String),
      seq: i['seq']! as int,
      rev: i['rev']! as int,
      refSeq: i['ref_seq'] as int?,
      prioHint: i['prio_hint']! as int,
      incidentType: i['incident_type']! as int,
      flags: i['flags']! as int,
      peopleBucket: i['people_bucket']! as int,
      locQuality: LocQuality.values[i['loc_quality']! as int],
      lat: (i['lat'] as num?)?.toDouble(),
      lon: (i['lon'] as num?)?.toDouble(),
      capturedAt: i['captured_at']! as int,
      batteryQ: i['battery_q']! as int,
      text: i['text'] as String?,
    );
