import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Longitud de la etiqueta de integridad en bytes.
const int kTagLength = 4;

/// HMAC-SHA256 truncado a [kTagLength] bytes.
Uint8List computeTag(Uint8List key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes.sublist(0, kTagLength));

/// Comparación en tiempo constante.
bool tagsEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
