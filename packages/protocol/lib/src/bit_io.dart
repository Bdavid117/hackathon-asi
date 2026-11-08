import 'dart:typed_data';

import 'pow2.dart';

/// Escribe campos de 1 a 32 bits, el más significativo primero, sin relleno entre campos.
///
/// Es seguro en VM y en Web: nunca desplaza más de 8 bits sobre un entero y
/// trata los valores de hasta 32 bits con aritmética, no con operadores de bits.
class BitWriter {
  final List<int> _bytes = <int>[];
  int _bits = 0;

  /// Número de bits escritos hasta ahora.
  int get bitLength => _bits;

  void put(int value, int bits) {
    if (bits < 1 || bits > 32) {
      throw ArgumentError.value(bits, 'bits', 'debe estar entre 1 y 32');
    }
    if (value < 0 || value >= kPow2[bits]) {
      throw ArgumentError.value(value, 'value', 'no cabe en $bits bits');
    }
    for (var i = bits - 1; i >= 0; i--) {
      _putBit((value ~/ kPow2[i]) % 2);
    }
  }

  void _putBit(int bit) {
    if (_bits % 8 == 0) _bytes.add(0);
    if (bit == 1) _bytes[_bytes.length - 1] |= 0x80 >> (_bits % 8);
    _bits++;
  }

  /// Los bits escritos, rellenados con ceros a la derecha hasta un byte entero.
  Uint8List toBytes() => Uint8List.fromList(_bytes);
}

/// Lee campos de 1 a 32 bits escritos por [BitWriter].
class BitReader {
  BitReader(this._bytes);

  final Uint8List _bytes;
  int _bits = 0;

  /// Bits leídos hasta ahora.
  int get bitsRead => _bits;

  /// Bytes que ocupan los bits leídos (redondeo hacia arriba).
  int get bytesConsumed => (_bits + 7) ~/ 8;

  int get(int bits) {
    if (bits < 1 || bits > 32) {
      throw ArgumentError.value(bits, 'bits', 'debe estar entre 1 y 32');
    }
    if (_bits + bits > _bytes.length * 8) {
      throw const FormatException('lectura más allá del final de los datos');
    }
    var result = 0;
    for (var i = 0; i < bits; i++) {
      final byte = _bytes[_bits ~/ 8];
      final bit = (byte >> (7 - _bits % 8)) & 1;
      result = result * 2 + bit;
      _bits++;
    }
    return result;
  }
}
