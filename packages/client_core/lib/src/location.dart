import 'package:sard_protocol/sard_protocol.dart';

/// Una lectura de ubicación con su precisión horizontal.
class LocationFix {
  LocationFix({required this.lat, required this.lon, required this.accuracyMeters, required this.at}) {
    if (lat.isNaN || lon.isNaN || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      throw ArgumentError('coordenadas fuera de rango: $lat, $lon');
    }
  }

  final double lat;
  final double lon;

  /// Radio de incertidumbre horizontal en metros.
  final double accuracyMeters;

  /// Cuándo se tomó la lectura.
  final DateTime at;

  /// Antigüedad respecto a [now]; nunca negativa (un reloj atrasado cuenta como 0).
  Duration age(DateTime now) {
    final d = now.difference(at);
    return d.isNegative ? Duration.zero : d;
  }

  /// ¿Es lo bastante reciente para usarla sin esperar a una lectura nueva?
  bool isFresh(DateTime now, {Duration maxAge = const Duration(minutes: 2)}) => age(now) < maxAge;
}

/// De dónde sale la ubicación. La app real usa el GPS del dispositivo; las pruebas, un doble.
abstract interface class LocationProvider {
  /// La última posición conocida, al instante. `null` si no hay o no hay permiso.
  Future<LocationFix?> lastKnown();

  /// Una lectura nueva, con plazo. `null` si no llega a tiempo, está apagado o no hay permiso.
  Future<LocationFix?> fresh({Duration timeout = const Duration(seconds: 8)});
}

/// Calidad de la ubicación según la precisión horizontal (PDF §7.2).
LocQuality locQualityFromAccuracy(double meters) {
  if (meters.isNaN || meters.isInfinite || meters < 0) return LocQuality.none;
  if (meters <= 10) return LocQuality.within10m;
  if (meters <= 50) return LocQuality.within50m;
  if (meters <= 200) return LocQuality.within200m;
  if (meters <= 1000) return LocQuality.within1km;
  return LocQuality.over1km;
}
