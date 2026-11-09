import 'dart:convert';

import 'package:sard_protocol/sard_protocol.dart';

import 'text_signals.dart';

enum Urgency { p1, p2, p3, p4 }

/// Resultado del triaje (agente 2).
class TriageResult {
  const TriageResult({
    required this.urgency,
    required this.signals,
    this.mode = 'rules',
    this.evidence = const [],
    this.confidence = 0.5,
    this.uncertainty = const [],
    this.escalateToHuman = false,
  });

  final Urgency urgency;

  /// Códigos de las señales activas (banderas y texto), sin repetir.
  final List<String> signals;

  /// `rules` (reglas) o `rules+llm` (reglas y modelo).
  final String mode;

  /// La evidencia de cada señal: campo estructurado o cita exacta del texto.
  final List<Signal> evidence;

  /// 0–1; informativa, no decide nada. Sube con evidencia que concuerda.
  final double confidence;

  /// Códigos de incertidumbre (`sin_detalle`, `texto_no_interpretado`, `ubicacion_ausente`,
  /// `texto_truncado`…).
  final List<String> uncertainty;

  /// «Ante la duda sube a revisión»: pide ojos humanos.
  final bool escalateToHuman;
}

const List<(int, String)> _signalCodes = [
  (SituationFlags.atrapado, 'atrapado'),
  (SituationFlags.herido, 'herido'),
  (SituationFlags.incendio, 'incendio'),
  (SituationFlags.dificultadRespiratoria, 'dificultad_respiratoria'),
  (SituationFlags.viaBloqueada, 'via_bloqueada'),
  (SituationFlags.estructuraInestable, 'estructura_inestable'),
  (SituationFlags.menoresMayores, 'menores_mayores'),
  (SituationFlags.medicacion, 'medicacion'),
];

/// Triaje por reglas deterministas. La tabla de prioridad vive en `prioHintFromFlags`.
///
/// Las banderas y las señales del texto se **suman** (OR): el texto puede subir la urgencia pero
/// nunca bajarla, y el piso por reglas (atrapado, dificultad respiratoria, incendio ⇒ ≥ P2) se
/// cumple con cualquier texto. El texto es dato no confiable: sólo cuentan los términos del léxico,
/// cada uno con una cita que es subcadena exacta del original.
///
/// Sin datos no se baja la urgencia: un SOS sin banderas ni texto, o con un texto que no se
/// entiende, queda en P3 con `escalateToHuman`. La única excepción es un texto que niega
/// explícitamente el peligro («sin heridos») sin ninguna señal positiva: P4, informativo.
TriageResult triage(int flags, {String? text, bool hasLocation = true}) {
  final hasText = text != null && text.trim().isNotEmpty;
  final analysis = hasText ? analyzeText(text) : const TextAnalysis([], {});

  var textFlags = 0;
  for (final s in analysis.signals) {
    for (final (bit, code) in _signalCodes) {
      if (code == s.code) textFlags |= bit;
    }
  }
  final effective = flags | textFlags;
  final codes = <String>[];
  final evidence = <Signal>[];
  for (final (bit, code) in _signalCodes) {
    if (effective & bit == 0) continue;
    codes.add(code);
    if (flags & bit != 0) evidence.add(Signal(code, field: 'flags.$code'));
    if (textFlags & bit != 0) {
      evidence.add(analysis.signals.firstWhere((s) => s.code == code));
    }
  }

  var urgency = Urgency.values[prioHintFromFlags(effective)];
  final uncertainty = <String>[];
  var escalate = false;
  var confidence = 0.5;
  if (effective == 0) {
    if (hasText && analysis.negated.isNotEmpty) {
      urgency = Urgency.p4; // dice expresamente que no hay peligro
      confidence = 0.6;
    } else if (hasText) {
      uncertainty.add('texto_no_interpretado');
      escalate = true;
      confidence = 0.35;
    } else {
      uncertainty.add('sin_detalle');
      escalate = true;
      confidence = 0.3;
    }
  } else {
    if (flags != 0) confidence += 0.2;
    if (textFlags != 0) confidence += 0.15;
    if (flags & textFlags != 0) confidence += 0.1;
  }
  if (!hasLocation) {
    uncertainty.add('ubicacion_ausente');
    confidence -= 0.05;
  }
  if (hasText && utf8.encode(text).length >= kMaxTextBytes - 2) uncertainty.add('texto_truncado');

  return TriageResult(
    urgency: urgency,
    signals: codes,
    evidence: evidence,
    confidence: confidence.clamp(0.05, 0.95),
    uncertainty: uncertainty,
    escalateToHuman: escalate,
  );
}
