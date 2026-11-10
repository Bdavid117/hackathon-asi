import 'package:sard_protocol/sard_protocol.dart';

import 'text_signals.dart';

// Contradicciones entre los reportes de un mismo incidente, DETERMINISTAS y sin modelo de lenguaje.
//
// Qué detecta (dos clases, y sólo esas):
//  · negación explícita: un reporte dice «sin heridos» y OTRO reporte afirma «herido» (por bandera o por texto);
//  · cantidad de personas incompatible: cajones que no son vecinos (1 frente a 6–20).
//
// Qué NO detecta: las contradicciones de sentido (que hacen falta modelo y juicio), ni un reporte que se contradice
// a sí mismo, ni nada que no sea una de esas dos clases. Que no salga ninguna NO significa que no las haya.
//
// Es una proyección pura de lo que ya dicen los reportes: no cambia la urgencia, no fusiona ni separa nada, y no
// resuelve la contradicción: la deja a la vista («contradicciones pendientes», ficha del agente 3) para que decida
// una persona. Una contradicción falsa cuesta tanto como una fusión falsa, por eso las reglas son estrechas.

/// Lo que de un reporte importa para buscar contradicciones.
class ReportFacts {
  const ReportFacts({required this.reportKey, this.flags = 0, this.people = 0, this.text});

  final String reportKey;

  /// Banderas de situación marcadas por quien reporta (`SituationFlags`).
  final int flags;

  /// Cajón de personas (`PeopleBucket.code`); 0 = no indicado.
  final int people;
  final String? text;
}

/// Un par de reportes que dicen cosas incompatibles.
class Contradiction {
  const Contradiction({required this.kind, required this.a, required this.b, this.code, this.aValue, this.bValue});

  /// `negacion` o `personas`.
  final String kind;

  /// En `negacion`, la señal negada por [a] y afirmada por [b] (`herido`…).
  final String? code;

  /// Los dos reportes; en `negacion`, [a] es quien niega y [b] quien afirma; en `personas`, [a] es el de la cifra menor.
  final String a;
  final String b;

  /// En `personas`, lo que dice cada uno (la etiqueta del cajón).
  final String? aValue;
  final String? bValue;

  Map<String, Object?> toJson() => {'kind': kind, 'code': ?code, 'a': a, 'b': b, 'aValue': ?aValue, 'bValue': ?bValue};
}

/// Señal del léxico → bandera que la afirma.
const Map<String, int> _bitOfSignal = {
  'atrapado': SituationFlags.atrapado,
  'herido': SituationFlags.herido,
  'incendio': SituationFlags.incendio,
  'dificultad_respiratoria': SituationFlags.dificultadRespiratoria,
  'via_bloqueada': SituationFlags.viaBloqueada,
  'estructura_inestable': SituationFlags.estructuraInestable,
  'menores_mayores': SituationFlags.menoresMayores,
  'medicacion': SituationFlags.medicacion,
};

/// Cuántos cajones de personas tienen que separar a dos reportes para que sea una contradicción (los vecinos no lo son).
const int kPeopleGap = 2;

/// Busca las contradicciones entre [reports] (los de un mismo incidente). Como mucho una por señal y una de personas;
/// el resultado no depende del orden de entrada.
List<Contradiction> detectContradictions(List<ReportFacts> reports) {
  final negators = <String, List<String>>{};
  final asserters = <String, List<String>>{};
  for (final rep in reports) {
    final text = rep.text;
    final analysis = text == null || text.trim().isEmpty ? const TextAnalysis([], {}) : analyzeText(text);
    for (final code in analysis.negated) {
      (negators[code] ??= []).add(rep.reportKey);
    }
    final asserted = <String>{
      for (final s in analysis.signals) s.code,
      for (final e in _bitOfSignal.entries)
        if (rep.flags & e.value != 0) e.key,
    };
    for (final code in asserted) {
      (asserters[code] ??= []).add(rep.reportKey);
    }
  }

  final out = <Contradiction>[];
  for (final code in _bitOfSignal.keys) {
    final n = negators[code], a = asserters[code];
    if (n == null || a == null) continue;
    n.sort();
    a.sort();
    // El primer par de reportes DISTINTOS (un reporte que se niega a sí mismo no cuenta).
    String? neg, asr;
    for (final ni in n) {
      final other = a.firstWhere((k) => k != ni, orElse: () => '');
      if (other.isNotEmpty) {
        neg = ni;
        asr = other;
        break;
      }
    }
    if (neg != null && asr != null) out.add(Contradiction(kind: 'negacion', code: code, a: neg, b: asr));
  }

  // Personas: se comparan los extremos; cuando empatan, manda la clave más pequeña (el orden de entrada no importa).
  ReportFacts? low, high;
  for (final rep in reports) {
    if (rep.people == 0) continue;
    if (low == null || rep.people < low.people || (rep.people == low.people && rep.reportKey.compareTo(low.reportKey) < 0)) low = rep;
    if (high == null || rep.people > high.people || (rep.people == high.people && rep.reportKey.compareTo(high.reportKey) < 0)) high = rep;
  }
  if (low != null && high != null && high.people - low.people >= kPeopleGap) {
    out.add(Contradiction(kind: 'personas', a: low.reportKey, b: high.reportKey, aValue: PeopleBucket.fromCode(low.people).label, bValue: PeopleBucket.fromCode(high.people).label));
  }
  return out;
}
