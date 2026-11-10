import 'dart:math';

import 'package:sard_protocol/sard_protocol.dart';

import 'geo.dart';
import 'text_sim.dart';

/// Lo que el agente 3 sabe de un reporte (ya fundidas sus revisiones).
class Observation {
  const Observation({
    required this.reportKey,
    required this.deviceId,
    required this.incidentType,
    required this.flags,
    required this.lat,
    required this.lon,
    required this.locQuality,
    required this.capturedAtMs,
    required this.text,
    required this.sourceClass,
  });

  final String reportKey;
  final String deviceId;
  final int incidentType;
  final int flags;
  final double? lat;
  final double? lon;
  final LocQuality locQuality;
  final int capturedAtMs;
  final String? text;

  /// `app` (teléfono) o `radio` (rumor de segunda mano): la credibilidad base depende de ella.
  final String sourceClass;

  /// Hay ubicación utilizable sólo si la calidad lleva coordenadas **y** las trae.
  bool get hasLocation => lat != null && lon != null && hasUsableCoordinates(locQuality);
  double? get sigma => hasLocation ? sigmaMeters(locQuality) : null;
}

/// ¿Alcanza [score] el umbral [threshold]? Con una tolerancia de 1e-9 para que un puntaje que cae
/// EXACTAMENTE en el umbral (p. ej. 0,85 = 0,40 + 0,15 + 0 + 0,30) no dependa del orden de las
/// sumas ni del redondeo de coma flotante.
bool meetsThreshold(double score, double threshold) => score + 1e-9 >= threshold;

/// Pesos y umbrales del PDF §6.6. Los umbrales se calibran con T07 priorizando no fusionar
/// casos distintos.
class Weights {
  const Weights({
    this.wd = 0.40,
    this.wt = 0.15,
    this.wk = 0.15,
    this.ws = 0.30,
    this.tau = const Duration(minutes: 30),
    this.thetaHi = 0.85,
    this.thetaLo = 0.55,
    this.thetaHiNoLoc = 0.90,
    this.textEvidenceTokens = 5,
  });

  final double wd, wt, wk, ws;
  final Duration tau;

  /// θhi **0,85**: el valor inicial del PDF era 0,80; se calibró con T07 (semillas 1–5, priorizando
  /// no fusionar casos distintos) porque a 0,80 la falsa fusión es inestable (0–1,6 % según la
  /// semilla y 3,8 % en calibración) y a 0,85 es 0 en las semillas nuevas. Es el que usa el nodo.
  final double thetaHi, thetaLo;

  /// Umbral de `same` cuando falta la ubicación en alguno: más estricto, porque sin ella el
  /// puntaje se apoya sólo en la hora, el tipo y el texto.
  /// Calibrado con T07 (valor inicial del PDF: 0,92); es el que usa el nodo.
  final double thetaHiNoLoc;

  /// Palabras compartidas necesarias para dar crédito completo a la similitud del texto.
  final int textEvidenceTokens;

  Weights copyWith({double? thetaHi, double? thetaHiNoLoc}) => Weights(
    wd: wd, wt: wt, wk: wk, ws: ws, tau: tau, thetaLo: thetaLo, textEvidenceTokens: textEvidenceTokens,
    thetaHi: thetaHi ?? this.thetaHi,
    thetaHiNoLoc: thetaHiNoLoc ?? this.thetaHiNoLoc,
  );
}

enum LinkState { same, possible, different }

class PairScore {
  const PairScore(this.score, this.state, this.uncertainty, this.terms);

  final double score;
  final LinkState state;

  /// Códigos de incertidumbre del par (`ubicacion_ausente`, `ubicacion_imprecisa`).
  final List<String> uncertainty;

  /// Cada término del puntaje por separado (`espacial`, `temporal`, `tipo`, `texto`), para poder
  /// explicar la decisión. Sin ubicación no hay `espacial`.
  final Map<String, double> terms;
}

/// Puntaje de que dos observaciones describan el mismo suceso:
/// `wd·K(d/(σ1+σ2)) + wt·e^(−Δt/τ) + wk·[mismo tipo] + ws·sim(texto)`, con `K(x) = máx(0, 1−x)`.
///
/// La distancia se mide relativa a la precisión declarada de cada reporte. Sin ubicación en
/// alguno, el término espacial no existe: se renormaliza sobre los demás y se usa el umbral más
/// estricto [Weights.thetaHiNoLoc]. Es **simétrica**.
PairScore scorePair(Observation a, Observation b, [Weights w = const Weights()]) {
  final dtMs = (a.capturedAtMs - b.capturedAtMs).abs();
  final temporal = exp(-dtMs / w.tau.inMilliseconds);
  final tipo = a.incidentType == b.incidentType ? 1.0 : 0.0;
  final texto = weightedTextSimilarity(a.text, b.text, evidenceTokens: w.textEvidenceTokens);
  final terms = <String, double>{'temporal': temporal, 'tipo': tipo, 'texto': texto};
  final uncertainty = <String>[];

  double score;
  double thetaHi;
  if (a.hasLocation && b.hasLocation) {
    final d = distanceMeters(a.lat!, a.lon!, b.lat!, b.lon!);
    final sigma = a.sigma! + b.sigma!;
    final espacial = max(0.0, 1 - d / sigma);
    terms['espacial'] = espacial;
    score = w.wd * espacial + w.wt * temporal + w.wk * tipo + w.ws * texto;
    thetaHi = w.thetaHi;
    if (a.sigma! >= 1000 || b.sigma! >= 1000) uncertainty.add('ubicacion_imprecisa');
  } else {
    score = (w.wt * temporal + w.wk * tipo + w.ws * texto) / (w.wt + w.wk + w.ws);
    thetaHi = w.thetaHiNoLoc;
    uncertainty.add('ubicacion_ausente');
  }
final state = meetsThreshold(score, thetaHi)
      ? LinkState.same
      : meetsThreshold(score, w.thetaLo)
      ? LinkState.possible
      : LinkState.different;
  return PairScore(score.clamp(0.0, 1.0), state, uncertainty, terms);
}
