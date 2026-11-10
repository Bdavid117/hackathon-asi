import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

const String a1 = '00000000000000a1-1'; // P1, con ubicación

const int nowMs = 1786371100 * 1000;

void main() {
  /// Una zona en silencio justo donde está el incidente a1 (así cae dentro del encuadre).
  SilentZone zoneAtA1(FakeApi api, {String id = 'z-a1'}) {
    final row = api.short.items.firstWhere((r) => r.id == a1);
    return SilentZone(id: id, lat: row.lat!, lon: row.lon!, total: 4, urgent: 1, lastAtMs: nowMs - 47 * 60 * 1000);
  }

  CoverageInfo infoWith(List<SilentZone> cells, {int withoutLocation = 0}) => CoverageInfo(
    cells: cells,
    silentTotal: cells.length,
    activeCells: 2,
    reportsInWindow: 12,
    withoutLocation: withoutLocation,
    nowMs: nowMs,
    cellDeg: 0.005,
    activity: const Duration(hours: 6),
    silence: const Duration(minutes: 30),
  );

  Future<void> boot(WidgetTester tester, FakeApi api, {Duration? every, Size size = const Size(1280, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs))));
    await tester.pumpAndSettle();
  }

  Future<void> openMap(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('view_map')));
    await tester.pumpAndSettle();
  }

  Future<void> toggle(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('map_silence_toggle')));
    await tester.pumpAndSettle();
  }

  /// Tras volver a entrar el tablero abre en la lista: se pasa al mapa si hace falta.
  Future<void> openMapIfNeeded(WidgetTester tester) async {
    if (find.byKey(const Key('map_silence_toggle')).evaluate().isEmpty && find.byKey(const Key('view_map')).evaluate().isNotEmpty) await tester.tap(find.byKey(const Key('view_map')));
    await tester.pump();
  }

  int coverageCalls(FakeApi api) => api.calls.where((c) => c.name == 'coverage').length;
  String caption(WidgetTester t) => t.widget<Text>(find.byKey(const Key('map_silence_caption'))).data!;

  group('la capa de silencio en el tablero', () {
    testWidgets('apagada (por omisión) NO cuesta red: ni en la lista ni en el mapa se pide la cobertura', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      await boot(tester, api, every: const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 3));
      await openMap(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('map_silence_toggle')), findsOneWidget);
      expect(find.byKey(const Key('map_silence_caption')), findsNothing);
      expect(coverageCalls(api), 0);
    });

    testWidgets('al encenderla se lee una vez y se dibujan las zonas con su rótulo', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)], withoutLocation: 2);
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(coverageCalls(api), 1);
      expect(find.byKey(const ValueKey('map_silence_z-a1')), findsOneWidget);
      expect(caption(tester), contains('1 zona en silencio'));
      expect(caption(tester), contains('2 reportes sin ubicación no entran'));
      expect(caption(tester), contains('El silencio no es seguridad'));
      expect(find.byKey(const Key('map_marker_$a1')), findsOneWidget, reason: 'el incidente sigue ahí, encima de la zona');
    });

    testWidgets('con la capa encendida se vuelve a leer en cada refresco del mapa, y al apagarla deja de pedirse y de dibujarse', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      await boot(tester, api, every: const Duration(seconds: 1));
      await openMap(tester);
      await toggle(tester);
      final first = coverageCalls(api);
      await tester.pump(const Duration(seconds: 2));
      expect(coverageCalls(api), greaterThan(first), reason: 'encendida, se mantiene al día');
      await toggle(tester);
      final off = coverageCalls(api);
      await tester.pump(const Duration(seconds: 3));
      expect(coverageCalls(api), off, reason: 'apagada no cuesta red');
      expect(find.byKey(const ValueKey('map_silence_z-a1')), findsNothing);
      expect(find.byKey(const Key('map_silence_caption')), findsNothing);
    });

    testWidgets('en la vista de lista (aunque la capa siga encendida) no se pide: la lectura sólo sirve al mapa', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      await boot(tester, api, every: const Duration(seconds: 1));
      await openMap(tester);
      await toggle(tester);
      await tester.tap(find.byKey(const Key('view_list')));
      await tester.pumpAndSettle();
      final before = coverageCalls(api);
      await tester.pump(const Duration(seconds: 3));
      expect(coverageCalls(api), before);
    });

    testWidgets('al apagar y volver a encender no se enseña una lectura vieja: se vuelve a leer', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'vieja')]);
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(find.byKey(const ValueKey('map_silence_vieja')), findsOneWidget);
      await toggle(tester);
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'nueva')]);
      await toggle(tester);
      expect(find.byKey(const ValueKey('map_silence_nueva')), findsOneWidget);
      expect(find.byKey(const ValueKey('map_silence_vieja')), findsNothing);
      expect(coverageCalls(api), 2);
    });

    testWidgets('mientras una lectura tarda no se pide otra encima (una sola en vuelo)', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      api.holdCoverage = Completer<void>();
      await boot(tester, api, every: const Duration(seconds: 1));
      await openMap(tester);
      await tester.tap(find.byKey(const Key('map_silence_toggle')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(coverageCalls(api), 1, reason: 'sigue en vuelo');
      expect(caption(tester), contains('Leyendo el silencio'));
      api.holdCoverage!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map_silence_z-a1')), findsOneWidget);
    });

    testWidgets('al apagarla se olvida lo leído: al encenderla otra vez NO se enseña la lectura vieja mientras llega la nueva', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'vieja')]);
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(find.byKey(const ValueKey('map_silence_vieja')), findsOneWidget);
      await toggle(tester); // apagar
      api.holdCoverage = Completer<void>();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'nueva')]);
      await tester.tap(find.byKey(const Key('map_silence_toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('map_silence_vieja')), findsNothing, reason: 'una lectura de antes de apagar ya no vale');
      expect(caption(tester), contains('Leyendo el silencio'));
      api.holdCoverage!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map_silence_nueva')), findsOneWidget);
    });

    testWidgets('una lectura que llega DESPUÉS de apagar se tira: no reaparece al volver a encender', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'tardia')]);
      api.holdCoverage = Completer<void>();
      await boot(tester, api);
      await openMap(tester);
      await tester.tap(find.byKey(const Key('map_silence_toggle')));
      await tester.pump(); // pide y queda esperando
      await tester.tap(find.byKey(const Key('map_silence_toggle'))); // apagar con la lectura en vuelo
      await tester.pump();
      api.holdCoverage!.complete(); // llega apagada
      await tester.pumpAndSettle();
      api.holdCoverage = Completer<void>();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'fresca')]);
      await tester.tap(find.byKey(const Key('map_silence_toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('map_silence_tardia')), findsNothing);
      expect(caption(tester), contains('Leyendo el silencio'));
      api.holdCoverage!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map_silence_fresca')), findsOneWidget);
    });

    testWidgets('al volver de la lista al mapa con la capa encendida se lee de nuevo en el acto (no se enseña la de antes de irse)', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      await boot(tester, api); // sin refresco automático: sólo el cambio de vista puede disparar la lectura
      await openMap(tester);
      await toggle(tester);
      await tester.tap(find.byKey(const Key('view_list')));
      await tester.pumpAndSettle();
      final before = coverageCalls(api);
      await openMap(tester);
      expect(coverageCalls(api), before + 1);
    });

    testWidgets('si se pierde el acceso se olvida la lectura: al volver a entrar no reaparece la de antes', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'previa')]);
      await boot(tester, api, every: const Duration(seconds: 1));
      await openMap(tester);
      await toggle(tester);
      expect(find.byKey(const ValueKey('map_silence_previa')), findsOneWidget);
      api.requireCode = 'abc-123';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      api.holdCoverage = Completer<void>();
      api.coverageInfo = infoWith([zoneAtA1(api, id: 'posterior')]);
      await tester.enterText(find.byKey(const Key('access_code')), 'abc-123');
      await tester.tap(find.byKey(const Key('access_enter')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await openMapIfNeeded(tester);
      expect(find.byKey(const ValueKey('map_silence_previa')), findsNothing, reason: 'tras perder el acceso no queda nada de lo leído con el código anterior');
      api.holdCoverage!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('un nodo anterior (sin /api/coverage) no rompe nada: se dice que no las calcula y no se afirma ningún recuento', (tester) async {
      final api = FakeApi(); // coverageInfo == null = el nodo contesta 404
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(caption(tester), contains('Este nodo no calcula las zonas en silencio'));
      expect(caption(tester), isNot(contains('0 zonas')));
      expect(find.byKey(const Key('map_marker_$a1')), findsOneWidget);
    });

    testWidgets('un fallo de red al leer: el mapa sigue funcionando y se dice que no se pudo leer', (tester) async {
      final api = FakeApi();
      api.failCoverage = Exception('sin red');
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(caption(tester), contains('No se pudo leer el silencio'));
      expect(find.byKey(const Key('map_marker_$a1')), findsOneWidget);
    });

    testWidgets('una respuesta mal formada se declara (no se dibuja a medias)', (tester) async {
      final api = FakeApi();
      api.failCoverage = const FormatException('mala');
      await boot(tester, api);
      await openMap(tester);
      await toggle(tester);
      expect(caption(tester), contains('No se pudo leer el silencio'));
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('si falla DESPUÉS de haber leído, se conserva la última lectura y se avisa que no está al día', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)]);
      await boot(tester, api, every: const Duration(seconds: 1));
      await openMap(tester);
      await toggle(tester);
      expect(find.byKey(const ValueKey('map_silence_z-a1')), findsOneWidget);
      api.failCoverage = Exception('sin red');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('map_silence_z-a1')), findsOneWidget);
      expect(caption(tester), contains('No se pudo actualizar'));
      // y se recupera sola
      api.failCoverage = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(caption(tester), isNot(contains('No se pudo actualizar')));
    });

    testWidgets('si el nodo pide el código de acceso (401) el tablero se bloquea como con cualquier otra lectura', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await openMap(tester);
      api.failCoverage = const AccessDenied();
      await toggle(tester);
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      expect(find.byKey(const Key('map_silence_caption')), findsNothing);
    });

    testWidgets('en 360 px el mapa con la capa encendida no desborda', (tester) async {
      final api = FakeApi();
      api.coverageInfo = infoWith([zoneAtA1(api)], withoutLocation: 12);
      await boot(tester, api, size: const Size(360, 780));
      await openMap(tester);
      await toggle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('map_silence_caption')), findsOneWidget);
    });
  });
}
