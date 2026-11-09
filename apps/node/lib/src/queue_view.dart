import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';

/// Un reporte (con todas sus revisiones fundidas) tal como lo ve el coordinador.
class QueueItem {
  const QueueItem({
    required this.reportKey,
    required this.urgency,
    required this.rev,
    required this.flags,
    this.lat,
    this.lon,
    this.text,
    required this.capturedAt,
    required this.receivedAtMs,
    required this.signals,
  });

  final String reportKey;
  final Urgency urgency;

  /// Revisión más alta conocida.
  final int rev;
  final int flags;
  final double? lat;
  final double? lon;
  final String? text;
  final int capturedAt;

  /// Cuándo recibió este nodo la primera trama del reporte.
  final int receivedAtMs;
  final List<String> signals;

  Map<String, Object?> toJson() => {
        'reportKey': reportKey,
        'urgency': urgency.name.toUpperCase(),
        'rev': rev,
        'flags': flags,
        'lat': lat,
        'lon': lon,
        'text': text,
        'capturedAt': capturedAt,
        'receivedAt': receivedAtMs,
        'signals': signals,
      };
}

/// Cola priorizada derivada del log. **No descarta ningún reporte.**
///
/// Las revisiones de un mismo reporte se funden por campo: gana la revisión más alta; la
/// ubicación y el texto sólo se sobrescriben cuando la revisión trae un valor (una
/// revisión sin ubicación no borra la anterior). El resultado no depende del orden en
/// que las revisiones entraron en el log.
List<QueueItem> buildQueue(EventLog log) {
  final byReport = <String, List<Event>>{};
  for (final e in log.all()) {
    if (e.type != 'report.received' || e.reportKey == null) continue;
    byReport.putIfAbsent(e.reportKey!, () => []).add(e);
  }
  final items = <QueueItem>[];
  byReport.forEach((key, events) {
    events.sort((a, b) => (a.rev ?? 0).compareTo(b.rev ?? 0));
    var flags = 0;
    double? lat;
    double? lon;
    String? text;
    var capturedAt = 0;
    var receivedAt = events.first.body['received_at'] as int? ?? 0;
    for (final e in events) {
      final b = e.body;
      flags = b['flags']! as int;
      if (b['lat'] != null && b['lon'] != null) {
        lat = (b['lat']! as num).toDouble();
        lon = (b['lon']! as num).toDouble();
      }
      if (b['text'] != null) text = b['text'] as String;
      if (e.rev == 0 || capturedAt == 0) capturedAt = b['captured_at']! as int;
      final r = b['received_at'] as int? ?? 0;
      if (r < receivedAt) receivedAt = r;
    }
    final t = triage(flags, text: text, hasLocation: lat != null);
    items.add(QueueItem(
      reportKey: key,
      urgency: t.urgency,
      rev: events.last.rev ?? 0,
      flags: flags,
      lat: lat,
      lon: lon,
      text: text,
      capturedAt: capturedAt,
      receivedAtMs: receivedAt,
      signals: t.signals,
    ));
  });
  items.sort((a, b) {
    final u = a.urgency.index.compareTo(b.urgency.index);
    if (u != 0) return u;
    final c = a.capturedAt.compareTo(b.capturedAt);
    return c != 0 ? c : a.reportKey.compareTo(b.reportKey);
  });
  return items;
}
