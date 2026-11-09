import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'event_log.dart';

/// Un reporte con todas sus revisiones fundidas. Es lo que ven el triaje de lectura, el
/// agrupamiento y la cola, y no depende del orden en que las revisiones entraron en el log.
class MergedReport {
  const MergedReport({
    required this.reportKey,
    required this.deviceId,
    required this.incidentType,
    required this.rev,
    required this.flags,
    required this.lat,
    required this.lon,
    required this.locQuality,
    required this.text,
    required this.capturedAt,
    required this.receivedAtMs,
  });

  final String reportKey;
  final String deviceId;
  final int incidentType;

  /// Revisión más alta conocida.
  final int rev;
  final int flags;
  final double? lat;
  final double? lon;
  final LocQuality locQuality;
  final String? text;

  /// Segundos desde la época, según el teléfono (revisión 0).
  final int capturedAt;

  /// Cuándo recibió este nodo la primera trama del reporte.
  final int receivedAtMs;

  bool get hasLocation => lat != null && lon != null;

  /// Lo que el agente 3 sabe del reporte. Todo lo que llega por una trama es de la app.
  Observation toObservation() => Observation(
    reportKey: reportKey,
    deviceId: deviceId,
    incidentType: incidentType,
    flags: flags,
    lat: lat,
    lon: lon,
    locQuality: hasLocation ? locQuality : LocQuality.none,
    capturedAtMs: capturedAt * 1000,
    text: text,
    sourceClass: 'app',
  );
}

/// Funde por reporte los `report.received` dados: gana la revisión más alta; la ubicación y el
/// texto sólo se sobrescriben cuando la revisión trae un valor (una revisión sin ubicación no borra
/// la anterior). Lee con tolerancia: un cuerpo al que le falte algún campo no rompe la cola.
List<MergedReport> mergeReports(Iterable<Event> received) {
  final byReport = <String, List<Event>>{};
  for (final e in received) {
    if (e.type != 'report.received' || e.reportKey == null) continue;
    byReport.putIfAbsent(e.reportKey!, () => []).add(e);
  }
  final out = <MergedReport>[];
  byReport.forEach((key, events) {
    events.sort((a, b) => (a.rev ?? 0).compareTo(b.rev ?? 0));
    var flags = 0, capturedAt = 0, type = 1;
    double? lat, lon;
    var q = LocQuality.none;
    String? text;
    var receivedAt = (events.first.body['received_at'] as num?)?.toInt() ?? 0;
    final device = (events.first.body['device_id'] as String?) ?? key.split('-').first;
    for (final e in events) {
      final b = e.body;
      flags = (b['flags'] as num?)?.toInt() ?? flags;
      type = (b['incident_type'] as num?)?.toInt() ?? type;
      if (b['lat'] != null && b['lon'] != null) {
        lat = (b['lat']! as num).toDouble();
        lon = (b['lon']! as num).toDouble();
        final qi = (b['loc_quality'] as num?)?.toInt() ?? 0;
        q = LocQuality.values[qi.clamp(0, LocQuality.values.length - 1)];
      }
      if (b['text'] != null) text = b['text'] as String;
      final c = (b['captured_at'] as num?)?.toInt();
      if (c != null && (e.rev == 0 || capturedAt == 0)) capturedAt = c;
      final r = (b['received_at'] as num?)?.toInt() ?? 0;
      if (r < receivedAt) receivedAt = r;
    }
    out.add(
      MergedReport(
        reportKey: key,
        deviceId: device,
        incidentType: type,
        rev: events.last.rev ?? 0,
        flags: flags,
        lat: lat,
        lon: lon,
        locQuality: q,
        text: text,
        capturedAt: capturedAt,
        receivedAtMs: receivedAt,
      ),
    );
  });
  return out;
}
