import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_mobile/byte_limit_formatter.dart';

TextEditingValue v(String s, {int? at}) => TextEditingValue(text: s, selection: TextSelection.collapsed(offset: at ?? s.length));

void main() {
  const f = Utf8ByteLimitFormatter(140);
  TextEditingValue apply(String before, String after) => f.formatEditUpdate(v(before), v(after));

  test('lo que cabe pasa tal cual (y conserva la selección)', () {
    final out = apply('hola', 'hola mundo');
    expect(out.text, 'hola mundo');
    expect(out.selection.baseOffset, 10);
  });

  test('140 bytes exactos pasan; 141 se recortan', () {
    expect(apply('', 'a' * 140).text, 'a' * 140);
    expect(apply('', 'a' * 141).text, 'a' * 140);
  });

  test('la «ñ» y las vocales con tilde pesan 2 bytes: caben 70, no 140', () {
    final out = apply('', 'ñ' * 100);
    expect(out.text, 'ñ' * 70);
    expect(utf8.encode(out.text).length, 140);
  });

  test('un emoji (4 bytes) que no cabe entero se descarta ENTERO, no se parte', () {
    final out = apply('', '${'a' * 138}🔥');
    expect(out.text, 'a' * 138);
    expect(out.text.contains('�'), isFalse);
  });

  test('un emoji compuesto (varios puntos de código unidos) no se corta por la mitad', () {
    const family = '👨‍👩‍👧'; // hombre + ZWJ + mujer + ZWJ + niña = 18 bytes
    expect(utf8.encode(family).length, 18);
    final out = apply('', '${'a' * 125}$family'); // 125 + 18 = 143 > 140
    expect(out.text, 'a' * 125, reason: 'o entra el emoji completo o no entra');
    final fits = apply('', '${'a' * 122}$family'); // 140 exactos
    expect(fits.text, '${'a' * 122}$family');
  });

  test('una letra con tilde escrita como base + marca combinante no pierde su marca al recortar', () {
    const e = 'é'; // «é» descompuesta: 3 bytes
    final out = apply('', '${'a' * 138}$e');
    expect(out.text, 'a' * 138, reason: 'o entra la letra con su acento o no entra');
  });

  test('pegar un texto enorme lo recorta al máximo que cabe', () {
    final out = apply('', 'palabra ' * 100);
    expect(utf8.encode(out.text).length, lessThanOrEqualTo(140));
    expect(utf8.encode(out.text).length, greaterThan(132), reason: 'aprovecha lo que cabe');
  });

  test('tras recortar el cursor queda al final del texto y sin zona de composición', () {
    final out = f.formatEditUpdate(v('a' * 140), TextEditingValue(text: '${'a' * 140}bcd', selection: const TextSelection.collapsed(offset: 143), composing: const TextRange(start: 140, end: 143)));
    expect(out.text, 'a' * 140);
    expect(out.selection, const TextSelection.collapsed(offset: 140));
    expect(out.composing, TextRange.empty);
  });

  test('el borrado siempre se permite, incluso si el texto previo ya estuviera pasado', () {
    expect(apply('a' * 150, 'a' * 149).text.length, lessThanOrEqualTo(149));
  });

  test('se puede editar en medio: insertar de más en medio recorta el sobrante del final del texto resultante', () {
    final before = 'a' * 139;
    final out = f.formatEditUpdate(v(before), TextEditingValue(text: '${'a' * 70}ZZZZ${'a' * 69}', selection: const TextSelection.collapsed(offset: 74)));
    expect(utf8.encode(out.text).length, lessThanOrEqualTo(140));
  });

  test('utf8Length cuenta bytes, no letras', () {
    expect(utf8Length('añ🔥'), 1 + 2 + 4);
    expect(utf8Length(''), 0);
  });
}
