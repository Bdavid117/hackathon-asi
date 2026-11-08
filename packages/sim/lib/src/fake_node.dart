import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

/// Un nodo en memoria que usa el protocolo de verdad: decodifica y valida cada trama, la
/// guarda (una vez por reporte y revisión) y responde un ACK real que sólo cubre lo que guarda.
class FakeNodeChannel implements Channel {
  FakeNodeChannel(this._key);

  final Uint8List _key;
  final Set<String> _stored = {};
  final Map<String, AckTracker> _trackers = {};

  /// Tramas distintas guardadas, por (reporte, revisión).
  int get received => _stored.length;

  /// Tramas válidas recibidas, contando duplicados.
  int deliveries = 0;

  @override
  Future<Uint8List?> send(Uint8List frame) async {
    final ReportFrame f;
    try {
      f = decodeReportFrame(frame, _key);
    } on FrameException {
      return null;
    }
    deliveries++;
    _stored.add('${f.reportKey}#${f.rev}');
    final tracker = _trackers.putIfAbsent(deviceIdToHex(f.deviceId), AckTracker.new)..record(f.seq);
    return encodeAck(tracker.build(f.deviceId, f.seq), _key);
  }
}
