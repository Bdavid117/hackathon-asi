import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';

import 'fake_api.dart';

final Uri base = Uri.parse('http://nodo:8081');

void main() {
  group('el contrato con el nodo (el mismo literal que lee la prueba del nodo)', () {
    final literal = jsonDecode(File('../node/test/fixtures/dispatch_request.json').readAsStringSync()) as Map<String, Object?>;

    Future<Map<String, Object?>> body({double? lat, double? lon}) async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return http.Response('{"id":"x"}', 200);
      }), base);
      await api.dispatch(id: 'a1b2c3d4e5f6a7b8', text: 'edificio con gente atrapada en la carrera 23, mensaje cortado', medium: 'telefono', who: 'Ana Gómez', origin: 'Estación Bomberos 3', flags: ['atrapado', 'herido'], people: 2, lat: lat, lon: lon);
      return (jsonDecode(seen.body) as Map).cast<String, Object?>();
    }

    test('con ubicación: el cuerpo es EXACTAMENTE el literal, con latitud y longitud como números', () async {
      expect(literal['lat'], isA<num>());
      expect(await body(lat: literal['lat']! as double, lon: literal['lon']! as double), literal);
    });

    test('una ubicación a medias (sólo la latitud) NO se manda: el nodo la rechazaría y el cliente no la completa', () async {
      final sent = await body(lat: 5.0689);
      expect(sent.containsKey('lat'), isFalse);
      expect(sent.containsKey('lon'), isFalse);
    });

    test('sin ubicación: el cuerpo es el mismo literal sin esas dos claves (no manda nulos)', () async {
      final sent = await body();
      expect(sent, {...literal}..remove('lat')..remove('lon'));
      expect(sent.containsKey('lat'), isFalse);
    });
  });

  group('el formulario «Registrar informe»', () {
    Future<FakeApi> boot(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1400);
      addTearDown(tester.view.reset);
      final api = FakeApi();
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dispatch_open')));
      await tester.pumpAndSettle();
      return api;
    }

    Future<void> write(WidgetTester tester, String key, String text) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.enterText(find.byKey(Key(key)), text);
      await tester.pump();
    }

    Future<void> fillBasics(WidgetTester tester) async {
      await write(tester, 'dispatch_text', 'edificio con gente atrapada');
      await write(tester, 'dispatch_who', 'Ana Gómez');
    }

    Future<void> send(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('send_dispatch')));
      await tester.tap(find.byKey(const Key('send_dispatch')));
      await tester.pumpAndSettle();
    }

    testWidgets('los dos campos existen, son opcionales y explican qué se registra', (tester) async {
      await boot(tester);
      expect(find.byKey(const Key('dispatch_lat')), findsOneWidget);
      expect(find.byKey(const Key('dispatch_lon')), findsOneWidget);
      expect(find.textContaining('escrita a mano'), findsOneWidget);
    });

    testWidgets('sin llenarlos se envía como siempre: sin ubicación', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      await send(tester);
      final call = api.of('dispatch').single.args;
      expect(call['lat'], isNull);
      expect(call['lon'], isNull);
    });

    testWidgets('con latitud y longitud se envían como números', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      await write(tester, 'dispatch_lat', '5.0689');
      await write(tester, 'dispatch_lon', '-75.5174');
      await send(tester);
      final call = api.of('dispatch').single.args;
      expect((call['lat'], call['lon']), (5.0689, -75.5174));
    });

    testWidgets('acepta coma decimal (como se escribe en español) y espacios', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      await write(tester, 'dispatch_lat', ' 5,0689 ');
      await write(tester, 'dispatch_lon', '-75,5174');
      await send(tester);
      final call = api.of('dispatch').single.args;
      expect((call['lat'], call['lon']), (5.0689, -75.5174));
    });

    testWidgets('una sola de las dos: lo dice y NO envía nada', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      await write(tester, 'dispatch_lat', '5.0689');
      await send(tester);
      expect(find.byKey(const Key('dispatch_loc_error')), findsOneWidget);
      expect(find.textContaining('las dos'), findsOneWidget);
      expect(api.of('dispatch'), isEmpty);
    });

    testWidgets('fuera de rango, o no numérico: lo dice y NO envía', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      for (final bad in [('91', '0'), ('0', '181'), ('-91', '10'), ('abc', '10'), ('5.07', 'xyz'), ('NaN', '1'), ('Infinity', '1')]) {
        await write(tester, 'dispatch_lat', bad.$1);
        await write(tester, 'dispatch_lon', bad.$2);
        await send(tester);
        expect(find.byKey(const Key('dispatch_loc_error')), findsOneWidget, reason: '$bad');
        expect(api.of('dispatch'), isEmpty, reason: '$bad');
      }
    });

    testWidgets('los extremos válidos se envían', (tester) async {
      final api = await boot(tester);
      await fillBasics(tester);
      await write(tester, 'dispatch_lat', '-90');
      await write(tester, 'dispatch_lon', '180');
      await send(tester);
      expect((api.of('dispatch').single.args['lat'], api.of('dispatch').single.args['lon']), (-90.0, 180.0));
    });

    testWidgets('cambiar la ubicación tras un intento fallido genera OTRO identificador (no choca con un 409)', (tester) async {
      final api = await boot(tester);
      api.failDispatch = const ApiException(500, 'caído');
      await fillBasics(tester);
      await write(tester, 'dispatch_lat', '5.0');
      await write(tester, 'dispatch_lon', '-75.0');
      await send(tester);
      await write(tester, 'dispatch_lat', '5.5');
      await send(tester);
      await send(tester);
      final ids = [for (final c in api.of('dispatch')) c.args['id']];
      expect(ids, hasLength(3));
      expect(ids[0] == ids[1], isFalse, reason: 'otro contenido, otro id');
      expect(ids[1] == ids[2], isTrue, reason: 'el mismo contenido reintenta con el MISMO id');
    });
  });
}
