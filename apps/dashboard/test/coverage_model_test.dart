import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/models.dart';

final Uri base = Uri.parse('http://nodo:8081');

http.Response ok(Object body, {int status = 200}) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object?> cell({String id = '1:2', double lat = 5.07, double lon = -75.51, int total = 3, int urgent = 1, int lastAtMs = 1800000000000 - 2 * 3600 * 1000}) =>
    {'id': id, 'lat': lat, 'lon': lon, 'total': total, 'urgent': urgent, 'lastAtMs': lastAtMs};

Map<String, Object?> body({List<Object?>? cells, Map<String, Object?> extra = const {}}) => {
  'nowMs': 1800000000000,
  'cellDeg': 0.005,
  'activityMs': 6 * 3600 * 1000,
  'silenceMs': 30 * 60 * 1000,
  'cells': cells ?? [cell()],
  'silentTotal': 1,
  'activeCells': 4,
  'reportsInWindow': 19,
  'withoutLocation': 2,
  ...extra,
};

void main() {
  group('CoverageInfo.fromJson', () {
    test('parsea las zonas, los totales y las ventanas tal como las manda el nodo', () {
      final c = CoverageInfo.fromJson(body());
      expect(c.cells, hasLength(1));
      expect((c.cells.single.id, c.cells.single.total, c.cells.single.urgent), ('1:2', 3, 1));
      expect((c.silentTotal, c.activeCells, c.reportsInWindow, c.withoutLocation), (1, 4, 19, 2));
      expect((c.cellDeg, c.nowMs), (0.005, 1800000000000));
      expect((c.activity, c.silence), (const Duration(hours: 6), const Duration(minutes: 30)));
    });

    test('«hace cuánto calló» sale del reloj DEL NODO (no del tablero), así un reloj de la pantalla mal puesto no lo falsea', () {
      final c = CoverageInfo.fromJson(body(cells: [cell(lastAtMs: 1800000000000 - 47 * 60 * 1000)]));
      expect(c.silentFor(c.cells.single), const Duration(minutes: 47));
      // Una recepción en el futuro del nodo no da duraciones negativas.
      final future = CoverageInfo.fromJson(body(cells: [cell(lastAtMs: 1800000000000 + 5000)]));
      expect(future.silentFor(future.cells.single), Duration.zero);
    });

    test('una zona mal formada invalida la respuesta entera (no se dibuja a medias): FormatException', () {
      expect(() => CoverageInfo.fromJson(body(cells: [cell(), {'id': 'x'}])), throwsFormatException);
      expect(() => CoverageInfo.fromJson(body(cells: [cell(lat: double.nan)])), throwsFormatException, reason: 'una coordenada no finita no se dibuja');
      expect(() => CoverageInfo.fromJson(body(cells: [cell(total: -1)])), throwsFormatException);
      expect(() => CoverageInfo.fromJson(body(extra: {'cells': 'no'})), throwsFormatException);
      expect(() => CoverageInfo.fromJson(body(extra: {'cellDeg': 0})), throwsFormatException, reason: 'una celda sin tamaño no se puede dibujar');
      expect(() => CoverageInfo.fromJson(body(extra: {'silenceMs': 'x'})), throwsFormatException);
      expect(() => CoverageInfo.fromJson('hola'), throwsFormatException);
    });

    test('lo urgente nunca supera el total de la zona (sería un dato incoherente)', () {
      expect(() => CoverageInfo.fromJson(body(cells: [cell(total: 2, urgent: 3)])), throwsFormatException);
    });
  });

  group('HttpDashboardApi.coverage', () {
    test('GET /api/coverage y parsea la respuesta', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return ok(body());
      }), base);
      final c = await api.coverage();
      expect(seen.path, '/api/coverage');
      expect(c!.cells, hasLength(1));
    });

    test('un nodo anterior (404) NO es un error: devuelve null y el tablero lo dice', () async {
      final api = HttpDashboardApi(MockClient((r) async => ok({'error': 'no existe'}, status: 404)), base);
      expect(await api.coverage(), isNull);
    });

    test('401 es AccessDenied (se vuelve a pedir el código), otro error es ApiException y un cuerpo raro, FormatException', () async {
      expect(HttpDashboardApi(MockClient((r) async => ok({}, status: 401)), base).coverage(), throwsA(isA<AccessDenied>()));
      expect(HttpDashboardApi(MockClient((r) async => ok({}, status: 500)), base).coverage(), throwsA(isA<ApiException>()));
      expect(HttpDashboardApi(MockClient((r) async => ok({'otra': 1})), base).coverage(), throwsFormatException);
    });
  });
}
