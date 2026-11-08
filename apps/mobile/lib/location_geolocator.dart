import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:sard_client_core/sard_client_core.dart';

/// Ubicación del dispositivo con `geolocator`.
///
/// **No pide permisos**: durante un SOS no hay tiempo para diálogos. El permiso se pide una
/// vez al primer arranque ([requestPermissionOnce]); si falta o el GPS está apagado, devuelve
/// `null` y el reporte sale sin ubicación (la app nunca la inventa).
class GeolocatorLocationProvider implements LocationProvider {
  /// Pide el permiso de ubicación «mientras se usa» si todavía no se ha decidido.
  static Future<void> requestPermissionOnce() async {
    try {
      if (await Geolocator.checkPermission() == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
    } on Object {
      // sin plugin o sin servicio: la app funciona igual, sin ubicación
    }
  }

  Future<bool> _ready() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.whileInUse || p == LocationPermission.always;
  }

  LocationFix _fix(Position p) => LocationFix(
    lat: p.latitude,
    lon: p.longitude,
    accuracyMeters: p.accuracy,
    at: p.timestamp,
  );

  @override
  Future<LocationFix?> lastKnown() async {
    try {
      if (!await _ready()) return null;
      final p = await Geolocator.getLastKnownPosition();
      return p == null ? null : _fix(p);
    } on Object {
      return null;
    }
  }

  @override
  Future<LocationFix?> fresh({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      if (!await _ready()) return null;
      final p = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      ).timeout(timeout + const Duration(seconds: 2));
      return _fix(p);
    } on Object {
      return null; // sin fix a tiempo, GPS apagado o sin permiso
    }
  }
}
