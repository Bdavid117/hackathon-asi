import 'dart:math' as math;

// La geometría del mapa del tablero, sin Flutter: se prueba aparte y no depende de cómo se dibuje.
//
// Tres reglas que el mapa no puede romper (cada una tiene su prueba):
//  1. La escala es la misma al norte que al este (un mapa que estira miente sobre las distancias).
//  2. El encuadre NO se mueve solo: el tablero consulta cada 2 s y, si los límites se recalcularan con
//     cada incidente nuevo, todos los marcadores se moverían bajo el dedo de quien está eligiendo.
//  3. Ningún incidente queda tapado por otro: los que caen en el mismo sitio forman UN grupo con su
//     conteo, el más urgente encima, y nada se desplaza para «separarlos» (eso inventaría posiciones).

/// Un punto geográfico (grados).
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  @override
  bool operator ==(Object other) => other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoPoint($lat, $lon)';
}

/// Una posición en el lienzo, en píxeles (x a la derecha, y hacia abajo).
class Px {
  const Px(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(Px o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
}

const double _metersPerDegreeLat = 111320.0;

/// El rectángulo geográfico que el mapa tiene a la vista. Es inmutable: lo que llega después no lo cambia.
class MapFrame {
  const MapFrame({required this.south, required this.north, required this.west, required this.east});

  final double south;
  final double north;
  final double west;
  final double east;

  /// Ajusta el encuadre a [points] con un [margin] (fracción del span a cada lado) y sin acercarse más
  /// allá de [minSpanMeters]: con un solo incidente no se amplía hasta el absurdo. Nulo si no hay puntos.
  static MapFrame? aroundOrNull(Iterable<GeoPoint> points, {double minSpanMeters = 1000, double margin = 0.15}) {
    var minLat = double.infinity, maxLat = -double.infinity, minLon = double.infinity, maxLon = -double.infinity;
    var any = false;
    for (final p in points) {
      any = true;
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    if (!any) return null;
    final cLat = (minLat + maxLat) / 2, cLon = (minLon + maxLon) / 2;
    final cosLat = math.cos(cLat * math.pi / 180);
    final spanLat = math.max(maxLat - minLat, minSpanMeters / _metersPerDegreeLat);
    final spanLon = math.max(maxLon - minLon, minSpanMeters / (_metersPerDegreeLat * cosLat));
    final padLat = spanLat * margin, padLon = spanLon * margin;
    return MapFrame(south: cLat - spanLat / 2 - padLat, north: cLat + spanLat / 2 + padLat, west: cLon - spanLon / 2 - padLon, east: cLon + spanLon / 2 + padLon);
  }

  GeoPoint get center => GeoPoint((south + north) / 2, (west + east) / 2);

  bool contains(GeoPoint p) => p.lat >= south && p.lat <= north && p.lon >= west && p.lon <= east;

  /// Dónde cae [p] en un lienzo de [width] × [height]: proyección equirectangular local (la escala es la misma
  /// en los dos ejes, corrigiendo la longitud por el coseno de la latitud), con todo el encuadre a la vista y centrado.
  Px project(GeoPoint p, {required double width, required double height}) {
    final c = center;
    final cosLat = _cosOfCenter;
    final scale = _pixelsPerDegree(width, height);
    return Px(width / 2 + (p.lon - c.lon) * cosLat * scale, height / 2 - (p.lat - c.lat) * scale);
  }

  /// Cuántos píxeles miden [meters] metros en un lienzo de [width] × [height] (la escala es la misma en los dos ejes).
  double metersToPixels(double meters, {required double width, required double height}) =>
      meters / _metersPerDegreeLat * _pixelsPerDegree(width, height);

  double get _cosOfCenter => math.cos(center.lat * math.pi / 180);

  /// Píxeles por grado de latitud: el que hace caber TODO el encuadre en el lienzo.
  double _pixelsPerDegree(double width, double height) => math.min(width / ((east - west) * _cosOfCenter), height / (north - south));
}

/// La cifra redonda (1, 2, 5 × 10ⁿ metros) más grande cuya longitud no pase de [maxPx] píxeles: para la barra de escala.
double niceScaleMeters(double pixelsPerMeter, {double maxPx = 140}) {
  var best = 1.0;
  for (var e = 0; e <= 8; e++) {
    for (final m in const [1, 2, 5]) {
      final v = m * math.pow(10, e).toDouble();
      if (v * pixelsPerMeter <= maxPx + 1e-9) best = v;
    }
  }
  return best;
}

// ───────────────────────────── marcadores ─────────────────────────────

int _rank(String urgency) => switch (urgency) {
  'P1' => 0,
  'P2' => 1,
  'P3' => 2,
  _ => 3,
};

/// Un incidente ya proyectado al lienzo.
class MapMarker {
  const MapMarker({required this.id, required this.urgency, required this.at});

  final String id;
  final String urgency;
  final Px at;
}

/// Uno o varios incidentes que caen casi en el mismo punto. Se dibuja donde está el más urgente.
class MarkerCluster {
  MarkerCluster._(this.members);

  /// El más urgente primero (a igual urgencia, por identificador: el orden no depende de cómo llegaron).
  final List<MapMarker> members;

  MapMarker get top => members.first;
  Px get at => top.at;
  String get urgency => top.urgency;
  int get count => members.length;
}

/// Agrupa los marcadores que quedan a menos de [radiusPx] del más urgente de un grupo. Determinista (no
/// depende del orden de entrada), no pierde ninguno y no mueve ninguna posición.
List<MarkerCluster> clusterMarkers(List<MapMarker> markers, {double radiusPx = 14}) {
  final sorted = [...markers]..sort((a, b) {
    final r = _rank(a.urgency).compareTo(_rank(b.urgency));
    return r != 0 ? r : a.id.compareTo(b.id);
  });
  final groups = <List<MapMarker>>[];
  for (final m in sorted) {
    List<MapMarker>? home;
    var best = double.infinity;
    for (final g in groups) {
      final d = g.first.at.distanceTo(m.at);
      if (d <= radiusPx && d < best) {
        best = d;
        home = g;
      }
    }
    if (home != null) {
      home.add(m);
    } else {
      groups.add([m]);
    }
  }
  return [for (final g in groups) MarkerCluster._(g)];
}
