import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/incident_map.dart';
import 'package:sard_dashboard/models.dart';
import 'package:sard_dashboard/theme.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

const double kLat = 5.0689, kLon = -75.5174;
const double kMetersPerDegLat = 111320.0;

/// Un incidente a [north] / [east] metros del centro de Manizales (o sin ubicación si [located] es falso).
IncidentRow mk(String id, String urgency, {double north = 0, double east = 0, bool located = true, String? quality, List<String> signals = const ['atrapado']}) {
  final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
  return IncidentRow.fromJson({
    ...base,
    'id': id,
    'urgency': urgency,
    'signals': signals,
    'lat': located ? kLat + north / kMetersPerDegLat : null,
    'lon': located ? kLon + east / (kMetersPerDegLat * 0.99643) : null,
    'locQuality': located ? quality : null,
  });
}

Future<void> pumpMap(
  WidgetTester t, {
  required List<IncidentRow> rows,
  String? selected,
  void Function(String id)? onSelect,
  int? total,
  Size size = const Size(800, 560),
}) async {
  await t.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      theme: dashTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: IncidentMap(rows: rows, selected: selected, onSelect: onSelect ?? (_) {}, totalIncidents: total ?? rows.length),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

Finder marker(String id) => find.byKey(Key('map_marker_$id'));

void main() {
  group('un marcador por incidente localizado', () {
    testWidgets('cada incidente con ubicación tiene su marcador con su urgencia escrita; el que no la tiene no lo tiene', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 800, east: 600), mk('c', 'P2', located: false)]);
      expect(marker('a'), findsOneWidget);
      expect(marker('b'), findsOneWidget);
      expect(marker('c'), findsNothing);
      expect(find.descendant(of: marker('a'), matching: find.text('P1')), findsOneWidget);
      expect(find.descendant(of: marker('b'), matching: find.text('P3')), findsOneWidget);
    });

    testWidgets('el norte queda arriba y el este a la derecha', (t) async {
      await pumpMap(t, rows: [mk('c', 'P3'), mk('n', 'P3', north: 1200), mk('e', 'P3', east: 1200)]);
      final c = t.getCenter(marker('c')), n = t.getCenter(marker('n')), e = t.getCenter(marker('e'));
      expect(n.dy, lessThan(c.dy));
      expect(e.dx, greaterThan(c.dx));
    });

    testWidgets('tocar un marcador elige ese incidente', (t) async {
      final picked = <String>[];
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 900, east: 900)], onSelect: picked.add);
      await t.tap(marker('b'));
      expect(picked, ['b']);
    });

    testWidgets('el incidente elegido se distingue en el mapa', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 900, east: 900)], selected: 'b');
      expect(find.byKey(const Key('map_selected_b')), findsOneWidget);
      expect(find.byKey(const Key('map_selected_a')), findsNothing);
    });

    testWidgets('lo lee un lector de pantalla: el marcador dice qué es, su urgencia y la precisión', (t) async {
      final handle = t.ensureSemantics();
      await pumpMap(t, rows: [mk('a', 'P1', quality: 'within200m', signals: const ['atrapado', 'herido'])]);
      expect(find.bySemanticsLabel(RegExp(r'P1.*Atrapado · Herido.*Precisión: unos 200 m')), findsOneWidget);
      handle.dispose();
    });
  });

  group('lo que no tiene ubicación no desaparece', () {
    testWidgets('se listan aparte, con su urgencia, y se pueden elegir', (t) async {
      final picked = <String>[];
      await pumpMap(t, rows: [mk('a', 'P1'), mk('x', 'P2', located: false), mk('y', 'P3', located: false)], onSelect: picked.add);
      expect(find.byKey(const Key('map_unlocated')), findsOneWidget);
      expect(find.byKey(const Key('map_unlocated_x')), findsOneWidget);
      expect(find.byKey(const Key('map_unlocated_y')), findsOneWidget);
      await t.tap(find.byKey(const Key('map_unlocated_x')));
      expect(picked, ['x']);
    });

    testWidgets('si ninguno tiene ubicación lo dice, y siguen estando listados', (t) async {
      await pumpMap(t, rows: [mk('x', 'P2', located: false)]);
      expect(find.byKey(const Key('map_empty')), findsOneWidget);
      expect(find.byKey(const Key('map_unlocated_x')), findsOneWidget);
    });

    testWidgets('la línea de estado cuenta lo que está en el mapa, lo que no tiene ubicación y lo que queda fuera de la vista', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 500), mk('x', 'P2', located: false)]);
      expect(find.byKey(const Key('map_status')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('map_status'))).data, '2 en el mapa · 1 sin ubicación · 0 fuera de la vista');
    });

    testWidgets('si hay más incidentes en el nodo que cargados, lo dice (no finge ser el total)', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 500)], total: 40);
      expect(t.widget<Text>(find.byKey(const Key('map_status'))).data, '2 en el mapa · 0 sin ubicación · 0 fuera de la vista · 38 más en la lista completa');
    });
  });

  group('dos incidentes en el mismo sitio no se tapan', () {
    testWidgets('forman UN marcador con el conteo y el más urgente a la vista', (t) async {
      await pumpMap(t, rows: [mk('a', 'P3'), mk('b', 'P1'), mk('far', 'P3', north: 1500, east: 1500)]);
      // `b` es el más urgente: el marcador del grupo es el de `b`, y `a` no tiene marcador propio.
      expect(marker('b'), findsOneWidget);
      expect(marker('a'), findsNothing);
      expect(find.descendant(of: marker('b'), matching: find.textContaining('P1')), findsOneWidget);
      expect(find.descendant(of: marker('b'), matching: find.textContaining('2')), findsOneWidget);
    });

    testWidgets('un grupo con MUCHOS incidentes cabe en su marcador (no desborda) y dice «99+» si son más de 99', (t) async {
      final many = [for (var i = 0; i < 12; i++) mk('m$i', 'P3'), mk('lejos', 'P3', north: 1500, east: 1500)];
      await pumpMap(t, rows: many);
      expect(t.takeException(), isNull, reason: 'con 12 en el mismo punto el marcador desbordaba');
      expect(find.descendant(of: marker('m0'), matching: find.textContaining('12')), findsOneWidget);
      // y de verdad cabe: sin error de desbordamiento el texto aún podría pintarse FUERA de su pastilla
      final text = t.getRect(find.descendant(of: marker('m0'), matching: find.textContaining('12')));
      final pill = t.getRect(find.descendant(of: marker('m0'), matching: find.byType(Container)).first);
      // dentro de su relleno (8 px + 1,5 de borde por cada lado), no sólo dentro de la pastilla
      expect(text.left, greaterThanOrEqualTo(pill.left + 9.4), reason: 'el texto $text se sale por la izquierda de su pastilla $pill');
      expect(text.right, lessThanOrEqualTo(pill.right - 9.4), reason: 'el texto $text se sale por la derecha de su pastilla $pill');

      final huge = [for (var i = 0; i < 150; i++) mk('h${i.toString().padLeft(3, '0')}', 'P2'), mk('lejos', 'P3', north: 1500, east: 1500)];
      await pumpMap(t, rows: huge);
      expect(t.takeException(), isNull);
      expect(find.descendant(of: marker('h000'), matching: find.textContaining('99+')), findsOneWidget);
    });

    testWidgets('un P1 al lado de un P3 nunca queda escondido', (t) async {
      await pumpMap(t, rows: [mk('p3', 'P3', north: 10), mk('p1', 'P1', north: 12), mk('far', 'P3', north: 2000, east: 2000)]);
      expect(marker('p1'), findsOneWidget);
      expect(find.descendant(of: marker('p1'), matching: find.textContaining('P1')), findsOneWidget);
    });

    testWidgets('tocar el mismo grupo dos veces lo abre y lo cierra', (t) async {
      await pumpMap(t, rows: [mk('a', 'P3'), mk('b', 'P1'), mk('far', 'P3', north: 1500, east: 1500)]);
      await t.tap(marker('b'));
      await t.pump();
      expect(find.byKey(const Key('map_cluster_panel')), findsOneWidget);
      await t.tap(marker('b'), warnIfMissed: false);
      await t.pump();
      expect(find.byKey(const Key('map_cluster_panel')), findsNothing);
    });

    testWidgets('la ventana del grupo no tapa su propio marcador, esté donde esté en el lienzo', (t) async {
      for (final (name, north) in [('arriba', 1800.0), ('en medio', 0.0), ('abajo', -1800.0)]) {
        final rows = [mk('a', 'P3', north: north), mk('b', 'P1', north: north), mk('lejos1', 'P3', north: 2000, east: 2000), mk('lejos2', 'P3', north: -2000, east: -2000)];
        await pumpMap(t, rows: rows);
        await t.tap(marker('b'));
        await t.pump();
        final panel = t.getRect(find.byKey(const Key('map_cluster_panel')));
        final mark = t.getRect(marker('b'));
        expect(panel.overlaps(mark), isFalse, reason: 'con el grupo $name, la ventana $panel tapa su marcador $mark');
        // y el segundo toque SÍ llega al marcador (no a un chip de la ventana): la cierra sin elegir nada
        final picked = <String>[];
        await pumpMap(t, rows: rows, onSelect: picked.add);
        await t.tapAt(t.getCenter(marker('b')));
        await t.pump();
        expect(find.byKey(const Key('map_cluster_panel')), findsNothing, reason: 'con el grupo $name');
        expect(picked, isEmpty, reason: 'con el grupo $name: el toque debía ser al marcador, no a un chip');
      }
    });

    testWidgets('si dos marcadores se solapan sin llegar a agruparse, el más urgente queda ENCIMA y recibe el toque', (t) async {
      // Se busca una separación de ≈ 20 px: fuera del radio de agrupación (14) pero con las cajas de toque solapadas.
      Future<double> gap(double east) async {
        await pumpMap(t, rows: [mk('p3', 'P3'), mk('p1', 'P1', east: east), mk('far', 'P3', north: 2000, east: 2000), mk('far2', 'P3', north: -2000, east: -2000)]);
        return (t.getCenter(marker('p1')) - t.getCenter(marker('p3'))).distance;
      }
      final d1 = await gap(400);
      final east = 400 * 20 / d1;
      final d = await gap(east);
      expect(d, inInclusiveRange(15, 40), reason: 'el montaje del caso: $d px');
      final picked = <String>[];
      await pumpMap(t, rows: [mk('p3', 'P3'), mk('p1', 'P1', east: east), mk('far', 'P3', north: 2000, east: 2000), mk('far2', 'P3', north: -2000, east: -2000)], onSelect: picked.add);
      final mid = (t.getCenter(marker('p1')) + t.getCenter(marker('p3'))) / 2;
      await t.tapAt(mid);
      expect(picked, ['p1'], reason: 'en la zona solapada manda el P1');
    });

    testWidgets('el panel del grupo se cierra sin elegir nada', (t) async {
      final picked = <String>[];
      await pumpMap(t, rows: [mk('a', 'P3'), mk('b', 'P1'), mk('far', 'P3', north: 1500, east: 1500)], onSelect: picked.add);
      await t.tap(marker('b'));
      await t.pump();
      expect(find.byKey(const Key('map_cluster_panel')), findsOneWidget);
      await t.tap(find.byKey(const Key('map_cluster_close')));
      await t.pump();
      expect(find.byKey(const Key('map_cluster_panel')), findsNothing);
      expect(picked, isEmpty);
    });

    testWidgets('tocar el grupo muestra a todos los que hay en ese punto, y se puede elegir cualquiera', (t) async {
      final picked = <String>[];
      await pumpMap(t, rows: [mk('a', 'P3'), mk('b', 'P1'), mk('far', 'P3', north: 1500, east: 1500)], onSelect: picked.add);
      await t.tap(marker('b'));
      await t.pump();
      expect(picked, isEmpty, reason: 'tocar un grupo no elige a ciegas: primero enseña quiénes son');
      expect(find.byKey(const Key('map_cluster_member_a')), findsOneWidget);
      expect(find.byKey(const Key('map_cluster_member_b')), findsOneWidget);
      await t.tap(find.byKey(const Key('map_cluster_member_a')));
      await t.pump();
      expect(picked, ['a']);
      expect(find.byKey(const Key('map_cluster_member_a')), findsNothing, reason: 'al elegir, el panel del grupo se cierra');
    });
  });

  group('el encuadre NO se mueve solo: los datos llegan cada 2 s', () {
    testWidgets('un incidente nuevo dentro de lo encuadrado no mueve a los demás', (t) async {
      final a = mk('a', 'P1'), b = mk('b', 'P3', north: 1000, east: 1000);
      await pumpMap(t, rows: [a, b]);
      final before = t.getCenter(marker('a'));
      await pumpMap(t, rows: [a, b, mk('c', 'P2', north: 400, east: 300)]);
      expect(marker('c'), findsOneWidget);
      expect(t.getCenter(marker('a')), before);
      expect(t.getCenter(marker('b')), t.getCenter(marker('b')));
    });

    testWidgets('uno nuevo FUERA se avisa y no mueve nada; «Reencuadrar» lo trae, a petición', (t) async {
      final a = mk('a', 'P1'), b = mk('b', 'P3', north: 1000, east: 1000);
      await pumpMap(t, rows: [a, b]);
      final before = t.getCenter(marker('a'));
      final far = mk('far', 'P1', north: 30000, east: -25000);
      await pumpMap(t, rows: [a, b, far]);
      expect(t.getCenter(marker('a')), before, reason: 'no se mueve solo');
      expect(marker('far'), findsNothing, reason: 'cae fuera del encuadre: no se dibuja en un sitio falso');
      expect(t.widget<Text>(find.byKey(const Key('map_status'))).data, contains('1 fuera de la vista'));
      expect(find.byKey(const Key('map_reframe')), findsOneWidget);

      await t.tap(find.byKey(const Key('map_reframe')));
      await t.pump();
      expect(marker('far'), findsOneWidget, reason: 'tras reencuadrar, el lejano está a la vista');
      expect(t.getCenter(marker('a')), isNot(before), reason: 'reencuadrar SÍ cambia el encuadre');
      expect(t.widget<Text>(find.byKey(const Key('map_status'))).data, contains('0 fuera de la vista'));
    });

    testWidgets('que aparezca un incidente SIN ubicación no cambia el tamaño del lienzo: nada se mueve', (t) async {
      final a = mk('a', 'P1'), b = mk('b', 'P3', north: 1000, east: 1000);
      await pumpMap(t, rows: [a, b]);
      final before = t.getCenter(marker('a'));
      await pumpMap(t, rows: [a, b, mk('x', 'P2', located: false)]);
      expect(find.byKey(const Key('map_unlocated_x')), findsOneWidget);
      expect(t.getCenter(marker('a')), before);
    });

    testWidgets('abrir un grupo no mueve ningún marcador', (t) async {
      final rows = [mk('a', 'P3'), mk('b', 'P1'), mk('far', 'P3', north: 1500, east: 1500)];
      await pumpMap(t, rows: rows);
      final far = t.getCenter(marker('far')), grp = t.getCenter(marker('b'));
      await t.tap(marker('b'));
      await t.pump();
      expect(find.byKey(const Key('map_cluster_panel')), findsOneWidget);
      expect(t.getCenter(marker('far')), far);
      expect(t.getCenter(marker('b')), grp);
    });

    testWidgets('el aviso de «fuera de la vista» incluye cuántos son P1', (t) async {
      await pumpMap(t, rows: [mk('a', 'P3')]);
      await pumpMap(t, rows: [mk('a', 'P3'), mk('far1', 'P1', north: 30000), mk('far2', 'P3', north: -30000)]);
      expect(find.byKey(const Key('map_outside_alert')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('map_outside_alert')), matching: find.textContaining('1 es P1')), findsOneWidget);
    });
  });

  group('la precisión no se finge', () {
    testWidgets('un anillo muestra la incertidumbre cuando es mayor que el marcador', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1', quality: 'within200m'), mk('b', 'P3', north: 800, east: 800, quality: 'within1km')]);
      expect(find.byKey(const Key('map_precision_a')), findsOneWidget);
      expect(find.byKey(const Key('map_precision_b')), findsOneWidget);
    });

    testWidgets('si la precisión es menor que el marcador o no se sabe, no se dibuja un anillo inventado', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1', quality: 'within10m'), mk('b', 'P3', north: 800, east: 800), mk('c', 'P3', north: -800, east: -800, quality: 'over1km')]);
      expect(find.byKey(const Key('map_precision_a')), findsNothing);
      expect(find.byKey(const Key('map_precision_b')), findsNothing);
      expect(find.byKey(const Key('map_precision_c')), findsNothing);
    });
  });

  group('la escala', () {
    testWidgets('hay una barra de escala con una cifra redonda', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 1500, east: 1500)]);
      final label = t.widget<Text>(find.byKey(const Key('map_scale'))).data!;
      expect(RegExp(r'^\d+ (m|km)$').hasMatch(label), isTrue, reason: label);
    });

    testWidgets('en una zona de unos cientos de metros la escala va en metros; en decenas de km, en km', (t) async {
      await pumpMap(t, rows: [mk('a', 'P1'), mk('b', 'P3', north: 300, east: 300)]);
      expect(t.widget<Text>(find.byKey(const Key('map_scale'))).data, matches(RegExp(r'^\d+ m$')));
      await pumpMap(t, rows: [mk('a', 'P1', north: 0), mk('b', 'P3', north: 40000, east: 40000)]);
      // otro encuadre: se recrea el widget para que ajuste de nuevo
      await t.pumpWidget(const SizedBox());
      await pumpMap(t, rows: [mk('a', 'P1', north: 0), mk('b', 'P3', north: 40000, east: 40000)]);
      expect(t.widget<Text>(find.byKey(const Key('map_scale'))).data, matches(RegExp(r'^\d+ km$')));
    });
  });
}
