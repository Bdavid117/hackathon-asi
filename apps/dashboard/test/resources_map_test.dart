import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/incident_map.dart';
import 'package:sard_dashboard/models.dart';
import 'package:sard_dashboard/theme.dart';

import 'incident_map_test.dart' show mk, kLat, kLon, kMetersPerDegLat;

ResourceUnit unit(String id, {double north = 0, double east = 0, bool available = true, bool conflict = false, String kind = 'ambulancia', String label = 'Unidad'}) =>
    ResourceUnit(id: id, kind: kind, label: label, lat: kLat + north / kMetersPerDegLat, lon: kLon + east / (kMetersPerDegLat * 0.99643), available: available, conflict: conflict);

Future<void> pump(WidgetTester t, {required List<IncidentRow> rows, List<ResourceUnit> resources = const [], Size size = const Size(800, 560)}) async {
  await t.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      theme: dashTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: IncidentMap(rows: rows, selected: null, onSelect: (_) {}, totalIncidents: rows.length, resources: resources)),
        ),
      ),
    ),
  );
  await t.pump();
}

String status(WidgetTester t) => t.widget<Text>(find.byKey(const Key('map_status'))).data!;
/// ¿Hay un IgnorePointer ACTIVO entre el rótulo y el lienzo?
bool isIgnoringPointer(Finder ignoring) => ignoring.evaluate().any((e) => (e.widget as IgnorePointer).ignoring);
String caption(WidgetTester t) => t.widget<Text>(find.byKey(const Key('map_units_caption'))).data!;

void main() {
  // Dos incidentes separados ≈ 2 km: el encuadre los abarca con holgura.
  final rows = [mk('a', 'P1'), mk('b', 'P3', north: 2000, east: 1500)];

  testWidgets('sin recursos el mapa es el de siempre: ninguna unidad dibujada y el estado no los menciona', (t) async {
    await pump(t, rows: rows);
    expect(find.byKey(const ValueKey('map_unit_AMB-01')), findsNothing);
    expect(status(t), isNot(contains('unidad')));
    expect(find.byKey(const Key('map_units_caption')), findsNothing);
  });

  testWidgets('cada unidad dentro del encuadre se dibuja, con su nombre y su estado a mano', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200, label: 'Ambulancia 1'), unit('BOM-01', north: 900, east: 700, kind: 'bomberos', available: false, label: 'Bomberos 1')]);
    expect(find.byKey(const Key('map_unit_AMB-01')), findsOneWidget);
    expect(find.byKey(const Key('map_unit_BOM-01')), findsOneWidget);
    expect(t.widget<Tooltip>(find.byKey(const Key('map_unit_tip_AMB-01'))).message, 'Ambulancia 1 · Disponible');
    expect(t.widget<Tooltip>(find.byKey(const Key('map_unit_tip_BOM-01'))).message, 'Bomberos 1 · No disponible');
  });

  testWidgets('una unidad NO disponible se ve hueca y una disponible, rellena (no sólo cambia el color del borde)', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200), unit('AMB-02', north: 500, east: 100, available: false)]);
    Color? fill(String id) => ((t.widget<Container>(find.descendant(of: find.byKey(Key('map_unit_tip_$id')), matching: find.byType(Container)).first).decoration) as BoxDecoration).color;
    expect(fill('AMB-01'), isNot(DashColors.surface));
    expect(fill('AMB-02'), DashColors.surface);
  });

  testWidgets('el rótulo de unidades no captura toques (no tapa a un incidente que quede debajo)', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200)]);
    final ignoring = find.ancestor(of: find.byKey(const Key('map_units_caption')), matching: find.byType(IgnorePointer));
    expect(isIgnoringPointer(ignoring), isTrue);
  });

  testWidgets('un conflicto se dice en la etiqueta: la unidad no se ofrece', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200, label: 'Ambulancia 1', available: false, conflict: true)]);
    expect(t.widget<Tooltip>(find.byKey(const Key('map_unit_tip_AMB-01'))).message, 'Ambulancia 1 · En conflicto: no se ofrece');
  });

  testWidgets('las unidades fuera de la vista NO se dibujan, y el rótulo dice cuántas hay dentro y cuántas fuera', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200), unit('AMB-02', north: 90000, east: 0)]);
    expect(find.byKey(const Key('map_unit_AMB-01')), findsOneWidget);
    expect(find.byKey(const Key('map_unit_AMB-02')), findsNothing);
    expect(caption(t), 'Unidades: 1 en el mapa · 1 fuera de la vista');
    expect(status(t), isNot(contains('unidad')), reason: 'el estado de los incidentes no se mezcla con el de las unidades');
  });

  testWidgets('sin ninguna fuera no se menciona lo de fuera', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200), unit('AMB-02', north: 500, east: 100)]);
    expect(caption(t), 'Unidades: 2 en el mapa', reason: 'si no hay ninguna fuera, no se menciona');
  });

  testWidgets('NO estorba a los incidentes: tocar el marcador que cae sobre una unidad elige el INCIDENTE', (t) async {
    final picked = <String>[];
    await t.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: dashTheme(),
        home: Scaffold(body: SizedBox(width: 800, height: 560, child: IncidentMap(rows: rows, selected: null, onSelect: picked.add, totalIncidents: 2, resources: [unit('AMB-01')]))),
      ),
    );
    await t.pump();
    expect(t.getRect(find.byKey(const Key('map_marker_a'))).overlaps(t.getRect(find.byKey(const Key('map_unit_AMB-01')))), isTrue, reason: 'el montaje: están en el mismo punto');
    await t.tapAt(t.getCenter(find.byKey(const Key('map_unit_AMB-01'))));
    expect(picked, ['a']);
  });

  testWidgets('con unidades el estado no cambia el tamaño del lienzo (la franja de estado mide siempre lo mismo)', (t) async {
    await pump(t, rows: rows);
    final before = t.getSize(find.byKey(const Key('map_marker_a')));
    final canvasBefore = t.getSize(find.byType(CustomPaint).first);
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200)]);
    expect(t.getSize(find.byKey(const Key('map_marker_a'))), before);
    expect(t.getSize(find.byType(CustomPaint).first), canvasBefore);
  });

  testWidgets('con 360 px de ancho no desborda', (t) async {
    await pump(t, rows: rows, resources: [unit('AMB-01', north: 300, east: 200), unit('BOM-01', north: 90000)], size: const Size(360, 560));
    expect(t.takeException(), isNull);
  });
}
