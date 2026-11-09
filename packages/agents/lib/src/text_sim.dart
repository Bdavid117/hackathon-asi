/// Normaliza un texto para compararlo: minúsculas, sin tildes ni signos de puntuación.
///
/// **Conserva la longitud**: cada unidad UTF-16 del original produce exactamente una del resultado
/// (lo que no es letra ni cifra se vuelve un espacio). Así un índice en el texto normalizado es el
/// mismo índice en el original, y una cita sacada de aquel es subcadena exacta de éste.
String normalizeText(String s) {
  final b = StringBuffer();
  for (final u in s.codeUnits) {
    b.writeCharCode(_fold(u));
  }
  return b.toString();
}

int _fold(int u) {
  final lower = String.fromCharCode(u).toLowerCase();
  if (lower.length != 1) return 0x20; // casos raros de minúscula de varios caracteres
  final c = lower.codeUnitAt(0);
  switch (c) {
    case 0xE1: // á
    case 0xE0: // à
    case 0xE4: // ä
      return 0x61;
    case 0xE9: // é
    case 0xE8:
    case 0xEB:
      return 0x65;
    case 0xED: // í
    case 0xEC:
    case 0xEF:
      return 0x69;
    case 0xF3: // ó
    case 0xF2:
    case 0xF6:
      return 0x6F;
    case 0xFA: // ú
    case 0xF9:
    case 0xFC:
      return 0x75;
    case 0xF1: // ñ
      return 0x6E;
  }
  final isLetter = c >= 0x61 && c <= 0x7A;
  final isDigit = c >= 0x30 && c <= 0x39;
  return (isLetter || isDigit) ? c : 0x20;
}
