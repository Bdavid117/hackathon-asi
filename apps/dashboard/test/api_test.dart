import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';

String fx(String name) => File('test/fixtures/$name').readAsStringSync();

final Uri base = Uri.parse('http://nodo:8081');

http.Response json(String body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response.bytes(utf8.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

void main() {
  group('HttpDashboardApi.incidents', () {
    test('pide la vista corta por omisión y parsea el sobre', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return json(fx('incidents_short.json'), headers: {'x-queue-stale': 'false', 'x-queue-age-ms': '120', 'etag': 'W/"a.1:/api/incidents?"'});
      }), base);
      final page = await api.incidents();
      expect(seen.path, '/api/incidents');
      expect(seen.query, isEmpty);
      expect(page.view, 'short');
      expect(page.items, hasLength(5));
      expect(page.stale, isFalse);
      expect(page.ageMs, 120);
    });

    test('arma la consulta de la vista completa con filtros y página', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return json(fx('incidents_all.json'));
      }), base);
      await api.incidents(view: 'all', urgency: 'P1', bare: false, offset: 50, limit: 25);
      expect(seen.queryParameters, {'view': 'all', 'urgency': 'P1', 'bare': 'false', 'offset': '50', 'limit': '25'});
    });

    test('anota que el nodo sirvió una versión anterior', () async {
      final api = HttpDashboardApi(MockClient((r) async => json(fx('incidents_short.json'), headers: {'x-queue-stale': 'true', 'x-queue-age-ms': '4300'})), base);
      final page = await api.incidents();
      expect(page.stale, isTrue);
      expect(page.ageMs, 4300);
    });

    test('ETag: la segunda lectura manda If-None-Match y, con 304, reutiliza la página sin volver a parsear, con la frescura nueva', () async {
      var calls = 0;
      String? sentTag;
      final api = HttpDashboardApi(MockClient((r) async {
        calls++;
        sentTag = r.headers['if-none-match'];
        if (calls == 1) return json(fx('incidents_short.json'), headers: {'etag': 'W/"x.1:/api/incidents?"', 'x-queue-stale': 'false', 'x-queue-age-ms': '10'});
        return http.Response('', 304, headers: {'etag': 'W/"x.1:/api/incidents?"', 'x-queue-stale': 'true', 'x-queue-age-ms': '7000'});
      }), base);
      final first = await api.incidents();
      final second = await api.incidents();
      expect(sentTag, 'W/"x.1:/api/incidents?"');
      expect(second.items.length, first.items.length);
      expect(second.stale, isTrue, reason: 'la frescura es la de AHORA, no la de la primera lectura');
      expect(second.ageMs, 7000);
    });

    test('cada consulta tiene su propia caché de ETag', () async {
      final tags = <String?>[];
      final api = HttpDashboardApi(MockClient((r) async {
        tags.add(r.headers['if-none-match']);
        return json(r.url.query.contains('all') ? fx('incidents_all.json') : fx('incidents_short.json'), headers: {'etag': 'W/"e:${r.url.query}"'});
      }), base);
      await api.incidents();
      await api.incidents(view: 'all');
      await api.incidents();
      await api.incidents(view: 'all');
      expect(tags, [null, null, 'W/"e:"', 'W/"e:view=all"']);
    });

    test('un 304 sin nada en caché (no debería pasar) se resuelve volviendo a pedir sin ETag', () async {
      var calls = 0;
      final api = HttpDashboardApi(MockClient((r) async {
        calls++;
        if (calls == 1) return http.Response('', 304);
        return json(fx('incidents_short.json'));
      }), base);
      expect((await api.incidents()).items, isNotEmpty);
      expect(calls, 2);
    });

    test('un error HTTP lanza ApiException con el estado', () async {
      final api = HttpDashboardApi(MockClient((r) async => http.Response('boom', 500)), base);
      await expectLater(api.incidents(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    });

    test('un 400 trae el motivo del nodo', () async {
      final api = HttpDashboardApi(MockClient((r) async => http.Response('parámetros inválidos: limit', 400)), base);
      await expectLater(api.incidents(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('limit'))));
    });

    test('una respuesta que no es válida lanza FormatException (no se muestra algo dudoso)', () async {
      final api = HttpDashboardApi(MockClient((r) async => json('{"view":"short"}')), base);
      await expectLater(api.incidents(), throwsFormatException);
      final api2 = HttpDashboardApi(MockClient((r) async => json('esto no es json')), base);
      await expectLater(api2.incidents(), throwsFormatException);
    });

    test('un nodo que no responde a tiempo lanza TimeoutException', () async {
      final api = HttpDashboardApi(MockClient((r) => Completer<http.Response>().future), base, timeout: const Duration(milliseconds: 50));
      await expectLater(api.incidents(), throwsA(isA<TimeoutException>()));
    });
  });

  group('HttpDashboardApi.detail', () {
    test('pide el detalle por identificador (con codificación) y lo parsea', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return json(fx('detail_p1_approved.json'));
      }), base);
      final d = await api.detail('00000000000000a1-1');
      expect(seen.path, '/api/incidents/00000000000000a1-1');
      expect(d.row.urgency, 'P1');
      final api2 = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return json(fx('detail_p1_approved.json'));
      }), base);
      await api2.detail('a b/c');
      expect(seen.toString(), contains('a%20b%2Fc'));
    });

    test('un 404 es IncidentGone (pudo fusionarse o dividirse), distinto de un fallo del nodo', () async {
      final api = HttpDashboardApi(MockClient((r) async => http.Response('incidente desconocido', 404)), base);
      await expectLater(api.detail('x-1'), throwsA(isA<IncidentGone>()));
    });
  });

  group('HttpDashboardApi.nodes', () {
    test('lee el estado de los nodos', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return json(fx('nodes.json'));
      }), base);
      final n = await api.nodes();
      expect(seen.path, '/api/nodes');
      expect(n.selfId, 'A');
    });
  });

  group('HttpDashboardApi.decide', () {
    test('envía JSON con todo lo que la persona vio y quién decidió', () async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return json('{"id":"A:000099"}');
      }), base);
      await api.decide(recommendationId: '3fa8370868b2c56c', incidentId: 'aa-1', members: ['aa-1', 'bb-1'], granted: false, who: 'Ana', note: 'no procede', supersedes: ['A:000031']);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/approval');
      expect(seen.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(seen.body), {
        'recommendationId': '3fa8370868b2c56c',
        'incidentId': 'aa-1',
        'members': ['aa-1', 'bb-1'],
        'decision': 'denied',
        'note': 'no procede',
        'who': 'Ana',
        'supersedes': ['A:000031'],
      });
    });

    test('«aprobar» se envía como granted', () async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return json('{"id":"A:1"}');
      }), base);
      await api.decide(recommendationId: '3fa8370868b2c56c', incidentId: 'aa-1', members: const [], granted: true, who: 'Ana');
      expect(jsonDecode(seen.body)['decision'], 'granted');
      expect(jsonDecode(seen.body)['supersedes'], isEmpty);
    });

    test('un rechazo del nodo (400) lanza ApiException con su motivo y NO se da por registrado', () async {
      final api = HttpDashboardApi(MockClient((r) async => http.Response('who debe ser texto de 1 a 80 caracteres', 400)), base);
      await expectLater(
        api.decide(recommendationId: '3fa8370868b2c56c', incidentId: 'aa-1', members: const [], granted: true, who: ''),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)),
      );
    });

    test('si el nodo no responde, lanza (la decisión no se da por hecha)', () async {
      final api = HttpDashboardApi(MockClient((r) async => throw http.ClientException('sin red')), base);
      await expectLater(api.decide(recommendationId: '3fa8370868b2c56c', incidentId: 'aa-1', members: const [], granted: true, who: 'Ana'), throwsA(isA<http.ClientException>()));
    });
  });
}
