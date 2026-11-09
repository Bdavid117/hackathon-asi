import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/incident_card.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

/// Para contar tarjetas sin depender de su contenido.
abstract final class IncidentCardFinder {
  static const Type type = IncidentCard;
}

void main() {
  Future<void> boot(WidgetTester tester, FakeApi api, {Duration? every, Size size = const Size(1280, 900)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: every, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
    await tester.pumpAndSettle();
  }

  group('contadores honestos', () {
    testWidgets('la barra de triaje muestra los incidentes por urgencia, sobre el TOTAL real', (tester) async {
      await boot(tester, FakeApi());
      expect(find.descendant(of: find.byKey(const Key('counter_P1')), matching: find.text('1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_P2')), matching: find.text('1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_P3')), matching: find.text('6')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_P4')), matching: find.text('0')), findsOneWidget);
    });

    testWidgets('incertidumbre alta, a revisar, SOS sin detalle y en seguimiento fuera de la vista', (tester) async {
      await boot(tester, FakeApi());
      expect(find.descendant(of: find.byKey(const Key('counter_highUncertainty')), matching: find.text('1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_needsReview')), matching: find.text('1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_bareSos')), matching: find.text('3')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_followUp')), matching: find.text('0')), findsOneWidget);
      expect(find.text('Incertidumbre alta'), findsWidgets);
    });

    testWidgets('los contadores son los del total aunque la vista corta muestre menos', (tester) async {
      final j = fixture('incidents_short.json');
      final counters = {...(j['counters']! as Map<String, Object?>), 'incidents': 500, 'followUp': 300, 'byUrgency': {'P1': 12, 'P2': 40, 'P3': 400, 'P4': 48}};
      final api = FakeApi(short: IncidentsPage.fromJson({...j, 'counters': counters}));
      await boot(tester, api);
      expect(find.descendant(of: find.byKey(const Key('counter_followUp')), matching: find.text('300')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('counter_P3')), matching: find.text('400')), findsOneWidget);
      expect(find.text('Ver todo (500)'), findsOneWidget);
    });
  });

  group('la vista corta', () {
    testWidgets('lista los incidentes en el orden del nodo, con su urgencia', (tester) async {
      await boot(tester, FakeApi());
      final tops = <double>[];
      for (final id in ['00000000000000a1-1', '00000000000000c1-1', '00000000000000b1-1']) {
        expect(find.byKey(Key('incident_$id')), findsOneWidget, reason: id);
        tops.add(tester.getTopLeft(find.byKey(Key('incident_$id'))).dy);
      }
      expect(tops, [...tops]..sort());
    });

    testWidgets('cada tarjeta resume qué pasa, cuántos reportes, personas y fuentes', (tester) async {
      await boot(tester, FakeApi());
      final card = find.byKey(const Key('incident_00000000000000a1-1'));
      expect(find.descendant(of: card, matching: find.text('P1')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('Atrapado')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('2–5 personas')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('1 reporte')), findsOneWidget);
    });

    testWidgets('«Revisar» sólo en lo que no se entendió, «Incertidumbre alta» en P1/P2 con datos dudosos y «Sin ubicación» donde falta', (tester) async {
      await boot(tester, FakeApi());
      final fire = find.byKey(const Key('incident_00000000000000c1-1'));
      expect(find.descendant(of: fire, matching: find.text('Incertidumbre alta')), findsOneWidget);
      expect(find.descendant(of: fire, matching: find.text('Sin ubicación')), findsOneWidget);
      final unread = find.byKey(const Key('incident_00000000000000d1-1'));
      expect(find.descendant(of: unread, matching: find.text('Revisar')), findsOneWidget);
      final p1 = find.byKey(const Key('incident_00000000000000a1-1'));
      expect(find.descendant(of: p1, matching: find.text('Revisar')), findsNothing);
    });

    testWidgets('el estado de la aprobación se ve en la tarjeta', (tester) async {
      await boot(tester, FakeApi());
      expect(find.descendant(of: find.byKey(const Key('incident_00000000000000a1-1')), matching: find.text('Aprobada')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('incident_00000000000000c1-1')), matching: find.text('Falta información')), findsOneWidget);
    });

    testWidgets('los SOS sin detalle son UNA fila agregada con su cuenta, no una tarjeta por cada uno', (tester) async {
      await boot(tester, FakeApi());
      expect(find.byKey(const Key('bare_row')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('bare_row')), matching: find.textContaining('3 SOS sin detalle')), findsOneWidget);
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsNothing);
    });

    testWidgets('sin incidentes: mensaje claro y sin fila agregada', (tester) async {
      final j = fixture('incidents_short.json');
      final empty = IncidentsPage.fromJson({...j, 'items': <Object?>[], 'bareSos': null, 'total': 0, 'counters': {...(j['counters']! as Map<String, Object?>), 'incidents': 0, 'reports': 0, 'bareSos': 0, 'byUrgency': {'P1': 0, 'P2': 0, 'P3': 0, 'P4': 0}, 'highUncertainty': 0, 'needsReview': 0, 'inShortView': 0}});
      await boot(tester, FakeApi(short: empty));
      expect(find.text('Sin reportes todavía'), findsOneWidget);
      expect(find.byKey(const Key('bare_row')), findsNothing);
    });
  });

  group('ver más: todo, los SOS sin detalle, una urgencia', () {
    testWidgets('«Ver todo (N)» pide la vista completa y la muestra; «Volver a la vista corta» regresa', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pumpAndSettle();
      expect(api.of('incidents').last.args['view'], 'all');
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsOneWidget, reason: 'en la vista completa sí aparecen uno a uno');
      expect(find.byKey(const Key('bare_row')), findsNothing);
      await tester.tap(find.byKey(const Key('back_to_short')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bare_row')), findsOneWidget);
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsNothing);
    });

    testWidgets('«Ver» de la fila agregada pide sólo los SOS sin detalle', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('show_bare')));
      await tester.pumpAndSettle();
      final last = api.of('incidents').last;
      expect(last.args['view'], 'all');
      expect(last.args['bare'], true);
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsOneWidget);
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsNothing);
    });

    testWidgets('un clic en un segmento de la barra de triaje filtra por esa urgencia', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('counter_P3')));
      await tester.pumpAndSettle();
      final last = api.of('incidents').last;
      expect(last.args['view'], 'all');
      expect(last.args['urgency'], 'P3');
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsNothing, reason: 'el P1 no es P3');
      expect(find.byKey(const Key('incident_00000000000000b1-1')), findsOneWidget);
      expect(find.byKey(const Key('back_to_short')), findsOneWidget);
    });

    testWidgets('un P1 está a UN clic: tocar «P1» lo lista', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('counter_P1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsOneWidget);
    });

    testWidgets('páginas: «Cargar más» pide la siguiente, las acumula sin repetir y desaparece al llegar al final', (tester) async {
      final api = FakeApi();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null, pageSize: 3, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pumpAndSettle();
      expect(find.byType(IncidentCardFinder.type), findsNWidgets(3));
      expect(find.byKey(const Key('load_more')), findsOneWidget);
      expect(find.textContaining('5 restantes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('load_more')));
      await tester.pumpAndSettle();
      expect(api.of('incidents').last.args['offset'], 3);
      expect(find.byType(IncidentCardFinder.type), findsNWidgets(6));
      await tester.tap(find.byKey(const Key('load_more')));
      await tester.pumpAndSettle();
      expect(find.byType(IncidentCardFinder.type), findsNWidgets(8), reason: '8 incidentes en total, sin repetir ninguno');
      expect(find.byKey(const Key('load_more')), findsNothing);
    });
  });

  group('respuestas que llegan tarde o repetidas', () {
    testWidgets('una respuesta lenta de la vista corta que llega DESPUÉS de cambiar a «ver todo» no pisa lo que se está viendo', (tester) async {
      final api = FakeApi();
      await boot(tester, api, every: const Duration(seconds: 2));
      api.holdShort = Completer<void>();
      await tester.pump(const Duration(seconds: 2)); // empieza un refresco de la vista corta que se queda esperando
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsOneWidget, reason: 'la vista completa ya se ve');
      api.holdShort!.complete(); // llega la respuesta vieja de la vista corta
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsOneWidget, reason: 'la respuesta tardía de otra vista no la reemplaza');
      expect(find.byKey(const Key('bare_row')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('si los datos se desplazan entre dos páginas y una fila vuelve a venir, se muestra UNA vez', (tester) async {
      final all = allPage();
      final items = all.items;
      final shifted = [...items.take(3), items[2], ...items.skip(3)]; // la tercera aparece al final de la página 1 y al principio de la 2
      final api = FakeApi(all: IncidentsPage(view: 'all', counters: all.counters, total: shifted.length, offset: 0, limit: 3, bare: null, items: shifted));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: api, every: null, pageSize: 3, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('load_more')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('incident_${items[2].id}')), findsOneWidget);
    });

    testWidgets('los SOS sin detalle no llevan «Revisar»: no traer nada no es traer algo que no se entendió', (tester) async {
      await boot(tester, FakeApi());
      await tester.tap(find.byKey(const Key('show_bare')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident_00000000000000e1-1')), findsOneWidget);
      expect(find.text('Revisar'), findsNothing);
    });
  });

  group('frescura y fallos: se dicen, no se esconden', () {
    testWidgets('sin conexión con el nodo: aviso y se conserva la última vista', (tester) async {
      final api = FakeApi();
      await boot(tester, api, every: const Duration(seconds: 2));
      expect(find.byKey(const Key('offline_banner')), findsNothing);
      api.failIncidents = http.ClientException('sin red');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('offline_banner')), findsOneWidget);
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsOneWidget, reason: 'la última vista se conserva');
      api.failIncidents = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('offline_banner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('el nodo sirve una vista anterior: se dice con su antigüedad', (tester) async {
      await boot(tester, FakeApi(short: shortPage(stale: true, ageMs: 4200)));
      expect(find.byKey(const Key('stale_banner')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('stale_banner')), matching: find.textContaining('4 s')), findsOneWidget);
    });

    testWidgets('una respuesta que no es válida se avisa como tal (no como «sin conexión») y se conserva lo anterior', (tester) async {
      final api = FakeApi();
      await boot(tester, api, every: const Duration(seconds: 2));
      api.failIncidents = const FormatException('urgencia desconocida: P9');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('invalid_banner')), findsOneWidget);
      expect(find.byKey(const Key('offline_banner')), findsNothing);
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('un primer arranque sin nodo: aviso y mensaje, no una pantalla vacía sin explicación', (tester) async {
      final api = FakeApi()..failIncidents = http.ClientException('sin red');
      await boot(tester, api);
      expect(find.byKey(const Key('offline_banner')), findsOneWidget);
      expect(find.text('Sin reportes todavía'), findsNothing, reason: 'no se dice «sin reportes» cuando en realidad no se pudo leer');
      expect(find.byKey(const Key('no_data')), findsOneWidget);
    });

    testWidgets('los contadores y la lista se actualizan solos', (tester) async {
      final api = FakeApi();
      await boot(tester, api, every: const Duration(seconds: 2));
      final j = fixture('incidents_short.json');
      final counters = {...(j['counters']! as Map<String, Object?>), 'byUrgency': {'P1': 9, 'P2': 1, 'P3': 6, 'P4': 0}};
      api.short = IncidentsPage.fromJson({...j, 'counters': counters});
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.descendant(of: find.byKey(const Key('counter_P1')), matching: find.text('9')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('estado de los nodos', () {
    NodesStatus nodes({required bool partial, List<String> reasons = const [], List<Map<String, Object?>> peers = const []}) => NodesStatus.fromJson({
      'self': {'id': 'A', 'events': 31, 'versionVector': {'A': 31}, 'uptimeMs': 1000},
      'peers': peers,
      'periodMs': 3000,
      'partialView': partial,
      'reasons': reasons,
    });

    testWidgets('un nodo solo: se nombra y no hay alerta', (tester) async {
      await boot(tester, FakeApi());
      expect(find.byKey(const Key('nodes_bar')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('nodes_bar')), matching: find.textContaining('Nodo A')), findsOneWidget);
      expect(find.byKey(const Key('partial_view')), findsNothing);
    });

    testWidgets('con pares: estado y hace cuánto se les vio', (tester) async {
      final api = FakeApi(nodes: nodes(partial: false, peers: [
        {'url': 'http://b:8082', 'state': 'sincronizado', 'lastSeenAgoMs': 2000, 'lastSyncAgoMs': 2000, 'missingEvents': 0, 'lastError': null},
      ]));
      await boot(tester, api);
      final peer = find.byKey(const Key('peer_0'));
      expect(find.descendant(of: peer, matching: find.textContaining('Sincronizado')), findsOneWidget);
      expect(find.descendant(of: peer, matching: find.textContaining('hace 2 s')), findsOneWidget);
    });

    testWidgets('VISTA PARCIAL: si falta un nodo, un aviso visible dice por qué', (tester) async {
      final api = FakeApi(nodes: nodes(partial: true, reasons: ['par_sin_respuesta'], peers: [
        {'url': 'http://b:8082', 'state': 'sin_respuesta', 'lastSeenAgoMs': 40000, 'lastSyncAgoMs': null, 'missingEvents': 5, 'lastError': 'tiempo agotado'},
      ]));
      await boot(tester, api);
      expect(find.byKey(const Key('partial_view')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('partial_view')), matching: find.textContaining('Vista parcial')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('partial_view')), matching: find.textContaining('no responde')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('peer_0')), matching: find.textContaining('Sin respuesta')), findsOneWidget);
    });

    testWidgets('un nodo recién reiniciado (par desconocido) NO se muestra como sincronizado', (tester) async {
      final api = FakeApi(nodes: nodes(partial: true, reasons: ['par_desconocido'], peers: [
        {'url': 'http://b:8082', 'state': 'desconocido', 'lastSeenAgoMs': null, 'lastSyncAgoMs': null, 'missingEvents': null, 'lastError': null},
      ]));
      await boot(tester, api);
      expect(find.descendant(of: find.byKey(const Key('peer_0')), matching: find.textContaining('Sincronizado')), findsNothing);
      expect(find.byKey(const Key('partial_view')), findsOneWidget);
    });

    testWidgets('si no se puede leer el estado de los nodos, se dice (no se asume que todo está bien)', (tester) async {
      final api = FakeApi()..failNodes = http.ClientException('x');
      await boot(tester, api);
      expect(find.byKey(const Key('nodes_unknown')), findsOneWidget);
      expect(find.byKey(const Key('incident_00000000000000a1-1')), findsOneWidget, reason: 'los incidentes se siguen mostrando');
    });
  });

  group('selección y detalle', () {
    testWidgets('al tocar una tarjeta se pide su detalle y se abre el panel', (tester) async {
      final api = FakeApi();
      await boot(tester, api);
      await tester.tap(find.byKey(const Key('incident_00000000000000a1-1')));
      await tester.pumpAndSettle();
      expect(api.of('detail').last.args['id'], '00000000000000a1-1');
      expect(find.byKey(const Key('detail_panel')), findsOneWidget);
    });

    testWidgets('sin selección el panel invita a elegir un incidente', (tester) async {
      await boot(tester, FakeApi());
      expect(find.byKey(const Key('detail_empty')), findsOneWidget);
    });

    testWidgets('en pantallas estrechas el detalle abre a pantalla completa y se puede volver', (tester) async {
      await boot(tester, FakeApi(), size: const Size(420, 900));
      expect(find.byKey(const Key('detail_empty')), findsNothing);
      await tester.tap(find.byKey(const Key('incident_00000000000000a1-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_panel')), findsOneWidget);
      expect(find.byKey(const Key('counters')), findsNothing, reason: 'es otra pantalla');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('counters')), findsOneWidget);
    });

    testWidgets('la tarjeta seleccionada queda marcada', (tester) async {
      await boot(tester, FakeApi());
      await tester.tap(find.byKey(const Key('incident_00000000000000a1-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selected_00000000000000a1-1')), findsOneWidget);
    });

    testWidgets('un incidente que ya no existe (se fusionó) se avisa y se vuelve a pedir la lista', (tester) async {
      final api = FakeApi(details: {});
      await boot(tester, api);
      final before = api.of('incidents').length;
      await tester.tap(find.byKey(const Key('incident_00000000000000a1-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_gone')), findsOneWidget);
      expect(api.of('incidents').length, greaterThan(before));
    });
  });
}
