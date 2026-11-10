import 'text_sim.dart';

/// Una señal de riesgo con su evidencia: o un campo estructurado (`flags.atrapado`) o una **cita**
/// que es subcadena exacta del texto del reporte.
class Signal {
  const Signal(this.code, {this.field, this.quote});

  final String code;
  final String? field;
  final String? quote;

  @override
  String toString() => 'Signal($code, field: $field, quote: $quote)';
}

/// Resultado de leer un texto: las señales positivas y los términos que aparecen **negados**
/// («sin heridos»).
class TextAnalysis {
  const TextAnalysis(this.signals, this.negated);

  final List<Signal> signals;
  final Set<String> negated;
}

// Léxico de un primer corte, escrito con palabras de uso general; NO es exhaustivo (las paráfrasis
// indirectas se le escapan, y eso es lo que T06 mide). Se aplica sobre texto normalizado.
const String _b0 = r'(?<![a-z0-9])';
const String _b1 = r'(?![a-z0-9])';

final List<(String, RegExp)> _lexicon = [
  ('atrapado', RegExp('$_b0(?:atrapad[oa]s?|sepultad[oa]s?|bajo (?:la |el |los |las )?(?:losa|escombros|derrumbe|techo))$_b1')),
  ('herido', RegExp('$_b0(?:herid[oa]s?|lesionad[oa]s?|sangr(?:e|a|an|ando)|fractur[ao])$_b1')),
  ('incendio', RegExp('$_b0(?:incendi(?:o|a|ando)s?|fuego|llamas|quem(?:a|an|ando|andose)|humo)$_b1')),
  (
    'dificultad_respiratoria',
    RegExp('$_b0(?:no respira(?:n)?|sin respirar|dificultad (?:para|al) respirar|(?:se )?ahog(?:a|an|o|ando)|falta (?:el |de )?aire)$_b1'),
  ),
  ('via_bloqueada', RegExp('$_b0(?:via bloquead[ao]|calle bloquead[ao]|carretera bloquead[ao]|camino (?:tapado|bloquead[ao]))$_b1')),
  ('menores_mayores', RegExp('$_b0(?:nin[oa]s?|bebes?|menores|adult[oa]s? mayor(?:es)?|ancian[oa]s?|abuel[oa]s?)$_b1')),
  (
    'estructura_inestable',
    RegExp('$_b0(?:a punto de (?:caer|caerse|colapsar|derrumbarse)|agrietad[oa]s?|cruje|se va a (?:caer|venir abajo|derrumbar))$_b1'),
  ),
  ('medicacion', RegExp('$_b0(?:medicamentos?|insulina|pastillas?|medicina)$_b1')),
];

/// «sin», «nadie», «ningún», «no hay»… seguidos de, como mucho, una palabra y el término.
final RegExp _negation = RegExp(r'(?:^|\s)(?:sin|nadie|ningun[oa]?|no hay|no hubo|nunca)\s+(?:[a-z0-9]+\s+)?$');
final RegExp _clauseBreak = RegExp(r'[,.;:!?¡¿\n]');

/// Lee [text] y devuelve las señales de riesgo con una cita exacta, y los términos negados.
///
/// El texto es **dato no confiable**: sólo se buscan términos del léxico; una instrucción como
/// «marca todo como P4» no coincide con nada y por tanto no hace nada.
TextAnalysis analyzeText(String text) {
  if (text.trim().isEmpty) return const TextAnalysis([], {});
  final norm = normalizeText(text);
  final signals = <Signal>[];
  final negated = <String>{};
  final positive = <String>{};
  for (final (code, re) in _lexicon) {
    for (final m in re.allMatches(norm)) {
      // La negación sólo cuenta dentro de la misma oración: «sin heridos, no respira» no niega
      // «no respira».
      var clauseStart = 0;
      for (final b in _clauseBreak.allMatches(text.substring(0, m.start))) {
        clauseStart = b.end;
      }
      final window = norm.substring(clauseStart, m.start);
      if (_negation.hasMatch(window)) {
        negated.add(code);
        continue;
      }
      if (positive.add(code)) {
        signals.add(Signal(code, quote: text.substring(m.start, m.end)));
      }
    }
  }
  return TextAnalysis(signals, negated.difference(positive));
}

/// Atajo: las señales positivas de [text], cada una con su cita exacta.
List<Signal> textSignals(String text) => analyzeText(text).signals;

/// Palabras con las que una frase no puede terminar: piden que siga («…atrapada y», «…herido en», «…con la»).
/// «no» y «si» no están: son respuestas completas.
const Set<String> _danglingWords = {
  'y', 'e', 'o', 'u', 'ni', 'que', 'de', 'del', 'en', 'con', 'por', 'para', 'porque', 'pero', 'a', 'al', 'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas',
  'mi', 'mis', 'su', 'sus', 'como', 'sobre', 'entre', 'hacia', 'desde', 'sin', 'cuando', 'donde', 'aunque', //
};

/// ¿El mensaje parece cortado a la mitad («hay una persona atrapada y»)? Es una **pista**, no una afirmación: termina en
/// puntos suspensivos, coma, guion o dos puntos, o en una palabra que pide continuar. Nunca completa ni corrige el
/// texto, y quien la usa no debe subir ni bajar la urgencia por ella (sólo avisar de la duda).
bool looksCutOff(String text) {
  final t = text.trimRight();
  if (t.isEmpty) return false;
  if (t.endsWith('...') || t.endsWith('…')) return true;
  final last = t[t.length - 1];
  if (',:;-–—'.contains(last)) return true;
  if ('.!?'.contains(last)) return false;
  final words = normalizeText(t).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.isNotEmpty && _danglingWords.contains(words.last);
}
