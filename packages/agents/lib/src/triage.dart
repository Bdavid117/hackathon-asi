import 'package:sard_protocol/sard_protocol.dart';

enum Urgency { p1, p2, p3, p4 }

/// Resultado del triaje. En B1 sólo hay modo `rules`.
class TriageResult {
  const TriageResult({required this.urgency, required this.signals, this.mode = 'rules'});

  final Urgency urgency;

  /// Códigos de las banderas de situación activas.
  final List<String> signals;
  final String mode;
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
/// [text] se acepta por compatibilidad con el triaje con modelo (B3): en B1 el texto libre
/// es dato no confiable y no influye en la urgencia.
TriageResult triage(int flags, {String? text}) => TriageResult(
      urgency: Urgency.values[prioHintFromFlags(flags)],
      signals: [for (final (bit, code) in _signalCodes) if (flags & bit != 0) code],
    );
