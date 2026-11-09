import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';

/// Escribe un `report.received` con el mismo cuerpo que produce `Ingest`.
Event received(
  EventLog log,
  String reportKey,
  int rev, {
  int flags = 0,
  int locQuality = 2,
  double? lat = 5.0703,
  double? lon = -75.5138,
  String? text,
  int capturedAt = 1786370851,
  int receivedAt = 5000,
  int people = 0,
  String? device,
}) => log.append(
  'report.received',
  {
    'device_id': device ?? reportKey.split('-').first,
    'frame_seq': rev + 1,
    'flags': flags,
    'people_bucket': people,
    'incident_type': 1,
    'loc_quality': locQuality,
    'lat': lat,
    'lon': lon,
    'text': text,
    'captured_at': capturedAt,
    'received_at': receivedAt,
  },
  reportKey: reportKey,
  rev: rev,
);

/// Recursos de prueba alrededor del punto (5.0703, -75.5138).
List<Resource> testResources({bool ambulanceAvailable = true}) => parseResources('''
{"resources": [
  {"id": "AMB-01", "kind": "ambulancia", "label": "Ambulancia 1", "lat": 5.0710, "lon": -75.5140, "available": $ambulanceAvailable},
  {"id": "BOM-01", "kind": "bomberos", "label": "Bomberos 1", "lat": 5.0720, "lon": -75.5150, "available": true},
  {"id": "RES-01", "kind": "rescate", "label": "Rescate 1", "lat": 5.0730, "lon": -75.5160, "available": true},
  {"id": "TRA-01", "kind": "transito", "label": "Tránsito 1", "lat": 5.0740, "lon": -75.5170, "available": true}
]}
''');
