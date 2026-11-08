import 'dart:convert';
import 'dart:typed_data';

import 'bit_io.dart';
import 'frame_exceptions.dart';
import 'report.dart';
import 'tag.dart';
import 'varint.dart';

/// Tipo de mensaje `REPORT`.
const int kTypeReport = 1;

const int _flagFrag = 0x80;
const int _flagAckReq = 0x40;
const int _flagSigned = 0x20;
const int _flagRev = 0x04;

const int _latMax = 16777215; // 2^24 - 1
const int _lonMax = 33554431; // 2^25 - 1

Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

int _readU32(Uint8List b, int o) => ByteData.sublistView(b, o, o + 4).getUint32(0);

/// Codifica un [ReportFrame] según SARD-WIRE v0 (PDF §7.2) y le añade la etiqueta.
Uint8List encodeReportFrame(ReportFrame f, Uint8List key) {
  final w = BitWriter()
    ..put(f.incidentType, 4)
    ..put(f.flags, 8)
    ..put(f.peopleBucket, 3)
    ..put(f.locQuality.index, 3);
  if (f.locQuality.hasCoordinates) {
    w
      ..put(((f.lat! + 90) / 180 * _latMax).round(), 24)
      ..put(((f.lon! + 180) / 360 * _lonMax).round(), 25);
  }
  w
    ..put(f.capturedAt, 32)
    ..put(f.batteryQ, 4)
    ..put(f.text != null ? 1 : 0, 1);

  final payload = BytesBuilder()..add(w.toBytes());
  if (f.text != null) {
    final t = utf8.encode(f.text!);
    payload
      ..add(encodeVarint(t.length))
      ..add(t);
  }
  final payloadBytes = payload.toBytes();

  final flags = _flagAckReq | _flagSigned | (f.prioHint << 3) | (f.rev > 0 ? _flagRev : 0);
  final out = BytesBuilder()
    ..addByte(kTypeReport) // versión 0 en el nibble alto
    ..addByte(flags)
    ..add(f.deviceId)
    ..add(_u32(f.seq))
    ..addByte(f.rev);
  if (f.rev > 0) out.add(_u32(f.refSeq!));
  out
    ..add(encodeVarint(payloadBytes.length))
    ..add(payloadBytes);
  final body = out.toBytes();
  return Uint8List.fromList([...body, ...computeTag(key, body)]);
}

/// Decodifica y valida una trama `REPORT`. Lanza una subclase de [FrameException].
ReportFrame decodeReportFrame(Uint8List bytes, Uint8List key) {
  if (bytes.length < 2) throw const TruncatedFrame('menos de 2 bytes');
  if (bytes[0] >> 4 != 0) throw UnsupportedVersion('versión ${bytes[0] >> 4}');
  if (bytes[0] & 0x0F != kTypeReport) throw WrongType('tipo ${bytes[0] & 0x0F}');
  final flags = bytes[1];
  if (flags & _flagFrag != 0) throw const UnsupportedFeature('fragmentación (FRAG) no implementada en v0');
  final isRev = flags & _flagRev != 0;

  final fixed = 2 + 8 + 4 + 1 + (isRev ? 4 : 0);
  if (bytes.length < fixed + 1 + kTagLength) throw const TruncatedFrame('cabecera incompleta');

  var o = 2;
  final deviceId = Uint8List.fromList(bytes.sublist(o, o + 8));
  o += 8;
  final seq = _readU32(bytes, o);
  o += 4;
  final rev = bytes[o];
  o += 1;
  int? refSeq;
  if (isRev) {
    refSeq = _readU32(bytes, o);
    o += 4;
  }
  final ({int value, int length}) len;
  try {
    len = decodeVarint(bytes, o);
  } on FormatException {
    throw const TruncatedFrame('largo de carga incompleto');
  }
  o += len.length;
  final total = o + len.value + kTagLength;
  if (bytes.length < total) throw const TruncatedFrame('la trama es más corta que su largo anunciado');
  if (bytes.length > total) throw const FrameException('bytes sobrantes tras la etiqueta');

  final body = Uint8List.sublistView(bytes, 0, total - kTagLength);
  if (!tagsEqual(computeTag(key, body), bytes.sublist(total - kTagLength))) {
    throw const BadTag('la etiqueta de integridad no coincide');
  }

  try {
    final payload = Uint8List.sublistView(bytes, o, o + len.value);
    final r = BitReader(payload);
    final incidentType = r.get(4);
    final situation = r.get(8);
    final people = r.get(3);
    final lq = r.get(3);
    if (lq > LocQuality.manual.index) throw const FrameException('calidad de ubicación reservada');
    final quality = LocQuality.values[lq];
    double? lat;
    double? lon;
    if (quality.hasCoordinates) {
      lat = r.get(24) / _latMax * 180 - 90;
      lon = r.get(25) / _lonMax * 360 - 180;
    }
    final capturedAt = r.get(32);
    final battery = r.get(4);
    final hasText = r.get(1) == 1;
    String? text;
    if (hasText) {
      final at = r.bytesConsumed;
      final t = decodeVarint(payload, at);
      final start = at + t.length;
      if (start + t.value > payload.length) throw const TruncatedFrame('texto incompleto');
      if (start + t.value != payload.length) throw const FrameException('bytes sobrantes en la carga');
      text = utf8.decode(payload.sublist(start, start + t.value));
    } else if (r.bytesConsumed != payload.length) {
      throw const FrameException('bytes sobrantes en la carga');
    }
    return ReportFrame(
      deviceId: deviceId,
      seq: seq,
      rev: rev,
      refSeq: refSeq,
      prioHint: (flags >> 3) & 3,
      incidentType: incidentType,
      flags: situation,
      peopleBucket: people,
      locQuality: quality,
      lat: lat,
      lon: lon,
      capturedAt: capturedAt,
      batteryQ: battery,
      text: text,
    );
  } on FormatException catch (e) {
    throw FrameException('carga inválida: ${e.message}');
  } on ArgumentError catch (e) {
    throw FrameException('valores inválidos: ${e.message}');
  }
}
