import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BitWriter', () {
    test('empaqueta 4 + 4 bits en un solo byte', () {
      final w = BitWriter()..put(0xA, 4)..put(0x5, 4);
      expect(w.toBytes(), [0xA5]);
      expect(w.bitLength, 8);
    });

    test('rellena con ceros a la derecha hasta completar el byte', () {
      final w = BitWriter()..put(1, 1);
      expect(w.toBytes(), [0x80]);
    });

    test('rechaza un valor que no cabe en los bits indicados', () {
      expect(() => BitWriter().put(16, 4), throwsArgumentError);
      expect(() => BitWriter().put(-1, 4), throwsArgumentError);
    });

    test('rechaza anchos fuera de 1..32', () {
      expect(() => BitWriter().put(0, 0), throwsArgumentError);
      expect(() => BitWriter().put(0, 33), throwsArgumentError);
    });
  });

  group('BitReader', () {
    test('ida y vuelta de los anchos del protocolo (4/8/3/3/24/25/32)', () {
      final fields = <(int, int)>[
        (9, 4), (0xC0, 8), (5, 3), (2, 3), (0xABCDEF, 24), (0x1234567, 25), (0xFFFFFFFF, 32),
      ];
      final w = BitWriter();
      for (final (v, b) in fields) {
        w.put(v, b);
      }
      final r = BitReader(w.toBytes());
      for (final (v, b) in fields) {
        expect(r.get(b), v, reason: 'campo de $b bits');
      }
      expect(r.bitsRead, 4 + 8 + 3 + 3 + 24 + 25 + 32);
    });

    test('bytesConsumed redondea hacia arriba', () {
      final r = BitReader(Uint8List.fromList([0xFF, 0xFF]));
      r.get(9);
      expect(r.bytesConsumed, 2);
      final r2 = BitReader(Uint8List.fromList([0xFF, 0xFF]));
      r2.get(8);
      expect(r2.bytesConsumed, 1);
    });

    test('leer más allá del final lanza FormatException', () {
      final r = BitReader(Uint8List.fromList([0xFF]));
      r.get(8);
      expect(() => r.get(1), throwsFormatException);
    });
  });
}
