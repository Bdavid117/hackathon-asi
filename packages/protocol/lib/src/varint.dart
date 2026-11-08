import 'dart:typed_data';

const int _maxUint32 = 4294967295;

/// Codifica un entero de 0 a 2^32-1 como LEB128 (7 bits por byte, bit alto = continúa).
Uint8List encodeVarint(int n) {
  if (n < 0 || n > _maxUint32) {
    throw ArgumentError.value(n, 'n', 'debe estar entre 0 y 4294967295');
  }
  final out = <int>[];
  var v = n;
  while (v >= 0x80) {
    out.add((v % 128) | 0x80);
    v = v ~/ 128;
  }
  out.add(v);
  return Uint8List.fromList(out);
}

/// Decodifica un varint que empieza en [offset]. Lanza [FormatException] si está truncado
/// o excede 32 bits.
({int value, int length}) decodeVarint(Uint8List bytes, int offset) {
  var value = 0;
  var mult = 1;
  for (var i = 0; i < 5; i++) {
    if (offset + i >= bytes.length) {
      throw const FormatException('varint truncado');
    }
    final b = bytes[offset + i];
    value += (b & 0x7F) * mult;
    if (b < 0x80) {
      if (value > _maxUint32) throw const FormatException('varint excede 32 bits');
      return (value: value, length: i + 1);
    }
    mult *= 128;
  }
  throw const FormatException('varint demasiado largo');
}
