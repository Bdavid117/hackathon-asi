import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/incident_map.dart';
import 'package:sard_dashboard/models.dart';
import 'package:sard_dashboard/theme.dart';

import 'incident_map_test.dart' show mk, kLat, kLon, kMetersPerDegLat;

const int nowMs = 1800000000000;

/// Una zona en silencio a [north]/[east] metros del centro de Manizales; calló hace [minutes] minutos.
SilentZone zone(String id, {double north = 0, double east = 0, int total = 3, int urgent = 0, int minutes = 47}) =>
    SilentZone(id: id, lat: kLat + north / kMetersPerDegLat, lon: kLon + east / (kMetersPerDegLat * 0.99643), total: total, urgent: urgent, lastAtMs: nowMs - minutes * 60 * 1000);

CoverageInfo info(List<SilentZone> cells, {int? silentTotal, int withoutLocation = 0, int activeCells = 2}) => CoverageInfo(
  cells: cells,
  silentTotal: silentTotal ?? cells.length,
  activeCells: activeCells,
  reportsInWindow: 20,
  withoutLocation: withoutLocation,
  nowMs: nowMs,
  cellDeg: 0.005,
  activity: const Duration(hours: 6),
  silence: const Duration(minutes: 30),
);

Future<void> pump(WidgetTester t, {required List<IncidentRow> rows, SilenceLayer? silence, void Function(String id)? onSelect, Size size = const Size(800, 560)}) async {
  await t.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      theme: dashTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: IncidentMap(rows: rows, selected: null, onSelect: onSelect ?? (_) {}, totalIncidents: rows.length, silence: silence)),
        ),
      ),
    ),
  );
  await t.pump();
}

String caption(WidgetTester t) => t.widget<Text>(find.byKey(const Key('map_silence_caption'))).data!;
String status(WidgetTester t) => t.widget<Text>(find.byKey(const Key('map_status'))).data!;

void main() {
  final rows = [mk('a', 'P1'), mk('b', 'P3', north: 2000, east: 1500)];

  testWidgets('sin capa de silencio (un tablero que no la pasa) el mapa es el de siempre: ni interruptor ni rótulo', (t) async {
    await pump(t, rows: rows);
    expect(find.byKey(const Key('map_silence_toggle')), findsNothing);
    expect(find.byKey(const Key('map_silence_caption')), findsNothing);
  });

  testWidgets('con el interruptor APAGADO está el interruptor pero no hay zonas ni rótulo, y nada se dibuja', (t) async {
    var toggles = 0;
    await pump(t, rows: rows, silence: SilenceLayer(on: false, info: info([zone('z1')]), onToggle: () => toggles++));
    expect(find.byKey(const Key('map_silence_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('map_silence_z1')), findsNothing);
    expect(find.byKey(const Key('map_silence_caption')), findsNothing);
    await t.tap(find.byKey(const Key('map_silence_toggle')));
    expect(toggles, 1);
  });

  testWidgets('encendido: dibuja las zonas dentro de la vista, cuenta las de fuera y dice que el silencio no es seguridad', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('dentro', north: 300, east: 200), zone('lejos', north: 20000, east: 20000)]), onToggle: () {}));
    expect(find.byKey(const ValueKey('map_silence_dentro')), findsOneWidget);
    expect(find.byKey(const ValueKey('map_silence_lejos')), findsNothing, reason: 'fuera del encuadre no se dibuja…');
    expect(caption(t), contains('2 zonas en silencio'));
    expect(caption(t), contains('1 fuera de la vista'), reason: '…pero se cuenta');
    expect(caption(t), contains('El silencio no es seguridad'));
  });

  testWidgets('cero zonas: lo dice, y tampoco entonces afirma que todo esté bien', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info(const [], activeCells: 5), onToggle: () {}));
    expect(caption(t), contains('0 zonas en silencio'));
    expect(caption(t), contains('El silencio no es seguridad'));
    expect(caption(t).toLowerCase(), isNot(contains('todo en calma')));
  });

  testWidgets('singular; el tope del nodo (se dibujan menos de las que hay) y los reportes sin ubicación se dicen', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1')], silentTotal: 1), onToggle: () {}));
    expect(caption(t), contains('1 zona en silencio'));
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1'), zone('z2', north: 100)], silentTotal: 430, withoutLocation: 1), onToggle: () {}));
    expect(caption(t), contains('430 zonas en silencio'));
    expect(caption(t), contains('se dibujan las 2 más urgentes'));
    expect(caption(t), contains('1 reporte sin ubicación no entra'));
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1')], withoutLocation: 7), onToggle: () {}));
    expect(caption(t), contains('7 reportes sin ubicación no entran'));
  });

  testWidgets('la nota (leyendo, nodo anterior, fallo) se muestra y NO se afirma un recuento que no se tiene', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, note: 'Este nodo no calcula las zonas en silencio.', onToggle: () {}));
    expect(caption(t), contains('Este nodo no calcula las zonas en silencio.'));
    expect(caption(t), isNot(contains('zonas en silencio ·')));
    expect(caption(t), isNot(contains('0 zonas')));
    // Con una lectura vieja y un fallo al actualizar: se ven las dos cosas.
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1')]), note: 'No se pudo actualizar; se muestra la última lectura.', onToggle: () {}));
    expect(caption(t), contains('1 zona en silencio'));
    expect(caption(t), contains('No se pudo actualizar'));
    expect(find.byKey(const ValueKey('map_silence_z1')), findsOneWidget);
  });

  testWidgets('la capa NO captura toques: un P1 dentro de una zona en silencio se puede elegir', (t) async {
    final picked = <String>[];
    await pump(t, rows: rows, onSelect: picked.add, silence: SilenceLayer(on: true, info: info([zone('encima', total: 9, urgent: 4)]), onToggle: () {}));
    await t.tap(find.byKey(const ValueKey('map_marker_a')));
    expect(picked, ['a']);
  });

  testWidgets('la capa no toma ni un solo toque: ninguna zona aparece en la ruta de impacto de la pantalla', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1', north: 300, east: 200)]), onToggle: () {}));
    final paint = t.renderObject(find.descendant(of: find.byKey(const ValueKey('map_silence_z1')), matching: find.byType(CustomPaint)));
    final center = t.getCenter(find.byKey(const ValueKey('map_silence_z1')));
    final targets = t.hitTestOnBinding(center).path.map((e) => e.target);
    expect(targets, isNot(contains(paint)), reason: 'si una zona recibiera toques taparía lo que haya debajo');
  });

  testWidgets('con un encuadre muy abierto una zona no se vuelve un punto invisible: mide al menos 8 px', (t) async {
    final wide = [mk('a', 'P1'), mk('b', 'P3', north: 100000)];
    await pump(t, rows: wide, silence: SilenceLayer(on: true, info: info([zone('z1')]), onToggle: () {}));
    final size = t.getSize(find.byKey(const ValueKey('map_silence_z1')));
    expect(size.width, greaterThanOrEqualTo(8));
    expect(size.height, greaterThanOrEqualTo(8));
  });

  testWidgets('encender la capa no mueve nada: marcadores, estado y franja miden lo mismo con la capa encendida o apagada', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: false, info: info([zone('z1'), zone('z2', north: 500)], withoutLocation: 3), onToggle: () {}));
    final off = (t.getCenter(find.byKey(const ValueKey('map_marker_a'))), t.getRect(find.byKey(const Key('map_status'))), t.getRect(find.byKey(const Key('map_silence_toggle'))));
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1'), zone('z2', north: 500)], withoutLocation: 3), onToggle: () {}));
    expect(t.getCenter(find.byKey(const ValueKey('map_marker_a'))), off.$1, reason: 'el marcador no se mueve bajo el dedo');
    expect(t.getRect(find.byKey(const Key('map_status'))), off.$2, reason: 'el estado de los incidentes conserva su sitio');
    expect(t.getRect(find.byKey(const Key('map_silence_toggle'))), off.$3, reason: 'la franja mide lo mismo encendida o apagada');
    expect(status(t), contains('en el mapa'));
  });

  testWidgets('el rótulo empieza por el aviso (si se recorta se pierde un detalle, no la advertencia)', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1')], silentTotal: 430, withoutLocation: 12), onToggle: () {}));
    expect(caption(t), startsWith('El silencio no es seguridad.'));
  });

  testWidgets('el rótulo y el interruptor quedan FUERA del lienzo: no tapan ningún incidente', (t) async {
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1')], silentTotal: 430, withoutLocation: 12), onToggle: () {}));
    final cap = t.getRect(find.byKey(const Key('map_silence_caption')));
    final toggle = t.getRect(find.byKey(const Key('map_silence_toggle')));
    for (final id in ['a', 'b']) {
      final marker = t.getRect(find.byKey(ValueKey('map_marker_$id')));
      expect(cap.overlaps(marker), isFalse, reason: 'el rótulo no cubre el incidente $id');
      expect(toggle.overlaps(marker), isFalse, reason: 'el interruptor no cubre el incidente $id');
    }
  });

  testWidgets('una zona dice, para quien no la ve, cuántos reportes tuvo, cuánto hace que calló y que el silencio no es seguridad', (t) async {
    final handle = t.ensureSemantics();
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info([zone('z1', total: 5, urgent: 2, minutes: 47)]), onToggle: () {}));
    final label = t.getSemantics(find.byKey(const ValueKey('map_silence_z1'))).label;
    expect(label, contains('5 reportes'));
    expect(label, contains('2 urgentes'));
    expect(label, contains('hace 47 min'));
    expect(label, contains('no es seguridad'));
    handle.dispose();
  });

  testWidgets('el interruptor es accesible: dice si está encendido y qué hace', (t) async {
    final handle = t.ensureSemantics();
    await pump(t, rows: rows, silence: SilenceLayer(on: true, info: info(const []), onToggle: () {}));
    final s = t.getSemantics(find.byKey(const Key('map_silence_toggle')));
    expect(s.label, contains('silencio'));
    expect(s.flagsCollection.isToggled, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('en 360 px de ancho no desborda, ni encendida ni apagada, y el texto cabe en la franja', (t) async {
    for (final on in [true, false]) {
      await pump(t, rows: rows, size: const Size(360, 640), silence: SilenceLayer(on: on, info: info([zone('z1')], silentTotal: 430, withoutLocation: 12), onToggle: () {}));
      expect(t.takeException(), isNull, reason: 'on=$on');
    }
    await pump(t, rows: rows, size: const Size(360, 640), silence: SilenceLayer(on: true, info: info([zone('z1')], silentTotal: 430, withoutLocation: 12), onToggle: () {}));
    final cap = t.getRect(find.byKey(const Key('map_silence_caption')));
    expect(cap.right, lessThanOrEqualTo(t.getRect(find.byType(IncidentMap)).right), reason: 'el texto no se sale del ancho');
    expect(cap.height, lessThanOrEqualTo(52));
  });
}
