import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

ResourceUnit unit(String id, {String kind = 'ambulancia', String label = 'Unidad', bool available = true, bool conflict = false, List<String> decl = const [], double lat = 5.07, double lon = -75.51}) =>
    ResourceUnit(id: id, kind: kind, label: label, lat: lat, lon: lon, available: available, conflict: conflict, declarationIds: decl);

void main() {
  Future<FakeApi> boot(WidgetTester tester, {List<ResourceUnit>? units, Size size = const Size(1280, 1100)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final api = FakeApi();
    if (units != null) api.units = units;
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null)));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('resources_open')));
    await tester.pumpAndSettle();
  }

  Future<void> write(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pump();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  group('el panel «Recursos»', () {
    testWidgets('lista las unidades con su tipo y si están disponibles', (tester) async {
      await boot(tester, units: [unit('AMB-01', label: 'Ambulancia 1'), unit('BOM-01', kind: 'bomberos', label: 'Bomberos 1', available: false)]);
      await open(tester);
      expect(find.byKey(const Key('resources_dialog')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('unit_AMB-01')), matching: find.textContaining('Ambulancia 1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('unit_AMB-01')), matching: find.text('Disponible')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('unit_BOM-01')), matching: find.text('No disponible')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('unit_BOM-01')), matching: find.textContaining('Bomberos')), findsWidgets);
    });

    testWidgets('cada interruptor dice a qué unidad pertenece (un lector de pantalla no oye «interruptor» a secas)', (tester) async {
      final handle = tester.ensureSemantics();
      await boot(tester, units: [unit('AMB-01', label: 'Ambulancia 1'), unit('BOM-01', kind: 'bomberos', label: 'Bomberos 1', available: false)]);
      await open(tester);
      expect(tester.getSemantics(find.byKey(const Key('unit_toggle_AMB-01'))).label, 'Disponibilidad de Ambulancia 1');
      expect(tester.getSemantics(find.byKey(const Key('unit_toggle_BOM-01'))).label, 'Disponibilidad de Bomberos 1');
      handle.dispose();
    });

    testWidgets('con un nombre puesto, cambiar el interruptor declara la unidad con los MISMOS datos y la disponibilidad al revés', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01', label: 'Ambulancia 1', lat: 5.0689, lon: -75.5174)]);
      await open(tester);
      await write(tester, 'resources_who', 'Ana Gómez');
      await tapKey(tester, 'unit_toggle_AMB-01');
      final c = api.of('declareResource').single.args;
      expect((c['id'], c['kind'], c['label'], c['lat'], c['lon'], c['available'], c['who']), ('AMB-01', 'ambulancia', 'Ambulancia 1', 5.0689, -75.5174, false, 'Ana Gómez'));
      expect(c['supersedes'], isEmpty, reason: 'la unidad de arranque no tiene declaraciones que reemplazar');
      expect(find.descendant(of: find.byKey(const Key('unit_AMB-01')), matching: find.text('No disponible')), findsOneWidget, reason: 'el panel se actualiza con lo que dice el nodo');
    });

    testWidgets('una unidad ya declarada reemplaza sus declaraciones vigentes', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01', available: false, decl: ['A:1'])]);
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(api.of('declareResource').single.args['supersedes'], ['A:1']);
      expect(api.of('declareResource').single.args['available'], isTrue);
    });

    testWidgets('sin nombre NO declara: dice que falta quién lo hace y no llama al nodo', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      await open(tester);
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.byKey(const Key('resources_who_error')), findsOneWidget);
      expect(api.of('declareResource'), isEmpty);
    });

    testWidgets('un conflicto se ve con claridad, dice que la unidad NO se ofrece, y se resuelve eligiendo, reemplazando las dos declaraciones', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01', available: false, conflict: true, decl: ['A:1', 'B:1'])]);
      await open(tester);
      final said = tester.widget<Text>(find.byKey(const Key('unit_conflict_AMB-01'))).data!;
      expect(said, contains('no coinciden'));
      expect(said, contains('no se ofrece'));
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_keep_available_AMB-01');
      final c = api.of('declareResource').single.args;
      expect(c['available'], isTrue);
      expect(c['supersedes'], ['A:1', 'B:1']);
    });

    testWidgets('mientras hay conflicto NO hay interruptor (sólo se resuelve eligiendo); sin conflicto, sí', (tester) async {
      await boot(tester, units: [unit('AMB-01', available: false, conflict: true, decl: ['A:1', 'B:1']), unit('AMB-02')]);
      await open(tester);
      expect(find.byKey(const Key('unit_toggle_AMB-01')), findsNothing);
      expect(find.byKey(const Key('unit_toggle_AMB-02')), findsOneWidget);
    });

    testWidgets('«Dejar no disponible» también reemplaza las dos', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01', conflict: true, decl: ['A:1', 'B:1'])]);
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_keep_unavailable_AMB-01');
      expect(api.of('declareResource').single.args['available'], isFalse);
      expect(api.of('declareResource').single.args['supersedes'], ['A:1', 'B:1']);
    });
  });

  group('añadir una unidad', () {
    Future<FakeApi> prepared(WidgetTester tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      await open(tester);
      await write(tester, 'resources_who', 'Ana Gómez');
      return api;
    }

    Future<void> fill(WidgetTester tester, {String id = 'AMB-09', String label = 'Ambulancia nueva', String lat = '5.0689', String lon = '-75.5174'}) async {
      await write(tester, 'unit_new_id', id);
      await write(tester, 'unit_new_label', label);
      await write(tester, 'unit_new_lat', lat);
      await write(tester, 'unit_new_lon', lon);
    }

    testWidgets('con todo bien se declara (sin reemplazos) y aparece en la lista', (tester) async {
      final api = await prepared(tester);
      await fill(tester);
      await tapKey(tester, 'unit_new_add');
      final c = api.of('declareResource').single.args;
      expect((c['id'], c['kind'], c['label'], c['lat'], c['lon'], c['available'], c['who']), ('AMB-09', 'ambulancia', 'Ambulancia nueva', 5.0689, -75.5174, true, 'Ana Gómez'));
      expect(c['supersedes'], isEmpty);
      expect(find.byKey(const Key('unit_AMB-09')), findsOneWidget);
    });

    testWidgets('acepta coma decimal', (tester) async {
      final api = await prepared(tester);
      await fill(tester, lat: '5,0689', lon: '-75,5174');
      await tapKey(tester, 'unit_new_add');
      expect(api.of('declareResource').single.args['lat'], 5.0689);
    });

    testWidgets('lo mal puesto se dice y NO se envía: id con espacios, etiqueta vacía, ubicación fuera de rango o no numérica', (tester) async {
      final api = await prepared(tester);
      for (final bad in [
        {'id': 'con espacio'},
        {'id': ''},
        {'id': 'X' * 25},
        {'label': ''},
        {'label': 'x' * 81},
        {'lat': '91'},
        {'lon': '-181'},
        {'lat': 'abc'},
        {'lon': ''},
        {'lat': 'NaN'},
      ]) {
        await fill(tester, id: bad['id'] ?? 'AMB-09', label: bad['label'] ?? 'Ambulancia', lat: bad['lat'] ?? '5.0', lon: bad['lon'] ?? '-75.0');
        await tapKey(tester, 'unit_new_add');
        expect(find.byKey(const Key('unit_new_error')), findsOneWidget, reason: '$bad');
        expect(api.of('declareResource'), isEmpty, reason: '$bad');
      }
    });

    testWidgets('un identificador que YA existe se rechaza con el motivo (para cambiarla se usa su interruptor)', (tester) async {
      final api = await prepared(tester);
      await fill(tester, id: 'AMB-01');
      await tapKey(tester, 'unit_new_add');
      expect(tester.widget<Text>(find.byKey(const Key('unit_new_error'))).data, contains('ya existe'));
      expect(api.of('declareResource'), isEmpty);
    });
  });

  group('cuando el nodo no acepta o no responde', () {
    testWidgets('un rechazo se muestra con su motivo y la lista NO cambia', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      api.failDeclare = const ApiException(400, 'lat debe ser un número');
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.descendant(of: find.byKey(const Key('resources_error')), matching: find.textContaining('lat debe ser un número')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('unit_AMB-01')), matching: find.text('Disponible')), findsOneWidget);
    });

    testWidgets('si el código ya no vale, lo dice (no finge que se declaró)', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      api.failDeclare = const AccessDenied();
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.descendant(of: find.byKey(const Key('resources_error')), matching: find.textContaining('código')), findsOneWidget);
    });

    testWidgets('sin conexión: dice que NO quedó declarada', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      api.failDeclare = Exception('ClientException: sin red');
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.descendant(of: find.byKey(const Key('resources_error')), matching: find.textContaining('NO quedó')), findsOneWidget);
    });
  });

  group('declaración aceptada pero relectura fallida', () {
    testWidgets('NO dice «no quedó declarada» (sí quedó): avisa de que la lista se actualizará', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      api.failResourcesAfterDeclare = true;
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(api.of('declareResource'), hasLength(1));
      final said = tester.widget<Text>(find.descendant(of: find.byKey(const Key('resources_notice')), matching: find.byType(Text)).first).data!;
      expect(said, contains('SÍ quedó declarada'));
      expect(said, isNot(contains('NO quedó')));
      expect(find.byKey(const Key('resources_error')), findsNothing);
    });
  });

  group('el aviso de relectura', () {
    testWidgets('desaparece en cuanto una declaración siguiente sí se puede releer', (tester) async {
      final api = await boot(tester, units: [unit('AMB-01')]);
      api.failResourcesAfterDeclare = true;
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.byKey(const Key('resources_notice')), findsOneWidget);
      api.failResourcesAfterDeclare = false;
      await tapKey(tester, 'unit_toggle_AMB-01');
      expect(find.byKey(const Key('resources_notice')), findsNothing);
    });
  });

  group('en la pantalla', () {
    testWidgets('si el nodo rechaza el código al leer los recursos, el tablero se bloquea y no conserva las unidades', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final api = FakeApi()..failResources = const AccessDenied();
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
    });

    testWidgets('al perder el acceso se olvidan las unidades leídas: tras volver a entrar no queda una insignia vieja si la nueva lectura falla', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final api = FakeApi()
        ..requireCode = 'acceso-2026'
        ..units = [unit('AMB-01', conflict: true, available: false, decl: ['A:1', 'B:1'])];
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: const Duration(seconds: 2))));
      await tester.pumpAndSettle();
      Future<void> enter(String code) async {
        await tester.enterText(find.byKey(const Key('access_code')), code);
        await tester.tap(find.byKey(const Key('access_enter')));
        await tester.pumpAndSettle();
      }

      await enter('acceso-2026');
      expect(find.byKey(const Key('resources_conflicts_badge')), findsOneWidget, reason: 'el montaje: con acceso se ve el conflicto');
      api.requireCode = 'rotado-2027';
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      api.failResources = const ApiException(500, 'caído');
      await enter('rotado-2027');
      expect(find.byKey(const Key('counters')), findsOneWidget);
      expect(find.byKey(const Key('resources_conflicts_badge')), findsNothing);
    });

    testWidgets('el botón avisa de los conflictos sin resolver (para que no pasen desapercibidos con el panel cerrado)', (tester) async {
      await boot(tester, units: [unit('AMB-01', conflict: true, available: false, decl: ['A:1', 'B:1']), unit('AMB-02'), unit('BOM-01', kind: 'bomberos', conflict: true, available: false, decl: ['A:2', 'B:2'])]);
      expect(find.descendant(of: find.byKey(const Key('resources_open')), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('sin conflictos no hay insignia', (tester) async {
      await boot(tester, units: [unit('AMB-01')]);
      expect(find.byKey(const Key('resources_conflicts_badge')), findsNothing);
    });

    testWidgets('si el nodo (anterior) no tiene /api/resources, el tablero sigue funcionando y el botón no estorba', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final api = FakeApi()..failResources = const ApiException(404, 'no existe');
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('counters')), findsOneWidget);
    });

    testWidgets('en el modo Mapa se ven las unidades que el nodo declara (la capa llega desde la pantalla)', (tester) async {
      await boot(tester, units: [unit('AMB-01', label: 'Ambulancia 1', lat: 5.0690, lon: -75.5140), unit('AMB-02', label: 'Ambulancia 2', available: false, lat: 5.0660, lon: -75.5100)]);
      await tester.tap(find.byKey(const Key('view_map')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map_unit_AMB-01')), findsOneWidget);
      expect(find.byKey(const Key('map_unit_AMB-02')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('map_units_caption'))).data, 'Unidades: 2 en el mapa');
    });

    testWidgets('cambiar una unidad en el panel se refleja al cerrarlo: el mapa muestra su nuevo estado', (tester) async {
      await boot(tester, units: [unit('AMB-01', label: 'Ambulancia 1', lat: 5.0690, lon: -75.5140)]);
      await tester.tap(find.byKey(const Key('view_map')));
      await tester.pumpAndSettle();
      expect(tester.widget<Tooltip>(find.byKey(const Key('map_unit_tip_AMB-01'))).message, 'Ambulancia 1 · Disponible');
      await open(tester);
      await write(tester, 'resources_who', 'Ana');
      await tapKey(tester, 'unit_toggle_AMB-01');
      await tester.tap(find.byKey(const Key('resources_close')));
      await tester.pumpAndSettle();
      expect(tester.widget<Tooltip>(find.byKey(const Key('map_unit_tip_AMB-01'))).message, 'Ambulancia 1 · No disponible');
    });

    testWidgets('con 360 px el botón es un icono y no desborda la barra', (tester) async {
      await boot(tester, units: [unit('AMB-01', conflict: true, available: false, decl: ['A:1', 'B:1'])], size: const Size(360, 800));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('resources_open')), findsOneWidget);
    });
  });
}
