// COBERTURA: dónde hubo reportes y dónde callaron. **La ausencia de reportes NO es seguridad**: una zona silenciosa puede estar bien, o
// sin teléfonos con batería, o sin señal; la capa sólo marca las celdas donde SÍ llegaron reportes con ubicación en la ventana de
// actividad y NINGUNO en la ventana reciente. Nada predice ni dice dónde «debería» haber reportes.
//
// Todo es propio del diseño (no del enunciado): la rejilla, las dos ventanas y el tope. Es una proyección pura de lo que el nodo ya
// tiene; se sirve aparte (`GET /api/coverage`) y no entra en la cola, la lista, el resumen ni la huella.
//
// Límites que se dicen: sólo cuenta la hora de PRIMERA recepción de cada reporte (una revisión posterior no se toma por actividad); si
// el reloj del nodo está atrasado todo parece reciente y la capa calla; los reportes sin ubicación utilizable no entran (se cuentan).

/// Lado de la celda en grados (≈ 550 m en Manizales).
const double kCoverageCellDeg = 0.005;

/// Ventana de actividad: sólo cuentan reportes recibidos en las últimas 6 h.
const Duration kCoverageActivityWindow = Duration(hours: 6);

/// Ventana de silencio: una celda con actividad pero sin ningún reporte en los últimos 30 min está en silencio.
const Duration kCoverageSilenceWindow = Duration(minutes: 30);

/// Tope de celdas que se devuelven (las de más peso primero).
const int kCoverageMaxCells = 400;

/// Lo mínimo de un reporte con ubicación utilizable (compacto: viaja entre isolates con la proyección).
class CoverageReport {
  const CoverageReport({required this.lat, required this.lon, required this.receivedAtMs, this.urgent = false});

  final double lat;
  final double lon;

  /// Hora de recepción del NODO (milisegundos), no la del teléfono: su reloj puede estar mal.
  final int receivedAtMs;

  /// El triaje por reglas lo puso en P1 o P2.
  final bool urgent;
}

class _Cell {
  _Cell(this.latIdx, this.lonIdx);
  final int latIdx, lonIdx;
  int total = 0, recent = 0, urgent = 0, lastAtMs = 0;
}

int _index(double degrees, double offset, double cell) => ((degrees + offset) / cell + 1e-9).floor();

/// Cuántas de las horas de recepción [atMs] caen en la ventana de actividad (para decir cuántos reportes sin ubicación no entran).
int countInWindow(Iterable<int> atMs, {required int nowMs, Duration activity = kCoverageActivityWindow}) =>
    atMs.where((t) => nowMs - t <= activity.inMilliseconds).length;

/// Las zonas en silencio a [nowMs]. Pura: no depende del orden de [reports] ni del reloj. Una recepción en el futuro (reloj del nodo
/// atrasado) cuenta como ahora. Devuelve sólo las celdas silenciosas (hasta [maxCells], las más urgentes y de más reportes primero) más
/// los totales reales.
Map<String, Object?> buildCoverage(
  List<CoverageReport> reports, {
  required int nowMs,
  int withoutLocation = 0,
  double cellDeg = kCoverageCellDeg,
  Duration activity = kCoverageActivityWindow,
  Duration silence = kCoverageSilenceWindow,
  int maxCells = kCoverageMaxCells,
}) {
  final cells = <(int, int), _Cell>{};
  var inWindow = 0;
  for (final r in reports) {
    if (!r.lat.isFinite || !r.lon.isFinite) continue;
    // Una recepción en el futuro (reloj del nodo atrasado) da una edad negativa: cuenta como ahora (activa y reciente) sin recortarla.
    final at = r.receivedAtMs;
    final age = nowMs - at;
    if (age > activity.inMilliseconds) continue;
    inWindow++;
    final key = (_index(r.lat, 90, cellDeg), _index(r.lon, 180, cellDeg));
    final c = cells.putIfAbsent(key, () => _Cell(key.$1, key.$2));
    c.total++;
    if (r.urgent) c.urgent++;
    if (age < silence.inMilliseconds) c.recent++;
    if (at > c.lastAtMs) c.lastAtMs = at;
  }
  final silent = [for (final c in cells.values) if (c.recent == 0) c]
    ..sort((a, b) {
      final u = b.urgent.compareTo(a.urgent);
      if (u != 0) return u;
      final t = b.total.compareTo(a.total);
      if (t != 0) return t;
      final l = b.lastAtMs.compareTo(a.lastAtMs);
      if (l != 0) return l;
      final la = a.latIdx.compareTo(b.latIdx);
      return la != 0 ? la : a.lonIdx.compareTo(b.lonIdx);
    });
  return {
    'nowMs': nowMs,
    'cellDeg': cellDeg,
    'activityMs': activity.inMilliseconds,
    'silenceMs': silence.inMilliseconds,
    'cells': [
      for (final c in silent.take(maxCells))
        {
          'id': '${c.latIdx}:${c.lonIdx}',
          'lat': (c.latIdx + 0.5) * cellDeg - 90,
          'lon': (c.lonIdx + 0.5) * cellDeg - 180,
          'total': c.total,
          'urgent': c.urgent,
          'lastAtMs': c.lastAtMs,
        },
    ],
    'silentTotal': silent.length,
    'activeCells': cells.length - silent.length,
    'reportsInWindow': inWindow,
    'withoutLocation': withoutLocation,
  };
}
