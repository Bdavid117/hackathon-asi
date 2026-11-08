import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('codifica 0, 127 y 128 como LEB128', () {
    expect(encodeVarint(0), [0x00]);
    expect(encodeVarint(127), [0x7F]);
    expect(encodeVarint(128), [0x80, 0x01]);
  });

  test('ida y vuelta del máximo de 32 bits', () {
    final b = encodeVarint(4294967295);
    final r = decodeVarint(b, 0);
    expect(r.value, 4294967295);
    expect(r.length, b.length);
  });

  test('decodifica desde un desplazamiento', () {
    final r = decodeVarint(Uint8List.fromList([0xAA, 0x80, 0x01]), 1);
    expect(r.value, 128);
    expect(r.length, 2);
  });

  test('un varint truncado lanza FormatException', () {
    expect(() => decodeVarint(Uint8List.fromList([0x80]), 0), throwsFormatException);
  });

  test('rechaza valores fuera de 0..2^32-1', () {
    expect(() => encodeVarint(-1), throwsArgumentError);
    expect(() => encodeVarint(4294967296), throwsArgumentError);
  });
}
