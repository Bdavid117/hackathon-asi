import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

/// La primera fila del contrato real (un incidente localizado) con lo que se pida cambiado.
IncidentRow rowWith(Map<String, Object?> over) {
  final base = (fixture('incidents_short.json')['items']! as List).first as Map;
  final json = {...base.cast<String, Object?>(), ...over};
  return IncidentRow.fromJson(json);
}

void main() {
  group('la precisión de la ubicación de un incidente', () {
    test('se lee el nombre que manda el nodo', () {
      expect(rowWith({'locQuality': 'within50m'}).locQuality, 'within50m');
    });

    test('un nodo anterior no lo manda: es desconocida (nulo), no un error', () {
      final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
      final json = {...base}..remove('locQuality');
      expect(IncidentRow.fromJson(json).locQuality, isNull);
    });

    test('un valor que este tablero no conoce (de un nodo más nuevo) se lee como desconocido, no rompe', () {
      expect(rowWith({'locQuality': 'within5m'}).locQuality, isNull);
      expect(rowWith({'locQuality': 7}).locQuality, isNull);
    });

    test('el radio en metros de cada calidad; «más de 1 km» y «a mano» no tienen uno', () {
      expect(rowWith({'locQuality': 'within10m'}).locRadiusMeters, 10);
      expect(rowWith({'locQuality': 'within50m'}).locRadiusMeters, 50);
      expect(rowWith({'locQuality': 'within200m'}).locRadiusMeters, 200);
      expect(rowWith({'locQuality': 'within1km'}).locRadiusMeters, 1000);
      expect(rowWith({'locQuality': 'over1km'}).locRadiusMeters, isNull);
      expect(rowWith({'locQuality': 'manual'}).locRadiusMeters, isNull);
      expect(rowWith({'locQuality': null}).locRadiusMeters, isNull);
    });
  });

  group('locPrecisionLabel: etiquetas en español que nunca rompen', () {
    test('cada calidad dice lo que es', () {
      expect(locPrecisionLabel('within10m'), 'Precisión: unos 10 m');
      expect(locPrecisionLabel('within50m'), 'Precisión: unos 50 m');
      expect(locPrecisionLabel('within200m'), 'Precisión: unos 200 m');
      expect(locPrecisionLabel('within1km'), 'Precisión: hasta 1 km');
      expect(locPrecisionLabel('over1km'), 'Precisión: más de 1 km');
      expect(locPrecisionLabel('manual'), 'Ubicación escrita a mano');
    });

    test('sin dato o con un código nuevo no se inventa una cifra', () {
      expect(locPrecisionLabel(null), 'Precisión desconocida');
      expect(locPrecisionLabel('within5m'), 'Precisión desconocida');
    });
  });
}
