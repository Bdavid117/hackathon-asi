import 'dart:typed_data';

import 'frame_exceptions.dart';
import 'pow2.dart';
import 'tag.dart';

/// Tipo de mensaje `ACK`.
const int kTypeAck = 2;

/// Longitud de un ACK en bytes: ver|tipo, flags, device_id (8), ack_seq (4), bitmap (4), etiqueta (4).
const int kAckLength = 22;

const int _maxUint32 = 4294967295;

/// ACK selectivo con ventana hacia atrás.
///
/// [ackSeq] es la trama que se responde; el bit *i* (el menos significativo es el 0) de
/// [bitmap] indica que el nodo guarda además la trama `ackSeq - 1 - i`.
///
/// **Invariante:** un ACK sólo cubre tramas que el nodo que lo emite tiene guardadas.
class Ack {
  Ack({required this.deviceId, required this.ackSeq, required this.bitmap}) {
    if (deviceId.length != 8) throw ArgumentError.value(deviceId.length, 'deviceId', 'debe medir 8 bytes');
    if (ackSeq < 0 || ackSeq > _maxUint32) throw ArgumentError.value(ackSeq, 'ackSeq');
    if (bitmap < 0 || bitmap > _maxUint32) throw ArgumentError.value(bitmap, 'bitmap');
  }

  final Uint8List deviceId;
  final int ackSeq;
  final int bitmap;

  /// ¿Confirma este ACK la trama [seq]?
  bool covers(int seq) {
    if (seq == ackSeq) return true;
    final d = ackSeq - seq;
    if (d < 1 || d > 32) return false;
    return (bitmap ~/ kPow2[d - 1]) % 2 == 1;
  }
}

Uint8List encodeAck(Ack a, Uint8List key) {
  final body = BytesBuilder()
    ..addByte(kTypeAck)
    ..addByte(0)
    ..add(a.deviceId)
    ..add((ByteData(4)..setUint32(0, a.ackSeq)).buffer.asUint8List())
    ..add((ByteData(4)..setUint32(0, a.bitmap)).buffer.asUint8List());
  final b = body.toBytes();
  return Uint8List.fromList([...b, ...computeTag(key, b)]);
}

/// Decodifica y valida un ACK. Lanza una subclase de [FrameException].
Ack decodeAck(Uint8List bytes, Uint8List key) {
  if (bytes.length < 2) throw const TruncatedFrame('menos de 2 bytes');
  if (bytes[0] >> 4 != 0) throw UnsupportedVersion('versión ${bytes[0] >> 4}');
  if (bytes[0] & 0x0F != kTypeAck) throw WrongType('tipo ${bytes[0] & 0x0F}');
  if (bytes.length < kAckLength) throw const TruncatedFrame('un ACK mide 22 bytes');
  if (bytes.length > kAckLength) throw const FrameException('bytes sobrantes en el ACK');
  final body = Uint8List.sublistView(bytes, 0, kAckLength - kTagLength);
  if (!tagsEqual(computeTag(key, body), bytes.sublist(kAckLength - kTagLength))) {
    throw const BadTag('la etiqueta de integridad no coincide');
  }
  final bd = ByteData.sublistView(bytes);
  return Ack(
    deviceId: Uint8List.fromList(bytes.sublist(2, 10)),
    ackSeq: bd.getUint32(10),
    bitmap: bd.getUint32(14),
  );
}

/// Tramas de un dispositivo que un nodo guarda. Un tracker por dispositivo.
class AckTracker {
  final Set<int> _seen = <int>{};

  void record(int seq) => _seen.add(seq);

  bool has(int seq) => _seen.contains(seq);

  /// ACK para [ackSeq]; el `bitmap` sólo contiene tramas que este nodo guarda.
  Ack build(Uint8List deviceId, int ackSeq) {
    if (!has(ackSeq)) throw StateError('el nodo no guarda la trama $ackSeq: no puede acusarla');
    var bitmap = 0;
    for (var i = 0; i < 32; i++) {
      final seq = ackSeq - 1 - i;
      if (seq < 0) break;
      if (has(seq)) bitmap += kPow2[i];
    }
    return Ack(deviceId: deviceId, ackSeq: ackSeq, bitmap: bitmap);
  }
}
