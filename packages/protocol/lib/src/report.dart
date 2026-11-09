import 'dart:convert';
import 'dart:typed_data';

import 'hex.dart';

/// Calidad de la ubicación; el valor de red es [index] (0..6).
enum LocQuality {
  none,
  within10m,
  within50m,
  within200m,
  within1km,
  over1km,
  manual;

  /// Sólo estas calidades llevan latitud y longitud en la trama.
  bool get hasCoordinates => index >= 1 && index <= 5;
}

/// Máximo de bytes UTF-8 del texto libre.
const int kMaxTextBytes = 140;

const int _maxUint32 = 4294967295;

/// Bits del campo `flags` de situación (el más significativo primero).
abstract final class SituationFlags {
  static const int atrapado = 0x80;
  static const int herido = 0x40;
  static const int incendio = 0x20;
  static const int dificultadRespiratoria = 0x10;
  static const int viaBloqueada = 0x08;
  static const int estructuraInestable = 0x04;
  static const int menoresMayores = 0x02;
  static const int medicacion = 0x01;
}

/// La única tabla de prioridad del proyecto: 0 = P1 … 3 = P4.
///
/// Piso por reglas: «atrapado», «dificultad respiratoria» e «incendio» nunca producen
/// menos que P2.
///
/// **Sin banderas devuelve P3 (2), no P4**: un SOS sin detalle no es «poco urgente», es «no se
/// sabe», y la ficha del agente 2 dice que la falta de datos nunca baja la urgencia. Por eso desde
/// las banderas nunca sale P4 (3); ese nivel sólo lo da el triaje cuando el texto dice
/// explícitamente que no hay peligro («sin heridos») y nada más.
int prioHintFromFlags(int flags) {
  bool has(int f) => flags & f != 0;
  if (has(SituationFlags.dificultadRespiratoria) ||
      (has(SituationFlags.atrapado) && has(SituationFlags.herido)) ||
      (has(SituationFlags.atrapado) && has(SituationFlags.incendio))) {
    return 0;
  }
  if (has(SituationFlags.atrapado) ||
      has(SituationFlags.incendio) ||
      has(SituationFlags.herido) ||
      has(SituationFlags.estructuraInestable)) {
    return 1;
  }
  if (has(SituationFlags.viaBloqueada) || has(SituationFlags.menoresMayores) || has(SituationFlags.medicacion)) {
    return 2;
  }
  return 2; // sin banderas: sin datos no baja la urgencia
}

/// Recorta [s] a como mucho [maxBytes] bytes UTF-8 sin partir nunca un carácter.
String truncateUtf8(String s, int maxBytes) {
  var used = 0;
  final kept = <int>[];
  for (final rune in s.runes) {
    final len = utf8.encode(String.fromCharCode(rune)).length;
    if (used + len > maxBytes) break;
    used += len;
    kept.add(rune);
  }
  return String.fromCharCodes(kept);
}

String deviceIdToHex(Uint8List id) => bytesToHex(id);

Uint8List deviceIdFromHex(String hex) {
  final b = bytesFromHex(hex);
  if (b.length != 8) throw ArgumentError.value(hex, 'hex', 'el device_id mide 8 bytes');
  return b;
}

/// Una trama `REPORT` decodificada (un reporte nuevo, `rev == 0`, o una revisión, `rev > 0`).
class ReportFrame {
  ReportFrame({
    required this.deviceId,
    required this.seq,
    required this.rev,
    this.refSeq,
    required this.prioHint,
    required this.incidentType,
    required this.flags,
    required this.peopleBucket,
    required this.locQuality,
    this.lat,
    this.lon,
    required this.capturedAt,
    required this.batteryQ,
    this.text,
  }) {
    _range('seq', seq, _maxUint32);
    _range('rev', rev, 255);
    _range('prioHint', prioHint, 3);
    _range('incidentType', incidentType, 15);
    _range('flags', flags, 255);
    _range('peopleBucket', peopleBucket, 7);
    _range('capturedAt', capturedAt, _maxUint32);
    _range('batteryQ', batteryQ, 15);
    if (deviceId.length != 8) throw ArgumentError.value(deviceId.length, 'deviceId', 'debe medir 8 bytes');
    if (rev == 0 && refSeq != null) throw ArgumentError('una revisión 0 no lleva refSeq');
    if (rev > 0) {
      if (refSeq == null) throw ArgumentError('una revisión > 0 exige refSeq');
      _range('refSeq', refSeq!, _maxUint32);
    }
    if (locQuality.hasCoordinates) {
      if (lat == null || lon == null) throw ArgumentError('la calidad $locQuality exige lat y lon');
      if (lat! < -90 || lat! > 90 || lon! < -180 || lon! > 180) throw ArgumentError('lat/lon fuera de rango');
    } else if (lat != null || lon != null) {
      throw ArgumentError('la calidad $locQuality no lleva lat/lon');
    }
    if (text != null) {
      final n = utf8.encode(text!).length;
      if (n == 0 || n > kMaxTextBytes) throw ArgumentError.value(n, 'text', 'debe medir 1..$kMaxTextBytes bytes UTF-8');
    }
  }

  final Uint8List deviceId;

  /// Contador de **tramas** del dispositivo (cada trama consume uno).
  final int seq;
  final int rev;

  /// `seq` de la trama de revisión 0 del mismo reporte; nulo cuando `rev == 0`.
  final int? refSeq;
  final int prioHint;
  final int incidentType;
  final int flags;
  final int peopleBucket;
  final LocQuality locQuality;
  final double? lat;
  final double? lon;
  final int capturedAt;
  final int batteryQ;
  final String? text;

  /// Identifica al reporte en todas sus revisiones: `device_id` + `seq` de la trama rev 0.
  String get reportKey => '${deviceIdToHex(deviceId)}-${refSeq ?? seq}';

  static void _range(String name, int v, int max) {
    if (v < 0 || v > max) throw ArgumentError.value(v, name, 'debe estar entre 0 y $max');
  }
}
