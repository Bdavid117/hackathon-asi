import 'dart:math';

import 'package:sard_protocol/sard_protocol.dart';

/// Distancia (haversine) en metros entre dos puntos de la Tierra.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double x) => x * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

/// Incertidumbre (σ, en metros) que declara una calidad de ubicación; `null` si no hay ubicación.
///
/// Los valores son los de la calidad de la trama: ±10, ±50, ±200 m, ±1 km y «más de 1 km». Una
/// ubicación manual (texto) no tiene coordenadas fiables y cuenta como la peor.
/// Distancia en metros del punto P al SEGMENTO A–B (no a la recta infinita: más allá de un extremo cuenta la distancia a ese
/// extremo). Proyección equirectangular local alrededor de A: sobra para los pocos kilómetros de un trayecto.
double distanceToSegmentMeters(double pLat, double pLon, double aLat, double aLon, double bLat, double bLon) {
  const metersPerDegree = 111320.0;
  final cosLat = cos(aLat * pi / 180);
  double x(double lon) => (lon - aLon) * cosLat * metersPerDegree;
  double y(double lat) => (lat - aLat) * metersPerDegree;
  final bx = x(bLon), by = y(bLat), px = x(pLon), py = y(pLat);
  final len2 = bx * bx + by * by;
  final t = len2 == 0 ? 0.0 : ((px * bx + py * by) / len2).clamp(0.0, 1.0);
  final cx = t * bx, cy = t * by;
  return sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}

/// ¿Esta calidad de ubicación sirve para situar un reporte? Las de la trama (1–5) llevan coordenadas; una ubicación
/// «manual» —la que escribe una persona, p. ej. un despachador— las trae aparte, en el evento, aunque la TRAMA no las lleve
/// (por eso `LocQuality.hasCoordinates` del protocolo no cambia: el códec depende de él).
bool hasUsableCoordinates(LocQuality q) => q.hasCoordinates || q == LocQuality.manual;

double? sigmaMeters(LocQuality q) => switch (q) {
  LocQuality.none => null,
  LocQuality.within10m => 10,
  LocQuality.within50m => 50,
  LocQuality.within200m => 200,
  LocQuality.within1km => 1000,
  LocQuality.over1km => 3000,
  LocQuality.manual => 3000,
};
