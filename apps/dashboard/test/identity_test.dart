import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/dispatch_dialog.dart';
import 'package:sard_dashboard/resources_dialog.dart';

import 'detail_panel_test.dart' show p1With, p1;
import 'fake_api.dart';

final Uri base = Uri.parse('http://nodo:8081');
http.Response json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json; charset=utf-8'});

TextField field(WidgetTester t, String key) => t.widget<TextField>(find.byKey(Key(key)));

void main() {
  group('HttpDashboardApi.whoami: quién dice el nodo que soy', () {
    test('GET /api/whoami con el código; devuelve el nombre', () async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return json({'who': 'Ana Gómez'});
      }), base)..accessCode = 'ana-codigo-26';
      expect(await api.whoami(), 'Ana Gómez');
      expect(seen.url.path, '/api/whoami');
      expect(seen.headers['authorization'], 'Bearer ana-codigo-26');
    });

    test('{who: null}: el nodo no identifica a nadie (código compartido o sin código)', () async {
      expect(await HttpDashboardApi(MockClient((r) async => json({'who': null})), base).whoami(), isNull);
    });

    test('un nodo anterior (404) no identifica a nadie: el nombre queda libre como siempre', () async {
      expect(await HttpDashboardApi(MockClient((r) async => http.Response('no existe', 404)), base).whoami(), isNull);
    });

    test('un 401 es AccessDenied; otro error, ApiException', () async {
      await expectLater(HttpDashboardApi(MockClient((r) async => http.Response('no', 401)), base).whoami(), throwsA(isA<AccessDenied>()));
      await expectLater(HttpDashboardApi(MockClient((r) async => http.Response('mal', 500)), base).whoami(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    });

    test('una respuesta que no es lo esperado es un FormatException, no un nombre inventado', () async {
      for (final body in [<String, Object?>{'who': 7}, <String, Object?>{'otro': 'x'}, <String, Object?>{'who': ''}]) {
        await expectLater(HttpDashboardApi(MockClient((r) async => json(body)), base).whoami(), throwsFormatException, reason: '$body');
      }
    });
  });

  group('con identidad, el nombre va fijado y es el del código', () {
    testWidgets('la decisión: campo de sólo lectura con el nombre, y se envía ese nombre', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      final api = FakeApi(details: {p1: p1With()});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: p1, every: null, who: ValueNotifier(''), identity: 'Luis Torres'))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      expect(field(tester, 'who_field').readOnly, isTrue);
      expect(field(tester, 'who_field').controller!.text, 'Luis Torres');
      expect(find.byKey(const Key('who_identified')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide').single.args['who'], 'Luis Torres');
    });

    testWidgets('sin identidad el campo sigue libre (como antes)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      final api = FakeApi(details: {p1: p1With()});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: p1, every: null, who: ValueNotifier('')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      expect(field(tester, 'who_field').readOnly, isFalse);
      expect(find.byKey(const Key('who_identified')), findsNothing);
    });

    testWidgets('el informe del despachador', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      final api = FakeApi();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DispatchDialog(api: api, who: ValueNotifier(''), identity: 'Luis Torres'))));
      await tester.pumpAndSettle();
      expect(field(tester, 'dispatch_who').readOnly, isTrue);
      expect(field(tester, 'dispatch_who').controller!.text, 'Luis Torres');
      expect(find.byKey(const Key('dispatch_who_identified')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('dispatch_text')), 'edificio con gente atrapada');
      await tester.ensureVisible(find.byKey(const Key('medium_radio')));
      await tester.tap(find.byKey(const Key('medium_radio')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('send_dispatch')));
      await tester.tap(find.byKey(const Key('send_dispatch')));
      await tester.pumpAndSettle();
      expect(api.of('dispatch').single.args['who'], 'Luis Torres');
    });

    testWidgets('los recursos', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      final api = FakeApi();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ResourcesDialog(api: api, who: ValueNotifier(''), units: api.units, onChanged: (_) {}, identity: 'Luis Torres'))));
      await tester.pumpAndSettle();
      expect(field(tester, 'resources_who').readOnly, isTrue);
      expect(field(tester, 'resources_who').controller!.text, 'Luis Torres');
      expect(find.byKey(const Key('resources_who_identified')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('unit_toggle_AMB-01')));
      await tester.tap(find.byKey(const Key('unit_toggle_AMB-01')));
      await tester.pumpAndSettle();
      expect(api.of('declareResource').single.args['who'], 'Luis Torres');
    });
  });

  group('en la pantalla: la identidad sigue al código', () {
    Future<FakeApi> boot(WidgetTester tester, {String? code, String? name, Duration? every}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final api = FakeApi()..whoamiName = name;
      if (code != null) api.requireCode = code;
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      return api;
    }

    Future<void> enter(WidgetTester tester, String code) async {
      await tester.enterText(find.byKey(const Key('access_code')), code);
      await tester.tap(find.byKey(const Key('access_enter')));
      await tester.pumpAndSettle();
    }

    Future<void> openResources(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('resources_open')));
      await tester.pumpAndSettle();
    }

    testWidgets('con identidad, el panel de recursos llega con el nombre fijado', (tester) async {
      await boot(tester, name: 'Ana Gómez');
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isTrue);
      expect(field(tester, 'resources_who').controller!.text, 'Ana Gómez');
    });

    testWidgets('el despachador llega con el nombre fijado', (tester) async {
      await boot(tester, name: 'Ana Gómez');
      await tester.tap(find.byKey(const Key('dispatch_open')));
      await tester.pumpAndSettle();
      expect(field(tester, 'dispatch_who').readOnly, isTrue);
      expect(field(tester, 'dispatch_who').controller!.text, 'Ana Gómez');
    });

    testWidgets('la decisión de un incidente (panel ancho) llega con el nombre fijado', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1200);
      addTearDown(tester.view.reset);
      final api = FakeApi(details: {p1: p1With()})..whoamiName = 'Ana Gómez';
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident_$p1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      expect(field(tester, 'who_field').readOnly, isTrue);
      expect(field(tester, 'who_field').controller!.text, 'Ana Gómez');
    });

    testWidgets('la decisión de un incidente (pantalla estrecha, otra ruta) llega con el nombre fijado', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 1200);
      addTearDown(tester.view.reset);
      final api = FakeApi(details: {p1: p1With()})..whoamiName = 'Ana Gómez';
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incident_$p1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('approve_button')));
      await tester.pumpAndSettle();
      expect(field(tester, 'who_field').readOnly, isTrue);
      expect(field(tester, 'who_field').controller!.text, 'Ana Gómez');
    });

    testWidgets('sin identidad (nodo anterior o código compartido) el nombre queda libre y vacío', (tester) async {
      await boot(tester, name: null);
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isFalse);
      expect(field(tester, 'resources_who').controller!.text, isEmpty);
    });

    testWidgets('se pregunta UNA vez por sesión, no en cada lectura de la cola', (tester) async {
      final api = await boot(tester, name: 'Ana Gómez', every: const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 7));
      expect(api.of('whoami'), hasLength(1));
    });

    testWidgets('OTRO código, OTRO nombre: tras perder el acceso y entrar con el de Luis, el nombre es el de Luis', (tester) async {
      final api = await boot(tester, code: 'ana-codigo-26', name: 'Ana Gómez', every: const Duration(seconds: 2));
      api.identities = {'ana-codigo-26': 'Ana Gómez', 'luis-codigo-26': 'Luis Torres'};
      await enter(tester, 'ana-codigo-26');
      await openResources(tester);
      expect(field(tester, 'resources_who').controller!.text, 'Ana Gómez');
      await tester.tap(find.byKey(const Key('resources_close')));
      await tester.pumpAndSettle();
      api.requireCode = 'luis-codigo-26'; // el nodo cambió de código
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      await enter(tester, 'luis-codigo-26');
      await openResources(tester);
      expect(field(tester, 'resources_who').controller!.text, 'Luis Torres');
    });

    testWidgets('si whoami falla tras volver a entrar NO queda el nombre viejo bloqueado: el campo queda libre y vacío', (tester) async {
      final api = await boot(tester, code: 'ana-codigo-26', every: const Duration(seconds: 2));
      api.identities = {'ana-codigo-26': 'Ana Gómez'};
      await enter(tester, 'ana-codigo-26');
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isTrue);
      await tester.tap(find.byKey(const Key('resources_close')));
      await tester.pumpAndSettle();
      api.requireCode = 'luis-codigo-26';
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      api.failWhoami = const ApiException(500, 'caído');
      await enter(tester, 'luis-codigo-26');
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isFalse, reason: 'no se sabe quién es: no se finge ni se deja el de antes');
      expect(field(tester, 'resources_who').controller!.text, isEmpty, reason: 'el nombre de Ana no debe quedar escrito para firmar con el código de Luis');
    });

    testWidgets('un fallo pasajero de whoami se reintenta en la lectura siguiente (no se queda sin identidad para siempre)', (tester) async {
      final api = FakeApi()
        ..whoamiName = 'Ana Gómez'
        ..failWhoami = const ApiException(500, 'caído');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: const Duration(seconds: 2))));
      await tester.pumpAndSettle();
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isFalse, reason: 'el montaje: el primer intento falló');
      await tester.tap(find.byKey(const Key('resources_close')));
      await tester.pumpAndSettle();
      api.failWhoami = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isTrue);
      expect(field(tester, 'resources_who').controller!.text, 'Ana Gómez');
    });

    testWidgets('una respuesta de whoami que llega DESPUÉS de perder el acceso no se aplica (era de otro código)', (tester) async {
      final api = FakeApi()
        ..requireCode = 'ana-codigo-26'
        ..identities = {'ana-codigo-26': 'Ana Gómez'}
        ..whoamiGate = Completer<void>();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: const Duration(seconds: 2))));
      await tester.pumpAndSettle();
      await enter(tester, 'ana-codigo-26'); // whoami queda esperando
      api.requireCode = 'luis-codigo-26';
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget, reason: 'el montaje: se perdió el acceso con whoami en vuelo');
      api.whoamiGate!.complete(); // ahora llega la respuesta vieja («Ana Gómez»)
      await tester.pumpAndSettle();
      api
        ..whoamiGate = null
        ..failWhoami = const ApiException(500, 'caído');
      await enter(tester, 'luis-codigo-26');
      await openResources(tester);
      expect(field(tester, 'resources_who').readOnly, isFalse, reason: 'no queda el nombre del código anterior');
      expect(field(tester, 'resources_who').controller!.text, isEmpty);
    });

    testWidgets('si whoami da 401 el tablero vuelve a pedir el código', (tester) async {
      final api = await boot(tester);
      expect(find.byKey(const Key('counters')), findsOneWidget);
      api.failWhoami = const AccessDenied();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
    });
  });
}
