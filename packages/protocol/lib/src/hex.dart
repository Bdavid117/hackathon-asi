import 'dart:typed_data';

/// Bytes → hexadecimal en minúsculas.
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Hexadecimal → bytes. Lanza [FormatException] si la cadena no es hexadecimal válida.
Uint8List bytesFromHex(String hex) {
  if (hex.length.isOdd) throw FormatException('longitud hexadecimal impar', hex);
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) throw FormatException('carácter no hexadecimal', hex);
    out[i] = v;
  }
  return out;
}
