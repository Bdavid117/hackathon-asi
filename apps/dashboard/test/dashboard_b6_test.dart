import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

const int kNow = 1786371100; // segundos: el reloj de las pruebas

Map<String, Object?> item(
  String id,
  String urgency, {
  String rec = 'informacion_requerida',
  String approval = 'pendiente',
  int? firstAgoSec,
  int receivedAt = 1794197853000,
  List<String> signals = const ['atrapado'],
  bool located = true,
}) {
  final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
  return {
    ...base,
    'id': id,
    'urgency': urgency,
    'signals': signals,
    'firstAt': kNow - (firstAgoSec ?? 120),
    'lastAt': kNow - (firstAgoSec ?? 120),
    'receivedAt': receivedAt,
    'recommendation': {'state': rec, 'id': 'r-$id', 'actions': ['enviar_rescate'], 'resourceIds': <String>[], 'pending': <String>[], 'missing': <String>[]},
    'approval': {'status': approval, 'discrepancy': false, 'decisions': 0},
    'lat': located ? 5.0689 + id.codeUnitAt(0) * 0.0001 : null,
    'lon': located ? -75.5174 : null,
    'bareSos': false,
  };
}

IncidentsPage pageOf(List<Map<String, Object?>> items, {Map<String, Object?> counters = const {}, bool bare = false}) {
  final j = fixture('incidents_short.json');
  final c = {...(j['counters']! as Map).cast<String, Object?>(), 'incidents': items.length + 3, ...counters};
  return IncidentsPage.fromJson({...j, 'items': items, 'counters': c, if (!bare) 'bareSos': j['bareSos']});
}

void main() {
  Future<void> boot(WidgetTester tester, FakeApi api, {Duration? every, Size size = const Size(1280, 900), int now = kNow}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(now * 1000))));
    await tester.pumpAndSettle();
  }

  group('pendientes de decisión: el contador, el filtro del nodo y la antigüedad', () {
    testWidgets('el contador sale del nodo (sobre el total) y dice desde cuándo espera la más antigua', (tester) async {
      final api = FakeApi(short: pageOf([item('a', 'P1', rec: 'propuesta')], counters: {'pendingDecision': 3, 'pendingOldestAt': kNow - 720}));
      await boot(tester, api);
      final stat = find.byKey(const Key('counter_pendingDecision'));
      expect(find.descendant(of: stat, matching: find.text('3')), findsOneWidget);
      expect(find.descendant(of: stat, matching: find.textContaining('hace 12 min')), findsOneWidget);
    });

    testWidgets('tocarlo pide al nodo SÓLO los pendientes (vista completa, pending=true) y lo dice en la cabecera', (tester) async {
      final api = FakeApi(short: pageOf([item('a', 'P1', rec: 'propuesta')], counters: {'pendingDecision': 1}), all: pageOf([item('a', 'P1', rec: 'propuesta'), item('b', 'P3')]));
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('counter_pendingDecision')));
      await tester.pumpAndSettle();
      expect(api.of('incidents').last.args['pending'], isTrue);
      expect(api.of('incidents').last.args['view'], 'all');
      expect(find.textContaining('Pendientes de decisión (1)'), findsWidgets);
      expect(find.byKey(const Key('incident_a')), findsOneWidget);
      expect(find.byKey(const Key('incident_b')), findsNothing);
    });

    testWidgets('con 0 pendientes el contador no se puede tocar (no pide nada)', (tester) async {
      final api = FakeApi(short: pageOf([item('a', 'P1')], counters: {'pendingDecision': 0}));
      await boot(tester, api);
      final before = api.of('incidents').length;
      await tester.tap(find.byKey(const Key('counter_pendingDecision')));
      await tester.pumpAndSettle();
      expect(api.of('incidents').length, before);
    });

    testWidgets('las decisiones contradictorias se cuentan aparte y se ven siempre', (tester) async {
      await boot(tester, FakeApi(short: pageOf([item('a', 'P1')], counters: {'discrepancies': 2})));
      expect(find.descendant(of: find.byKey(const Key('counter_discrepancies')), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('un P1 propuesto y sin decidir pasado el plazo (5 min) lo dice; antes del plazo, no', (tester) async {
      final api = FakeApi(short: pageOf([item('late', 'P1', rec: 'propuesta', firstAgoSec: 6 * 60), item('early', 'P1', rec: 'propuesta', firstAgoSec: 2 * 60)]));
      await boot(tester, api);
      expect(find.byKey(const Key('overdue_late')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('overdue_late')), matching: find.textContaining('hace 6 min')), findsOneWidget);
      expect(find.byKey(const Key('overdue_early')), findsNothing);
      expect(find.text('Pendiente de decisión'), findsOneWidget, reason: 'sólo el que aún está a tiempo; el vencido dice «Sin decidir hace N min» en lugar del genérico');
    });

    testWidgets('un P2 tiene un plazo mayor (15 min); un P3 no tiene plazo; lo ya decidido o sin propuesta, tampoco', (tester) async {
      final api = FakeApi(
        short: pageOf([
          item('p2late', 'P2', rec: 'propuesta', firstAgoSec: 20 * 60),
          item('p2ok', 'P2', rec: 'propuesta', firstAgoSec: 10 * 60),
          item('p3', 'P3', rec: 'propuesta', firstAgoSec: 90 * 60),
          item('done', 'P1', rec: 'propuesta', approval: 'aprobada', firstAgoSec: 60 * 60),
          item('noprop', 'P1', firstAgoSec: 60 * 60),
        ]),
      );
      await boot(tester, api);
      expect(find.byKey(const Key('overdue_p2late')), findsOneWidget);
      for (final id in ['p2ok', 'p3', 'done', 'noprop']) {
        expect(find.byKey(Key('overdue_$id')), findsNothing, reason: id);
      }
    });

    testWidgets('una propuesta caducada que nadie renovó también cuenta como sin decidir', (tester) async {
      final api = FakeApi(short: pageOf([item('cad', 'P1', rec: 'propuesta', approval: 'caduca', firstAgoSec: 8 * 60)]));
      await boot(tester, api);
      expect(find.byKey(const Key('overdue_cad')), findsOneWidget);
    });
  });

  group('la fila de contadores mide siempre lo mismo', () {
    testWidgets('con 0 o con 100 pendientes, con o sin hora de la más antigua, la altura no cambia (no le quita sitio a la lista)', (tester) async {
      final api = FakeApi(short: pageOf([item('a', 'P1')], counters: {'pendingDecision': 0}));
      await boot(tester, api, every: const Duration(seconds: 2));
      final before = tester.getSize(find.byKey(const Key('stats_row')));
      final listTop = tester.getTopLeft(find.byKey(const Key('incident_a')));
      api.short = pageOf([item('a', 'P1')], counters: {'pendingDecision': 100, 'pendingOldestAt': kNow - 3600, 'discrepancies': 12});
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('stats_row'))).height, before.height);
      expect(tester.getTopLeft(find.byKey(const Key('incident_a'))), listTop);
    });

    testWidgets('con 360 px de ancho no desborda y se puede desplazar hasta el último contador', (tester) async {
      await boot(tester, FakeApi(short: pageOf([item('a', 'P1')], counters: {'pendingDecision': 3, 'pendingOldestAt': kNow - 300})), size: const Size(360, 800));
      expect(tester.takeException(), isNull);
      await tester.drag(find.byKey(const Key('stats_row')), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('novedades: se avisa, no se mueve nada', () {
    testWidgets('en una pantalla estrecha el aviso aparece junto al selector sin desbordar ni mover la lista', (tester) async {
      final a = item('a', 'P3', receivedAt: 1000);
      final api = FakeApi(short: pageOf([a]));
      await boot(tester, api, every: const Duration(seconds: 2), size: const Size(500, 900));
      final top = tester.getTopLeft(find.byKey(const Key('incident_a')));
      api.short = pageOf([a, item('n', 'P3', receivedAt: 5000)]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.byKey(const Key('news_pill')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.byKey(const Key('incident_a'))), top);
    });

    testWidgets('al abrir no hay aviso, aunque haya mucho', (tester) async {
      await boot(tester, FakeApi(short: pageOf([item('a', 'P1', receivedAt: 1000), item('b', 'P3', receivedAt: 2000)])));
      expect(find.byKey(const Key('news_pill')), findsNothing);
    });

    testWidgets('un incidente que llega después se avisa con cuántos y cuántos son P1, sin reordenar lo que había', (tester) async {
      final a = item('a', 'P1', receivedAt: 1000), b = item('b', 'P3', receivedAt: 2000);
      final api = FakeApi(short: pageOf([a, b]));
      await boot(tester, api, every: const Duration(seconds: 2));
      final topA = tester.getTopLeft(find.byKey(const Key('incident_a'))), topB = tester.getTopLeft(find.byKey(const Key('incident_b')));

      api.short = pageOf([a, item('n', 'P1', receivedAt: 5000), b]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(tester.widget<Text>(find.descendant(of: find.byKey(const Key('news_pill')), matching: find.byType(Text))).data, '1 novedad (1 P1)');
      expect(tester.getTopLeft(find.byKey(const Key('incident_a'))), topA, reason: 'lo que ya estaba no se movió (el nuevo entra donde el nodo lo ordena, debajo del P1 anterior)');
      expect(tester.getTopLeft(find.byKey(const Key('incident_b'))).dy, greaterThan(topB.dy), reason: 'el nuevo ocupa su sitio por orden del nodo; lo de abajo baja, nada salta hacia arriba');
    });

    testWidgets('tocar el aviso lo da por visto y abre el incidente nuevo más urgente', (tester) async {
      final a = item('a', 'P3', receivedAt: 1000);
      final api = FakeApi(short: pageOf([a]), details: {'p1new': p1Detail(), 'p3new': p1Detail()});
      await boot(tester, api, every: const Duration(seconds: 2));
      api.short = pageOf([item('p3new', 'P3', receivedAt: 3000), item('p1new', 'P1', receivedAt: 4000), a]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.tap(find.byKey(const Key('news_pill')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('news_pill')), findsNothing);
      expect(find.byType(IncidentDetailView), findsOneWidget);
      expect(find.byKey(const Key('selected_p1new')), findsOneWidget, reason: 'abre el más urgente de las novedades');
    });

    testWidgets('cambiar de vista («Ver todo») no inventa novedades', (tester) async {
      final api = FakeApi(short: pageOf([item('a', 'P1', receivedAt: 1000)]), all: pageOf([item('a', 'P1', receivedAt: 1000), item('z', 'P3', receivedAt: 9000)]));
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('news_pill')), findsNothing);
    });

    testWidgets('el aviso lo lee un lector de pantalla sin que nadie lo busque (región en vivo)', (tester) async {
      final handle = tester.ensureSemantics();
      final a = item('a', 'P3', receivedAt: 1000);
      final api = FakeApi(short: pageOf([a]));
      await boot(tester, api, every: const Duration(seconds: 2));
      api.short = pageOf([a, item('n', 'P1', receivedAt: 5000)]);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(tester.getSemantics(find.byKey(const Key('news_pill'))).flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });
  });

  group('filtros y búsqueda sobre lo cargado', () {
    final rows = [
      item('a', 'P1', signals: const ['atrapado', 'herido']),
      item('b', 'P3', signals: const ['via_bloqueada']),
      item('c', 'P2', signals: const ['incendio'], located: false),
      item('d', 'P3', signals: const ['menores_mayores']),
    ];

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('filter_open')));
      await tester.pumpAndSettle();
    }

    testWidgets('sin filtro no hay resumen ni nada oculto', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      expect(find.byKey(const Key('filter_summary')), findsNothing);
      for (final id in ['a', 'b', 'c', 'd']) {
        expect(find.byKey(Key('incident_$id')), findsOneWidget);
      }
    });

    testWidgets('buscar «via» deja sólo «Vía bloqueada» y DICE cuántos oculta y cuántos de esos son P1', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      await openPanel(tester);
      await tester.enterText(find.byKey(const Key('filter_query')), 'via');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_b')), findsOneWidget);
      for (final id in ['a', 'c', 'd']) {
        expect(find.byKey(Key('incident_$id')), findsNothing, reason: id);
      }
      final summary = tester.widget<Text>(find.byKey(const Key('filter_summary'))).data!;
      expect(summary, contains('1 de 4 cargados'));
      expect(summary, contains('3 ocultos por el filtro (1 es P1)'));
    });

    testWidgets('una marca filtra («Sin ubicación») y «Quitar filtro» lo devuelve todo', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      await openPanel(tester);
      await tester.tap(find.byKey(const Key('filter_flag_noLocation')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_c')), findsOneWidget);
      expect(find.byKey(const Key('incident_a')), findsNothing);
      await tester.tap(find.byKey(const Key('filter_clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_a')), findsOneWidget);
      expect(find.byKey(const Key('filter_summary')), findsNothing);
    });

    testWidgets('el filtro activo se ve aunque el panel esté cerrado', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      await openPanel(tester);
      await tester.tap(find.byKey(const Key('filter_flag_noLocation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter_open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter_panel')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('filter_summary'))).data, contains('Sin ubicación'));
    });

    testWidgets('la fila agregada de «SOS sin detalle» no se esconde con un filtro', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      expect(find.byKey(const Key('bare_row')), findsOneWidget);
      await openPanel(tester);
      await tester.enterText(find.byKey(const Key('filter_query')), 'via');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bare_row')), findsOneWidget);
    });

    testWidgets('el mapa respeta el filtro y no confunde lo filtrado con «más en la lista completa»', (tester) async {
      await boot(tester, FakeApi(short: pageOf(rows)));
      await openPanel(tester);
      await tester.enterText(find.byKey(const Key('filter_query')), 'via');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view_map')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map_marker_b')), findsOneWidget);
      expect(find.byKey(const Key('map_marker_a')), findsNothing);
      final status = tester.widget<Text>(find.byKey(const Key('map_status'))).data!;
      expect(status, startsWith('1 en el mapa'));
      expect(status, endsWith('· 3 más en la lista completa'), reason: 'los 3 del filtro NO son «más sin cargar»; los 3 son los SOS sin detalle del contador');
    });
  });
}
