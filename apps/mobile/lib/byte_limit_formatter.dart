import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

/// Cuántos bytes ocupa [s] en UTF-8 (lo que viaja en la trama, no cuántas letras se ven).
int utf8Length(String s) => utf8.encode(s).length;

/// Filtro de entrada que **no deja escribir más de [maxBytes] bytes UTF-8**.
///
/// La trama admite una frase de hasta 140 bytes, y una «ñ», una vocal con tilde o un emoji pesan 2–4+:
/// limitar por letras dejaría pasar de más (y la trama fallaría al enviar) o recortaría de menos. Al
/// pasarse, se recorta **por grupos de letras completos** (clústeres de grafemas): un emoji o una
/// letra con su acento combinante entra entero o no entra, nunca partido a la mitad.
class Utf8ByteLimitFormatter extends TextInputFormatter {
  const Utf8ByteLimitFormatter(this.maxBytes);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (utf8Length(newValue.text) <= maxBytes) return newValue;
    var used = 0;
    final kept = StringBuffer();
    for (final g in newValue.text.characters) {
      final n = utf8Length(g);
      if (used + n > maxBytes) break;
      used += n;
      kept.write(g);
    }
    final text = kept.toString();
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
