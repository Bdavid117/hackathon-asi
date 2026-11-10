// Escenario de EXPOSICIÓN: datos SINTÉTICOS (no son reportes de nadie) para enseñar el tablero con historia, no vacío. Seis zonas de Manizales
// y seis horas: unas siguen reportando y otras CALLARON (el caso del «silencio digital»), incluida una que sólo mandó un mensaje suelto y otra
// que tuvo un urgente antes de callar. Es puro y reproducible (misma semilla ⇒ misma historia): `seed_expo.dart` lo escribe en un nodo con
// horas pasadas, y las pruebas fijan qué zonas debe marcar el detector.
//
// Cada zona se centra en el centro de una celda de la rejilla del nodo y sus reportes se reparten dentro de ella: «una zona» y «una celda»
// son lo mismo, y el número de zonas en silencio que se promete en el guion es el que el detector marca.
import 'dart:math';

import 'package:sard_protocol/sard_protocol.dart';

/// Ventana de la historia: seis horas.
const int kExpoWindowMinutes = 360;

/// Una zona del escenario. Sus coordenadas son las del centro de su celda (la más cercana al lugar real).
class ExpoZone {
  const ExpoZone(this.name, this.lat, this.lon, {required this.count, this.silentSinceMinutes, this.lastMinutesAgo = 0});

  final String name;
  final double lat;
  final double lon;

  /// Cuántos reportes tuvo en las seis horas.
  final int count;

  /// Hace cuántos minutos dejó de reportar; `null` = sigue reportando.
  final int? silentSinceMinutes;

  /// Para las que siguen reportando: hace cuántos minutos llegó el último.
  final int lastMinutesAgo;

  /// El identificador de su celda, el mismo que calcula el nodo.
  String get cellId => '${_index(lat, 90)}:${_index(lon, 180)}';
}

const double _cell = 0.005;
int _index(double degrees, double offset) => ((degrees + offset) / _cell + 1e-9).floor();
double _center(double degrees, double offset) => (_index(degrees, offset) + 0.5) * _cell - offset;

ExpoZone _zone(String name, double lat, double lon, {required int count, int? silentSince, int last = 0}) =>
    ExpoZone(name, _center(lat, 90), _center(lon, 180), count: count, silentSinceMinutes: silentSince, lastMinutesAgo: last);

/// Seis zonas: dos siguen reportando, cuatro callaron (hace 45 min, 95 min, 150 min y 240 min).
final List<ExpoZone> kExpoZones = [
  _zone('Centro', 5.0689, -75.5174, count: 14, last: 4),
  _zone('La Enea', 5.0399, -75.4830, count: 9, last: 11),
  _zone('Chipre', 5.0700, -75.5300, count: 7, silentSince: 95),
  _zone('Palogrande', 5.0560, -75.4960, count: 5, silentSince: 150),
  _zone('Villamaría', 5.0440, -75.5160, count: 1, silentSince: 45), // un mensaje suelto
  _zone('Alta Suiza', 5.0780, -75.4880, count: 4, silentSince: 240), // con un urgente antes de callar
];

/// Un reporte sintético: cuándo llegó (minutos atrás), dónde y qué trae.
class ExpoReport {
  const ExpoReport({required this.minutesAgo, required this.zone, required this.lat, required this.lon, required this.flags, required this.people, required this.text, required this.device});

  final int minutesAgo;
  final String zone;
  final double lat;
  final double lon;
  final int flags;
  final int people;
  final String? text;

  /// Dispositivo (16 hex): uno por reporte.
  final String device;

  /// Trae un indicador de riesgo grave (atrapado, herido o incendio).
  bool get urgent => flags & (SituationFlags.atrapado | SituationFlags.herido | SituationFlags.incendio) != 0;
}

typedef _Kind = ({int flags, int people, List<String?> texts});

final List<_Kind> _kinds = [
  (flags: SituationFlags.atrapado | SituationFlags.herido, people: 2, texts: ['atrapados bajo escombros, hay un herido', 'mi mamá no puede salir del segundo piso']),
  (flags: SituationFlags.herido, people: 1, texts: ['herido en la pierna, necesita ayuda', 'una persona con un golpe en la cabeza']),
  (flags: SituationFlags.viaBloqueada, people: 0, texts: ['derrumbe bloquea la calle', 'puente dañado, no pasan carros']),
  (flags: SituationFlags.incendio, people: 0, texts: ['humo saliendo de una bodega', 'se incendia un poste']),
  (flags: 0, people: 0, texts: [null]), // un SOS sin detalle
  (flags: 0, people: 0, texts: ['sin luz hace horas', 'necesitamos agua']),
];

// Pesos de cada clase (suman 100).
const List<int> _weights = [10, 22, 20, 14, 18, 16];

/// La historia completa, de la más vieja a la más nueva. Deja libres los últimos 3 minutos para lo que se haga en vivo.
List<ExpoReport> buildExpoScenario({int seed = 7}) {
  final rnd = Random(seed);
  final out = <ExpoReport>[];
  var device = 0;
  _Kind pick() {
    var r = rnd.nextInt(100);
    for (var i = 0; i < _kinds.length; i++) {
      r -= _weights[i];
      if (r < 0) return _kinds[i];
    }
    return _kinds.last;
  }

  for (final z in kExpoZones) {
    final last = z.silentSinceMinutes ?? z.lastMinutesAgo;
    final first = min(kExpoWindowMinutes - 5, last + 200); // la historia de cada zona abarca unos 200 min antes de su último reporte
    final times = <int>[last + rnd.nextInt(3)]; // el último reporte fija cuándo calló (o cuándo llegó el más reciente)
    for (var i = 1; i < z.count; i++) {
      times.add(last + 3 + rnd.nextInt(max(1, first - last - 3)));
    }
    for (var i = 0; i < times.length; i++) {
      // El primer reporte de Alta Suiza es el urgente que tuvo antes de callar.
      final kind = (z.name == 'Alta Suiza' && i == times.length - 1) ? _kinds.first : pick();
      final jitterLat = (rnd.nextDouble() - 0.5) * 0.003, jitterLon = (rnd.nextDouble() - 0.5) * 0.003; // ±0,0015° (≈ 165 m): dentro de la celda
      out.add(
        ExpoReport(
          minutesAgo: times[i],
          zone: z.name,
          lat: z.lat + jitterLat,
          lon: z.lon + jitterLon,
          flags: kind.flags,
          people: kind.people,
          text: kind.texts[rnd.nextInt(kind.texts.length)],
          device: '5e${(device++).toRadixString(16).padLeft(14, '0')}',
        ),
      );
    }
  }
  out.sort((a, b) {
    final t = b.minutesAgo.compareTo(a.minutesAgo);
    return t != 0 ? t : a.device.compareTo(b.device);
  });
  return out;
}
