// T20 · Estudio de la capa «Silencio»: ¿cuántas zonas marcadas en silencio son de verdad un apagón? (parte PURA: generador y métricas).
//
// Un modelo deliberadamente SENCILLO y escrito aparte del detector: cada zona reporta como un proceso de Poisson de tasa λ (reportes por hora);
// una parte de las zonas sufre un APAGÓN en un instante dado tras el cual su tasa cae al 5 % (el enunciado habla de «el 95 % de los teléfonos
// apagados»; el 5 % restante todavía puede reportar). Lo que se mide es lo que el detector real (`buildCoverage`) marca frente a esa verdad.
// La verdad NO usa las ventanas del detector (6 h, 30 min): se define por el apagón. Por eso la medición puede salir mal, y se informa así.
import 'dart:math';

import 'package:sard_node/sard_node.dart';

/// Minutos que dura el estudio (la ventana de actividad del detector es de 6 h).
const int kStudyMinutes = 360;

class StudyZone {
  StudyZone({required this.index, required this.rate, required this.blackoutAtMinute, required this.reportMinutes});

  final int index;

  /// Reportes por hora ANTES del apagón.
  final double rate;

  /// Minuto del estudio en que se apaga la zona; `null` = no se apaga.
  final int? blackoutAtMinute;

  /// Minutos (desde el inicio del estudio) en que llegó cada reporte.
  final List<int> reportMinutes;

  bool get blackout => blackoutAtMinute != null;

  /// Cuánto lleva apagada al final del estudio (minutos), o `null`.
  int? get darkForMinutes => blackoutAtMinute == null ? null : kStudyMinutes - blackoutAtMinute!;

  /// Llegó algún reporte en las seis horas: sólo entonces el detector puede verla.
  bool get visible => reportMinutes.isNotEmpty;
}

/// [zones] zonas con tasas log-uniformes entre [minRate] y [maxRate] reportes/hora; una fracción [blackoutShare] se apaga en un minuto
/// uniforme de [minDarkMinutes, kStudyMinutes - 1]. Tras el apagón la tasa es [residual] × λ.
List<StudyZone> generateStudyZones(Random rnd, {int zones = 60, double blackoutShare = 0.3, double residual = 0.05, double minRate = 0.3, double maxRate = 12, int minDarkMinutes = 5}) {
  final out = <StudyZone>[];
  for (var i = 0; i < zones; i++) {
    final rate = minRate * pow(maxRate / minRate, rnd.nextDouble());
    final dark = rnd.nextDouble() < blackoutShare;
    final blackoutAt = dark ? minDarkMinutes + rnd.nextInt(kStudyMinutes - 2 * minDarkMinutes) : null;
    final minutes = <int>[];
    // Por TRAMOS: antes del apagón con la tasa λ y después con residual × λ. Si se sorteara de corrido, el primer reporte tras el apagón se
    // sortearía con la tasa vieja (una versión anterior de este generador sesgaba así: 0,9 reportes/h medidos donde debía haber 0,6).
    void segment(double from, double to, double perHour) {
      var t = from;
      while (true) {
        t += -log(1 - rnd.nextDouble()) / (perHour / 60);
        if (t >= to) break;
        minutes.add(t.floor());
      }
    }

    if (blackoutAt == null) {
      segment(0, kStudyMinutes.toDouble(), rate);
    } else {
      segment(0, blackoutAt.toDouble(), rate);
      segment(blackoutAt.toDouble(), kStudyMinutes.toDouble(), rate * residual);
    }
    out.add(StudyZone(index: i, rate: rate, blackoutAtMinute: blackoutAt, reportMinutes: minutes));
  }
  return out;
}

/// Lo que el detector REAL marca como zona en silencio al final del estudio, con una ventana de silencio [silenceMinutes]. Devuelve los índices.
Set<int> markedSilent(List<StudyZone> zones, {int silenceMinutes = 30}) {
  const nowMs = 1800000000000;
  const baseLat = 5.0, baseLon = -75.5, step = 0.01; // una celda por zona (la celda mide 0,005°)
  double latOf(int i) => baseLat + i * step;
  final reports = <CoverageReport>[
    for (final z in zones)
      for (final m in z.reportMinutes) CoverageReport(lat: latOf(z.index), lon: baseLon, receivedAtMs: nowMs - (kStudyMinutes - m) * 60 * 1000),
  ];
  final c = buildCoverage(reports, nowMs: nowMs, silence: Duration(minutes: silenceMinutes), maxCells: 1 << 20);
  final marked = <int>{};
  for (final cell in (c['cells']! as List).cast<Map<String, Object?>>()) {
    final lat = cell['lat']! as double;
    marked.add(((lat - baseLat) / step).round());
  }
  return marked;
}

/// Una matriz de confusión sobre las zonas VISIBLES (con algún reporte en las seis horas); las invisibles se cuentan aparte.
class Confusion {
  int tp = 0, fp = 0, fn = 0, tn = 0, invisibleBlackout = 0, invisibleNormal = 0;

  int get marked => tp + fp;
  int get blackouts => tp + fn;

  /// De las zonas marcadas, cuántas eran un apagón (`null` si no se marcó ninguna).
  double? get precision => marked == 0 ? null : tp / marked;

  /// De los apagones visibles, cuántos se marcaron (`null` si no había ninguno).
  double? get recall => blackouts == 0 ? null : tp / blackouts;

  void add(StudyZone z, bool isMarked) {
    if (!z.visible) {
      z.blackout ? invisibleBlackout++ : invisibleNormal++;
      return;
    }
    switch ((z.blackout, isMarked)) {
      case (true, true):
        tp++;
      case (true, false):
        fn++;
      case (false, true):
        fp++;
      case (false, false):
        tn++;
    }
  }
}

Confusion confusionOf(Iterable<StudyZone> zones, Set<int> marked) {
  final c = Confusion();
  for (final z in zones) {
    c.add(z, marked.contains(z.index));
  }
  return c;
}
