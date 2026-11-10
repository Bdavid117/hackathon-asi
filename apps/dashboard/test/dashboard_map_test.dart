import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/incident_map.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

const String a1 = '00000000000000a1-1'; // P1, con ubicación
const String c1 = '00000000000000c1-1'; // P2, SIN ubicación
const String b1 = '00000000000000b1-1'; // P3, con ubicación

void main() {
  Future<void> boot(WidgetTester tester, FakeApi api, {Duration? every, Size size = const Size(1280, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
    await tester.pumpAndSettle();
  }

  Future<void> openMap(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('view_map')));
    await tester.pumpAndSettle();
  }

  group('el selector Lista | Mapa', () {
    testWidgets('por omisión se ve la lista, y el mapa está a un toque', (tester) async {
      await boot(tester, FakeApi());
      expect(find.byKey(const Key('incident_list')), findsOneWidget);
      expect(find.byType(IncidentMap), findsNothing);
      expect(find.byKey(const Key('view_list')), findsOneWidget);
      expect(find.byKey(const Key('view_map')), findsOneWidget);
    });

    testWidgets('el mapa reemplaza la lista y pone un marcador por incidente con ubicación', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      expect(find.byKey(const Key('incident_list')), findsNothing);
      expect(find.byType(IncidentMap), findsOneWidget);
      expect(find.byKey(const Key('map_marker_$a1')), findsOneWidget);
      expect(find.byKey(const Key('map_marker_$b1')), findsOneWidget);
    });

    testWidgets('lo que no tiene ubicación no desaparece al pasar al mapa: queda listado', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      expect(find.byKey(const Key('map_marker_$c1')), findsNothing);
      expect(find.byKey(const Key('map_unlocated_$c1')), findsOneWidget);
    });

    testWidgets('el mapa no finge ser el total: dice cuántos más hay en la lista completa', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      // el nodo tiene 8 incidentes y la vista corta trae 5: los otros 3 son los «SOS sin detalle», que no tienen ubicación
      expect(tester.widget<Text>(find.byKey(const Key('map_status'))).data, endsWith('· 3 más en la lista completa'));
    });

    testWidgets('volver a la lista la devuelve tal cual', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      await tester.tap(find.byKey(const Key('view_list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_list')), findsOneWidget);
      expect(find.byType(IncidentMap), findsNothing);
    });
  });

  group('elegir en el mapa es elegir en el tablero', () {
    testWidgets('tocar un marcador abre el detalle de ese incidente, a la derecha', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      expect(find.byKey(const Key('detail_empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('map_marker_$a1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_empty')), findsNothing);
      expect(find.byType(IncidentDetailView), findsOneWidget);
      expect(find.byKey(const Key('map_selected_$a1')), findsOneWidget, reason: 'el mapa marca el elegido');
    });

    testWidgets('el incidente elegido en el mapa sigue elegido al volver a la lista', (tester) async {
      await boot(tester, FakeApi());
      await openMap(tester);
      await tester.tap(find.byKey(const Key('map_marker_$a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view_list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selected_$a1')), findsOneWidget);
    });

    testWidgets('también se puede elegir uno SIN ubicación desde el mapa', (tester) async {
      await boot(tester, FakeApi(details: {c1: IncidentDetail.fromJson(fixture('detail_fire_no_location.json'))}));
      await openMap(tester);
      await tester.tap(find.byKey(const Key('map_unlocated_$c1')));
      await tester.pumpAndSettle();
      expect(find.byType(IncidentDetailView), findsOneWidget);
    });

    testWidgets('en una pantalla estrecha, elegir en el mapa abre el detalle en otra pantalla', (tester) async {
      await boot(tester, FakeApi(), size: const Size(700, 900));
      await openMap(tester);
      await tester.tap(find.byKey(const Key('map_marker_$a1')));
      await tester.pumpAndSettle();
      expect(find.text('Incidente'), findsOneWidget, reason: 'la barra de la pantalla de detalle');
      expect(find.byType(IncidentDetailView), findsOneWidget);
    });
  });

  group('el selector en una pantalla estrecha y al cambiar de vista', () {
    testWidgets('con 360 px de ancho el selector sigue disponible, encima del contenido, y nada se desborda', (tester) async {
      await boot(tester, FakeApi(), size: const Size(360, 800));
      expect(find.byKey(const Key('view_map')), findsOneWidget);
      await openMap(tester);
      expect(find.byType(IncidentMap), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('al pasar a «Ver todo» el mapa se encuadra de nuevo para la vista nueva', (tester) async {
      final j = fixture('incidents_all.json');
      final items = (j['items']! as List).cast<Map<String, Object?>>();
      final withLocation = items.firstWhere((i) => i['lat'] != null);
      // un incidente a ≈ 33 km al norte: sólo está en la vista completa y cae fuera del encuadre de la corta
      final far = {...withLocation, 'id': '00000000000000ff-1', 'lat': (withLocation['lat']! as num) + 0.3};
      final api = FakeApi(all: IncidentsPage.fromJson({...j, 'items': [...items, far]}));
      await boot(tester, api);
      await openMap(tester);
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map_marker_00000000000000ff-1')), findsOneWidget, reason: 'la vista completa trae un mapa encuadrado para ella');
      expect(tester.widget<Text>(find.byKey(const Key('map_status'))).data, contains('0 fuera de la vista'));
    });
  });

  group('con datos que llegan cada 2 s, el mapa no se mueve bajo el dedo', () {
    testWidgets('un incidente nuevo dentro de lo encuadrado no mueve los marcadores que ya estaban', (tester) async {
      final j = fixture('incidents_short.json');
      final api = FakeApi();
      await boot(tester, api, every: const Duration(seconds: 2));
      await openMap(tester);
      final before = tester.getCenter(find.byKey(const Key('map_marker_$a1')));
      final beforeB = tester.getCenter(find.byKey(const Key('map_marker_$b1')));

      // llega uno nuevo, justo entre los que ya estaban
      final items = (j['items']! as List).cast<Map<String, Object?>>();
      final src = items.firstWhere((i) => i['id'] == b1);
      final fresh = {...src, 'id': '00000000000000e9-1', 'urgency': 'P2', 'lat': ((src['lat']! as num) + (items.first['lat']! as num)) / 2, 'lon': ((src['lon']! as num) + (items.first['lon']! as num)) / 2};
      api.short = IncidentsPage.fromJson({...j, 'items': [...items, fresh]});
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(find.byKey(const Key('map_marker_00000000000000e9-1')), findsOneWidget, reason: 'el nuevo se dibuja');
      expect(tester.getCenter(find.byKey(const Key('map_marker_$a1'))), before);
      expect(tester.getCenter(find.byKey(const Key('map_marker_$b1'))), beforeB);
    });
  });
}
