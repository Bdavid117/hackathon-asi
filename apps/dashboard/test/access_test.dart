import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';

import 'fake_api.dart';

final Uri base = Uri.parse('http://nodo:8081');

/// Qué se envió al nodo: método, ruta y cabecera de autorización.
class Sent {
  Sent(this.method, this.url, this.auth);
  final String method;
  final Uri url;
  final String? auth;
}

HttpDashboardApi apiWith(List<Sent> log, {int status = 200}) => HttpDashboardApi(
  MockClient((r) async {
    log.add(Sent(r.method, r.url, r.headers['authorization']));
    if (status != 200) return http.Response('se exige el código de acceso', status, headers: {'www-authenticate': 'Bearer realm="sard"'});
    if (r.url.path == '/api/nodes') return http.Response.bytes(utf8.encode(jsonEncode(fixture('nodes.json'))), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    if (r.url.path.startsWith('/api/incidents/')) return http.Response.bytes(utf8.encode(jsonEncode(fixture('detail_p1_approved.json'))), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    if (r.url.path == '/api/approval') return http.Response('{"id":"A:000001"}', 200);
    return http.Response.bytes(utf8.encode(jsonEncode(fixture('incidents_short.json'))), 200, headers: {'content-type': 'application/json; charset=utf-8', 'etag': 'W/"1"'});
  }),
  base,
);

Future<void> decide(HttpDashboardApi api) => api.decide(recommendationId: 'a1b2c3d4e5f60718', incidentId: 'aa-1', members: const ['aa-1'], granted: true, who: 'Ana');

void main() {
  group('HttpDashboardApi: el código de acceso', () {
    test('sin código no se envía cabecera de autorización (un nodo sin código se usa como siempre)', () async {
      final sent = <Sent>[];
      final api = apiWith(sent);
      await api.incidents();
      await api.nodes();
      await api.detail('00000000000000a1-1');
      await decide(api);
      expect(sent, hasLength(4));
      expect(sent.map((s) => s.auth), everyElement(isNull));
    });

    test('con código, LAS CUATRO peticiones lo llevan como «Bearer»', () async {
      final sent = <Sent>[];
      final api = apiWith(sent)..accessCode = 'acceso-2026';
      await api.incidents();
      await api.nodes();
      await api.detail('00000000000000a1-1');
      await decide(api);
      expect(sent.map((s) => s.url.path), ['/api/incidents', '/api/nodes', '/api/incidents/00000000000000a1-1', '/api/approval']);
      expect(sent.map((s) => s.auth), everyElement('Bearer acceso-2026'));
    });

    test('la relectura con ETag (If-None-Match) también lo lleva', () async {
      final sent = <Sent>[];
      final api = apiWith(sent)..accessCode = 'acceso-2026';
      await api.incidents();
      await api.incidents();
      expect(sent.map((s) => s.auth), everyElement('Bearer acceso-2026'));
    });

    test('el código NO viaja en la dirección (ni en la consulta): iría a registros y al historial', () async {
      final sent = <Sent>[];
      final api = apiWith(sent)..accessCode = 'acceso-2026';
      await api.incidents(view: 'all', urgency: 'P1');
      await api.nodes();
      await api.detail('x');
      for (final s in sent) {
        expect(s.url.toString(), isNot(contains('acceso-2026')));
      }
    });

    test('cambiar el código surte efecto en la siguiente petición; quitarlo (null) deja de enviarlo', () async {
      final sent = <Sent>[];
      final api = apiWith(sent)..accessCode = 'uno-11111';
      await api.nodes();
      api.accessCode = 'dos-22222';
      await api.nodes();
      api.accessCode = null;
      await api.nodes();
      expect(sent.map((s) => s.auth), ['Bearer uno-11111', 'Bearer dos-22222', null]);
    });

    test('un 401 del nodo es AccessDenied (no «error del nodo») en lectura, detalle, estado y decisión', () async {
      final api = apiWith([], status: 401);
      await expectLater(api.incidents(), throwsA(isA<AccessDenied>()));
      await expectLater(api.nodes(), throwsA(isA<AccessDenied>()));
      await expectLater(api.detail('x'), throwsA(isA<AccessDenied>()));
      await expectLater(decide(api), throwsA(isA<AccessDenied>()));
    });

    test('un 500 sigue siendo ApiException: sólo el 401 es «falta el código»', () async {
      final api = apiWith([], status: 500);
      await expectLater(api.incidents(), throwsA(isA<ApiException>()));
    });
  });

  group('pantalla del tablero con un nodo que exige código', () {
    Future<FakeApi> boot(WidgetTester tester, {Duration? every}) async {
      final api = FakeApi()..requireCode = 'acceso-2026';
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      return api;
    }

    Future<void> enter(WidgetTester tester, String code) async {
      await tester.enterText(find.byKey(const Key('access_code')), code);
      await tester.tap(find.byKey(const Key('access_enter')));
      await tester.pumpAndSettle();
    }

    testWidgets('sin código se ve la pantalla de acceso y NO hay datos de nadie', (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      expect(find.text('Código de acceso'), findsWidgets);
      expect(find.byKey(const Key('counters')), findsNothing);
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byKey(const Key('access_error')), findsNothing, reason: 'todavía no se intentó nada: no se acusa de error');
    });

    testWidgets('un código equivocado dice que no es correcto y sigue sin mostrar datos', (tester) async {
      await boot(tester);
      await enter(tester, 'equivocado');
      expect(find.byKey(const Key('access_error')), findsOneWidget);
      expect(find.textContaining('no es correcto'), findsOneWidget);
      expect(find.byKey(const Key('counters')), findsNothing);
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
    });

    testWidgets('el código bueno abre el tablero, y desde entonces TODAS las lecturas lo llevan', (tester) async {
      final api = await boot(tester);
      await enter(tester, 'acceso-2026');
      expect(find.byKey(const Key('access_prompt')), findsNothing);
      expect(find.byKey(const Key('counters')), findsOneWidget);
      expect(api.accessCode, 'acceso-2026');
    });

    testWidgets('el campo oculta lo que se escribe y no ofrece autocompletar ni sugerencias', (tester) async {
      await boot(tester);
      final field = tester.widget<TextField>(find.byKey(const Key('access_code')));
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
    });

    testWidgets('«Entrar» con el campo vacío no llama al nodo', (tester) async {
      final api = await boot(tester);
      final before = api.of('incidents').length;
      await tester.tap(find.byKey(const Key('access_enter')));
      await tester.pumpAndSettle();
      expect(api.of('incidents').length, before);
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
    });

    testWidgets('mientras está bloqueado NO sondea cada pocos segundos (no se machaca al nodo con peticiones sin código)', (tester) async {
      final api = await boot(tester, every: const Duration(seconds: 2));
      final before = api.of('incidents').length;
      await tester.pump(const Duration(seconds: 7));
      expect(api.of('incidents').length, before);
    });

    testWidgets('si el nodo cambia de código con el tablero abierto, vuelve a pedirlo y lo explica', (tester) async {
      final api = await boot(tester, every: const Duration(seconds: 2));
      await enter(tester, 'acceso-2026');
      expect(find.byKey(const Key('counters')), findsOneWidget);
      api.requireCode = 'rotado-2027'; // el nodo se reinició con otro código
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      expect(find.textContaining('ya no acepta'), findsOneWidget);
      expect(find.byKey(const Key('counters')), findsNothing);
      await enter(tester, 'rotado-2027');
      expect(find.byKey(const Key('counters')), findsOneWidget);
    });

    testWidgets('un nodo SIN código no muestra la pantalla de acceso', (tester) async {
      final api = FakeApi();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsNothing);
      expect(find.byKey(const Key('counters')), findsOneWidget);
    });
  });
}
