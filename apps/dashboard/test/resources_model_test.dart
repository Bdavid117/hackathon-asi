import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/models.dart';

final Uri base = Uri.parse('http://nodo:8081');

Map<String, Object?> unit([Map<String, Object?> over = const {}]) => {
  'id': 'AMB-01',
  'kind': 'ambulancia',
  'label': 'Ambulancia 1',
  'lat': 5.071,
  'lon': -75.514,
  'available': true,
  'conflict': false,
  'declarationIds': <String>[],
  ...over,
};

http.Response ok(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  group('ResourceUnit.fromJson: lo que dice el nodo', () {
    test('una unidad completa', () {
      final u = ResourceUnit.fromJson(unit({'declarationIds': ['A:1'], 'declaredBy': 'Ana'}));
      expect((u.id, u.kind, u.label, u.lat, u.lon, u.available, u.conflict), ('AMB-01', 'ambulancia', 'Ambulancia 1', 5.071, -75.514, true, false));
      expect(u.declarationIds, ['A:1']);
      expect(u.declaredBy, 'Ana');
    });

    test('un nodo anterior no manda conflicto ni declaraciones: sin conflicto y sin declaraciones', () {
      final j = unit()..remove('conflict')..remove('declarationIds');
      final u = ResourceUnit.fromJson(j);
      expect(u.conflict, isFalse);
      expect(u.declarationIds, isEmpty);
    });

    test('lo imprescindible mal formado es un error claro (no una unidad inventada)', () {
      for (final bad in [{'id': 7}, {'kind': null}, {'lat': 'x'}, {'available': 'sí'}, {'label': 3}]) {
        expect(() => ResourceUnit.fromJson(unit(bad)), throwsFormatException, reason: '$bad');
      }
    });

    test('el tipo se dice en español, y uno desconocido no rompe', () {
      expect(resourceKindLabel('ambulancia'), 'Ambulancia');
      expect(resourceKindLabel('bomberos'), 'Bomberos');
      expect(resourceKindLabel('rescate'), 'Rescate');
      expect(resourceKindLabel('transito'), 'Tránsito');
      expect(resourceKindLabel('dron'), 'Dron');
    });

    test('una unidad no disponible o en conflicto NO se ofrece (isOffered)', () {
      expect(ResourceUnit.fromJson(unit()).isOffered, isTrue);
      expect(ResourceUnit.fromJson(unit({'available': false})).isOffered, isFalse);
      expect(ResourceUnit.fromJson(unit({'conflict': true, 'available': true})).isOffered, isFalse, reason: 'un conflicto nunca deja una unidad ofrecida');
    });
  });

  group('HttpDashboardApi.resources / declareResource', () {
    test('GET /api/resources parsea la lista, ordenada como la manda el nodo', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return ok({'resources': [unit(), unit({'id': 'BOM-01', 'kind': 'bomberos', 'label': 'B'})]});
      }), base);
      final l = await api.resources();
      expect(seen.path, '/api/resources');
      expect([for (final u in l) u.id], ['AMB-01', 'BOM-01']);
    });

    test('una respuesta que no es lo esperado es un FormatException (el tablero la declara inválida, no se la traga)', () async {
      final api = HttpDashboardApi(MockClient((r) async => ok({'otra': 1})), base);
      expect(api.resources(), throwsFormatException);
    });

    test('POST con los campos de la unidad, quién declara y lo que reemplaza', () async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return ok({'id': 'A:7'});
      }), base);
      await api.declareResource(id: 'AMB-01', kind: 'ambulancia', label: 'Ambulancia 1', lat: 5.071, lon: -75.514, available: false, who: 'Ana Gómez', supersedes: ['A:1', 'B:2']);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/resources');
      expect(seen.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(seen.body), {'id': 'AMB-01', 'kind': 'ambulancia', 'label': 'Ambulancia 1', 'lat': 5.071, 'lon': -75.514, 'available': false, 'who': 'Ana Gómez', 'supersedes': ['A:1', 'B:2']});
    });

    test('sin reemplazos no manda la clave', () async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return ok({'id': 'A:7'});
      }), base);
      await api.declareResource(id: 'AMB-09', kind: 'ambulancia', label: 'Nueva', lat: 5.0, lon: -75.0, available: true, who: 'Ana');
      expect((jsonDecode(seen.body) as Map).containsKey('supersedes'), isFalse);
    });

    test('un 401 es AccessDenied; otro error, ApiException con el motivo; con código lleva la cabecera', () async {
      final denied = HttpDashboardApi(MockClient((r) async => http.Response('no', 401)), base);
      expect(denied.declareResource(id: 'A', kind: 'ambulancia', label: 'x', lat: 1, lon: 1, available: true, who: 'a'), throwsA(isA<AccessDenied>()));
      final bad = HttpDashboardApi(MockClient((r) async => http.Response.bytes(utf8.encode('lat debe ser un número'), 400)), base);
      expect(bad.declareResource(id: 'A', kind: 'ambulancia', label: 'x', lat: 1, lon: 1, available: true, who: 'a'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)));
      late http.Request seen;
      final withCode = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return ok({'resources': <Object>[]});
      }), base)..accessCode = 'coord-1234';
      await withCode.resources();
      expect(seen.headers['authorization'], 'Bearer coord-1234');
    });
  });
}
