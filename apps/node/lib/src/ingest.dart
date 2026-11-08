import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

import 'event_log.dart';

enum IngestOutcome { stored, duplicate, rejected }

class IngestResult {
  const IngestResult(this.outcome, {this.ack, this.event});

  final IngestOutcome outcome;

  /// Bytes del ACK; `null` si la trama se rechazó.
  final Uint8List? ack;

  /// El evento `report.received` escrito; `null` en duplicados y rechazos.
  final Event? event;
}

/// Recibe tramas `REPORT`: las valida, las guarda como evento y las acusa.
///
/// El ACK se calcula **después** de escribir el evento (escritura durable). Un duplicado
/// ya guardado se vuelve a acusar, porque el ACK anterior pudo perderse.
class Ingest {
  Ingest({required EventLog log, required Uint8List key, DateTime Function()? clock})
      : _log = log,
        _key = key,
        _clock = clock ?? DateTime.now {
    // Reconstruye qué tramas guarda este nodo (incluidas las replicadas) a partir del log.
    for (final e in _log.all()) {
      if (e.type != kReceivedType) continue;
      _tracker(e.body['device_id']! as String).record(e.body['frame_seq']! as int);
    }
  }

  static const String kReceivedType = 'report.received';

  final EventLog _log;
  final Uint8List _key;
  final DateTime Function() _clock;
  final Map<String, AckTracker> _trackers = {};

  AckTracker _tracker(String deviceHex) => _trackers.putIfAbsent(deviceHex, AckTracker.new);

  IngestResult handleFrame(Uint8List bytes, {String channel = 'http'}) {
    final ReportFrame f;
    try {
      f = decodeReportFrame(bytes, _key);
    } on FrameException {
      return const IngestResult(IngestOutcome.rejected);
    }
    final deviceHex = deviceIdToHex(f.deviceId);
    final tracker = _tracker(deviceHex);

    if (_log.find(kReceivedType, f.reportKey, f.rev) != null) {
      tracker.record(f.seq);
      return IngestResult(IngestOutcome.duplicate, ack: _ack(tracker, f));
    }
    final event = _log.append(
      kReceivedType,
      {
        'device_id': deviceHex,
        'frame_seq': f.seq,
        'ref_seq': f.refSeq,
        'prio_hint': f.prioHint,
        'incident_type': f.incidentType,
        'flags': f.flags,
        'people_bucket': f.peopleBucket,
        'loc_quality': f.locQuality.index,
        'lat': f.lat,
        'lon': f.lon,
        'captured_at': f.capturedAt,
        'battery_q': f.batteryQ,
        'text': f.text,
        'received_at': _clock().millisecondsSinceEpoch,
        'channel': channel,
      },
      reportKey: f.reportKey,
      rev: f.rev,
    );
    tracker.record(f.seq);
    return IngestResult(IngestOutcome.stored, ack: _ack(tracker, f), event: event);
  }

  Uint8List _ack(AckTracker tracker, ReportFrame f) => encodeAck(tracker.build(f.deviceId, f.seq), _key);
}
