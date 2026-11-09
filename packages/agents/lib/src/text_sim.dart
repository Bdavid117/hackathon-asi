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

// ---------------------------------------------------------------------------------------------
// Similitud de textos (agente 3). Léxica y sin modelo: tokens de contenido con tolerancia a una
// falta de ortografía en las palabras largas.
// ---------------------------------------------------------------------------------------------

const Set<String> _stopwords = {
  'del', 'las', 'los', 'una', 'uno', 'unos', 'unas', 'que', 'por', 'con', 'para', 'sin', 'sus',
  'mis', 'nos', 'les', 'esta', 'este', 'estan', 'estoy', 'estamos', 'hay', 'pero', 'como', 'muy',
  'mas', 'todo', 'toda', 'todos', 'aqui', 'alli', 'ahi', 'ser', 'fue', 'son', 'han', 'ahora',
  // muletillas que se repiten en cualquier reporte y no distinguen un suceso de otro
  'favor', 'ayuda', 'urgente', 'ayudenme', 'necesitamos', 'vengan', 'porfavor',
};

/// Las palabras de contenido de [text]: normalizadas, sin palabras vacías ni muletillas, y sin
/// tokens de menos de 3 letras (salvo los números, que sirven para direcciones).
Set<String> contentTokens(String? text) {
  if (text == null) return const {};
  final out = <String>{};
  for (final t in normalizeText(text).split(' ')) {
    if (t.isEmpty || _stopwords.contains(t)) continue;
    final digits = t.codeUnits.every((c) => c >= 0x30 && c <= 0x39);
    if (t.length >= 3 || digits) out.add(t);
  }
  return out;
}

bool _tokensMatch(String a, String b) {
  if (a == b) return true;
  if (a.length < 5 || b.length < 5 || (a.length - b.length).abs() > 1) return false;
  return _editDistanceAtMostOne(a, b);
}

bool _editDistanceAtMostOne(String a, String b) {
  if (a.length == b.length) {
    var diff = -1;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == b[i]) continue;
      if (diff == -1) {
        diff = i;
        continue;
      }
      // dos diferencias: sólo vale si son una transposición de letras vecinas
      return i == diff + 1 && a[diff] == b[i] && a[i] == b[diff] && a.substring(i + 1) == b.substring(i + 1);
    }
    return true;
  }
  final (s, l) = a.length < b.length ? (a, b) : (b, a);
  var i = 0;
  while (i < s.length && s[i] == l[i]) {
    i++;
  }
  return s.substring(i) == l.substring(i + 1);
}

({int matched, int a, int b}) _match(String? a, String? b) {
  final ta = contentTokens(a).toList(), tb = contentTokens(b).toList();
  if (ta.isEmpty || tb.isEmpty) return (matched: 0, a: ta.length, b: tb.length);
  final used = List<bool>.filled(tb.length, false);
  var matched = 0;
  for (final x in ta) {
    for (var j = 0; j < tb.length; j++) {
      if (!used[j] && _tokensMatch(x, tb[j])) {
        used[j] = true;
        matched++;
        break;
      }
    }
  }
  return (matched: matched, a: ta.length, b: tb.length);
}

/// Parecido entre dos textos, de 0 a 1: palabras de contenido compartidas sobre palabras de
/// contenido totales (Jaccard), con tolerancia a una falta de ortografía. Si a uno le falta el
/// texto, **0**: no hay nada que comparar, y no se parecen por no tener nada que decir.
///
/// Es la similitud *cruda*: con una sola palabra de contenido en cada texto puede dar 1. Para
/// decidir si dos reportes son del mismo suceso se usa [weightedTextSimilarity].
double textSimilarity(String? a, String? b) {
  final m = _match(a, b);
  if (m.a == 0 || m.b == 0) return 0.0;
  return m.matched / (m.a + m.b - m.matched);
}

/// Similitud ponderada por la **masa de evidencia**: la similitud cruda multiplicada por
/// `mín(1, palabras compartidas / evidenceTokens)`. Una frase genérica de una o dos palabras
/// («hay un incendio», «varios heridos») la dicen personas distintas sobre sucesos distintos, así
/// que coincidir en ella casi no prueba nada; coincidir en cinco o más palabras sí.
double weightedTextSimilarity(String? a, String? b, {int evidenceTokens = 5}) {
  final m = _match(a, b);
  if (m.a == 0 || m.b == 0) return 0.0;
  final raw = m.matched / (m.a + m.b - m.matched);
  return raw * (m.matched >= evidenceTokens ? 1.0 : m.matched / evidenceTokens);
}
