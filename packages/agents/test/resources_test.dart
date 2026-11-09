import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:test/test.dart';

Map<String, Object?> res({String id = 'AMB-01', String kind = 'ambulancia', Object? lat = 5.07, Object? lon = -75.51, Object? available = true, Object? label = 'Ambulancia 1'}) => {
  'id': id,
  'kind': kind,
  'label': label,
  'lat': lat,
  'lon': lon,
  'available': available,
};

String doc(List<Object?> rs) => jsonEncode({'resources': rs});

void main() {
  group('parseResources: el archivo de recursos declarados', () {
    test('lee un archivo válido', () {
      final rs = parseResources(doc([res(), res(id: 'BOM-01', kind: 'bomberos', available: false)]));
      expect(rs.map((r) => r.id), ['AMB-01', 'BOM-01']);
      expect(rs.first.kind, ResourceKind.ambulancia);
      expect(rs.first.available, isTrue);
      expect(rs.last.available, isFalse);
      expect(rs.first.lat, 5.07);
    });

    test('los tipos de recurso son un conjunto cerrado', () {
      expect(ResourceKind.values.map((k) => k.name), ['ambulancia', 'bomberos', 'rescate', 'transito']);
    });

    test('un tipo desconocido se rechaza (no se inventa una categoría)', () {
      expect(() => parseResources(doc([res(kind: 'dron_de_ataque')])), throwsFormatException);
    });

    test('ids repetidos se rechazan: un id debe nombrar UN recurso', () {
      expect(() => parseResources(doc([res(), res()])), throwsFormatException);
    });

    test('ids con caracteres raros o demasiado largos se rechazan', () {
      for (final bad in ['', 'a b', 'AMB/01', 'x' * 25, 'AMB\n01', '<script>']) {
        expect(() => parseResources(doc([res(id: bad)])), throwsFormatException, reason: bad);
      }
    });

    test('coordenadas fuera de rango, ausentes o no numéricas se rechazan', () {
      expect(() => parseResources(doc([res(lat: 91)])), throwsFormatException);
      expect(() => parseResources(doc([res(lon: -181)])), throwsFormatException);
      expect(() => parseResources(doc([res(lat: null)])), throwsFormatException);
      expect(() => parseResources(doc([res(lat: '5.07')])), throwsFormatException);
    });

    test('«available» debe ser booleano y la etiqueta, texto corto', () {
      expect(() => parseResources(doc([res(available: 'sí')])), throwsFormatException);
      expect(() => parseResources(doc([res(label: 'x' * 81)])), throwsFormatException);
      expect(() => parseResources(doc([res(label: 7)])), throwsFormatException);
    });

    test('estructura inválida: no es JSON, no es objeto, falta la lista', () {
      expect(() => parseResources('esto no es json'), throwsFormatException);
      expect(() => parseResources('[]'), throwsFormatException);
      expect(() => parseResources('{"resources": 3}'), throwsFormatException);
      expect(() => parseResources('{}'), throwsFormatException);
    });

    test('una lista vacía es válida (no hay recursos declarados)', () {
      expect(parseResources(doc([])), isEmpty);
    });
  });

  group('nearestAvailable: el recurso disponible más cercano de un tipo', () {
    final rs = parseResources(doc([
      res(id: 'AMB-LEJOS', lat: 5.20, lon: -75.60),
      res(id: 'AMB-CERCA', lat: 5.071, lon: -75.511),
      res(id: 'AMB-OCUPADA', lat: 5.0701, lon: -75.5101, available: false),
      res(id: 'BOM-01', kind: 'bomberos', lat: 5.0702, lon: -75.5102),
    ]));

    test('elige el más cercano ENTRE LOS DISPONIBLES del tipo pedido', () {
      expect(nearestAvailable(rs, ResourceKind.ambulancia, 5.07, -75.51)?.id, 'AMB-CERCA');
      expect(nearestAvailable(rs, ResourceKind.bomberos, 5.07, -75.51)?.id, 'BOM-01');
    });

    test('si no hay ninguno disponible de ese tipo, devuelve null (no recurre a otro tipo)', () {
      expect(nearestAvailable(rs, ResourceKind.rescate, 5.07, -75.51), isNull);
      expect(nearestAvailable([rs[2]], ResourceKind.ambulancia, 5.07, -75.51), isNull);
    });

    test('un empate exacto se desempata por id (determinista)', () {
      final tie = parseResources(doc([res(id: 'B', lat: 5.07, lon: -75.51), res(id: 'A', lat: 5.07, lon: -75.51)]));
      expect(nearestAvailable(tie, ResourceKind.ambulancia, 5.07, -75.51)?.id, 'A');
      expect(nearestAvailable(tie.reversed.toList(), ResourceKind.ambulancia, 5.07, -75.51)?.id, 'A');
    });
  });
}
