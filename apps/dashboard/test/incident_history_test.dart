import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/incident_history_panel.dart';
import 'package:sard_dashboard/models.dart';
import 'package:sard_dashboard/theme.dart';

import 'fake_api.dart';

Map<String, Object?> step(String agent, String kind, String summary, {String? node = 'A', int? at = 1786371100000, bool derived = false, List<String> ids = const ['A:000001']}) =>
    {'agent': agent, 'kind': kind, 'summary': summary, 'nodeId': derived ? null : node, 'atMs': derived ? null : at, 'derived': derived, 'eventIds': derived ? <String>[] : ids};

Map<String, Object?> audit(String who, {String decision = 'granted', String status = 'vigente', int at = 1786371200000, List<String> supersedes = const [], String? note, String id = 'A:000010'}) =>
    {'eventId': id, 'who': who, 'decision': decision, 'atMs': at, 'status': status, 'supersedes': supersedes, 'note': note};

Map<String, Object?> history({List<Map<String, Object?>>? steps, int? total, List<Map<String, Object?>> audits = const [], int? auditTotal}) {
  final s = steps ??
      [
        step('1 · Recepción', 'recibido', 'Reporte aa-1 · revisión 0 · canal app', node: 'B', at: 1786371100000, ids: ['B:000007']),
        step('2 · Triaje', 'triaje', 'Urgencia P1 · reglas + modelo (agente llm-1)', at: 1786371105000, ids: ['A:000009']),
        step('3 · Correlación', 'agrupamiento', 'Grupo de 1 reporte · 1 fuente', derived: true),
        step('6 · Coordinación', 'recomendacion', 'Recomendación (propuesta): 2 acciones, 1 requisitos pendientes', derived: true),
      ];
  return {'steps': s, 'stepsTotal': total ?? s.length, 'audit': audits, 'auditTotal': auditTotal ?? audits.length};
}

String hhmmss(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

IncidentDetail detailWith(Map<String, Object?>? h) => IncidentDetail.fromJson({...fixture('detail_p1_approved.json'), 'history': ?h});

Future<void> pumpPanel(WidgetTester t, Map<String, Object?> h, {Size size = const Size(900, 1200)}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: dashTheme(), home: Scaffold(body: SingleChildScrollView(child: IncidentHistoryPanel(history: HistoryInfo.fromJson(h)!)))));
  await t.pump();
}

Future<void> open(WidgetTester t) async {
  await t.tap(find.byKey(const Key('history_toggle')));
  await t.pumpAndSettle();
}

void main() {
  group('HistoryInfo.fromJson', () {
    test('lee los pasos y la auditoría', () {
      final h = HistoryInfo.fromJson(history(audits: [audit('Ana Gómez', supersedes: ['A:000003'], note: 'Visto')]))!;
      expect(h.steps, hasLength(4));
      expect((h.steps.first.agent, h.steps.first.nodeId, h.steps.first.atMs, h.steps.first.derived), ('1 · Recepción', 'B', 1786371100000, false));
      expect(h.steps.last.derived, isTrue);
      expect(h.steps.last.atMs, isNull);
      expect((h.audit.single.who, h.audit.single.granted, h.audit.single.status, h.audit.single.note), ('Ana Gómez', true, 'vigente', 'Visto'));
      expect(h.audit.single.supersedes, ['A:000003']);
      expect(h.stepsTotal, 4);
    });

    test('un nodo anterior (sin history) da null y el detalle sigue siendo válido', () {
      expect(HistoryInfo.fromJson(null), isNull);
      expect(detailWith(null).history, isNull);
      expect(detailWith(history()).history, isNotNull);
    });

    test('una historia mal formada NO tumba el detalle (es información secundaria): da null', () {
      for (final bad in [
        'texto',
        {'steps': 'x', 'stepsTotal': 1, 'audit': [], 'auditTotal': 0},
        {'steps': [{'agent': 7}], 'stepsTotal': 1, 'audit': [], 'auditTotal': 0},
        {'steps': [], 'stepsTotal': 'uno', 'audit': [], 'auditTotal': 0},
      ]) {
        expect(HistoryInfo.fromJson(bad), isNull, reason: '$bad');
      }
      expect(() => IncidentDetail.fromJson({...fixture('detail_p1_approved.json'), 'history': 'basura'}), returnsNormally);
    });
  });

  group('el panel «Historia»', () {
    testWidgets('plegado por omisión: sólo la cabecera, con el conteo; no se construye ningún paso', (t) async {
      await pumpPanel(t, history());
      expect(find.byKey(const Key('history_panel')), findsOneWidget);
      expect(find.byKey(const Key('history_toggle')), findsOneWidget);
      expect(find.byKey(const Key('history_step_0')), findsNothing);
      expect(t.widget<Text>(find.byKey(const Key('history_count'))).data, '4 pasos');
    });

    testWidgets('la altura plegada no depende de cuántos pasos haya (no empuja la lista)', (t) async {
      await pumpPanel(t, history());
      final small = t.getSize(find.byKey(const Key('history_panel'))).height;
      await pumpPanel(t, history(steps: [for (var i = 0; i < 60; i++) step('1 · Recepción', 'recibido', 'Reporte m$i-1', ids: ['A:${i.toString().padLeft(6, '0')}'])], total: 1500));
      expect(t.getSize(find.byKey(const Key('history_panel'))).height, small);
    });

    testWidgets('con muchos pasos dice «N de M» y que son los más recientes', (t) async {
      await pumpPanel(t, history(steps: [for (var i = 0; i < 60; i++) step('1 · Recepción', 'recibido', 'Reporte m$i-1')], total: 1500));
      expect(t.widget<Text>(find.byKey(const Key('history_count'))).data, '60 de 1500 pasos (los más recientes)');
    });

    testWidgets('pestaña Agentes: agrupa por agente en orden; el paso con evento trae nodo y hora; el derivado, ninguna hora y su marca', (t) async {
      await pumpPanel(t, history());
      await open(t);
      final titles = [for (final w in t.widgetList<Text>(find.byKey(const Key('history_agent_title')))) w.data];
      expect(titles, ['1 · Recepción', '2 · Triaje', '3 · Correlación', '6 · Coordinación']);
      final first = t.widget<Text>(find.byKey(const Key('history_step_text_0'))).data!;
      expect(first, contains('Reporte aa-1'));
      final meta = t.widget<Text>(find.byKey(const Key('history_step_meta_0'))).data!;
      expect(meta, contains('nodo B'));
      expect(meta, contains(hhmmss(1786371100000)));
      final derivedMeta = t.widget<Text>(find.byKey(const Key('history_step_meta_2'))).data!;
      expect(derivedMeta, 'derivado de estos eventos');
      expect(derivedMeta, isNot(matches(RegExp(r'\d\d:\d\d'))));
      expect(find.byKey(const Key('history_derived_note')), findsOneWidget);
    });

    testWidgets('el orden de los agentes es el canónico aunque los pasos lleguen en otro orden; y un derivado nunca muestra hora, venga como venga', (t) async {
      final odd = history(steps: [
        {...step('6 · Coordinación', 'recomendacion', 'Recomendación', derived: true), 'atMs': 1786371100000},
        step('2 · Triaje', 'triaje', 'Urgencia P1'),
        step('1 · Recepción', 'recibido', 'Reporte aa-1'),
      ]);
      await pumpPanel(t, odd);
      await open(t);
      expect([for (final w in t.widgetList<Text>(find.byKey(const Key('history_agent_title')))) w.data], ['1 · Recepción', '2 · Triaje', '6 · Coordinación']);
      expect(t.widget<Text>(find.byKey(const Key('history_step_meta_0'))).data, 'derivado de estos eventos');
    });

    testWidgets('dice en UNA línea que los agentes 4 y 5 no dejan eventos por incidente (no se les inventa fila)', (t) async {
      await pumpPanel(t, history());
      await open(t);
      final note = t.widget<Text>(find.byKey(const Key('history_no_rows_note'))).data!;
      expect(note, contains('4'));
      expect(note, contains('5'));
      expect(note, contains('no dejan eventos'));
      expect([for (final w in t.widgetList<Text>(find.byKey(const Key('history_agent_title')))) w.data], isNot(contains('4 · Comunicación')));
    });

    testWidgets('pestaña Decisiones: quién, cuándo, estado y a quién sustituyó; y dice que no registra QUÉ se aprobó', (t) async {
      await pumpPanel(t, history(audits: [audit('Ana Gómez', status: 'sustituida', id: 'A:000010', at: 1786371200000), audit('Luis Torres', decision: 'denied', supersedes: ['A:000010'], note: 'Falta confirmar', id: 'A:000011', at: 1786371300000)]));
      await open(t);
      await t.tap(find.byKey(const Key('history_tab_audit')));
      await t.pumpAndSettle();
      final a0 = t.widget<Text>(find.byKey(const Key('history_audit_0'))).data!;
      expect(a0, contains('Ana Gómez'));
      expect(a0, contains('aprobó'));
      expect(a0, contains('sustituida'));
      expect(a0, contains(hhmmss(1786371200000)));
      final a1 = t.widget<Text>(find.byKey(const Key('history_audit_1'))).data!;
      expect(a1, contains('Luis Torres'));
      expect(a1, contains('rechazó'));
      expect(a1, contains('vigente'));
      expect(a1, contains('sustituye a A:000010'));
      expect(a1, contains('Falta confirmar'));
      expect(t.widget<Text>(find.byKey(const Key('history_audit_note'))).data, contains('qué se aprobó'));
    });

    testWidgets('sin decisiones lo dice; con más decisiones que las mostradas, «N de M»', (t) async {
      await pumpPanel(t, history());
      await open(t);
      await t.tap(find.byKey(const Key('history_tab_audit')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('history_audit_empty')), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // otro panel: sin el estado (abierto, pestaña) del anterior
      await pumpPanel(t, history(audits: [audit('Ana')], auditTotal: 80));
      await open(t);
      await t.tap(find.byKey(const Key('history_tab_audit')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const Key('history_audit_count'))).data, '1 de 80 decisiones (las más recientes)');
    });

    testWidgets('a 360 px de ancho no desborda (con la Historia abierta en las dos pestañas)', (t) async {
      await pumpPanel(t, history(audits: [audit('Ana Gómez Rodríguez de la Torre', supersedes: ['A:000003', 'B:000044'], note: 'Una nota larga de quien decide para comprobar que el texto se parte en líneas y no desborda')]), size: const Size(360, 900));
      await open(t);
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const Key('history_tab_audit')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('cada paso tiene una etiqueta accesible con agente, nodo y hora', (t) async {
      final handle = t.ensureSemantics();
      await pumpPanel(t, history());
      await open(t);
      final label = t.getSemantics(find.byKey(const Key('history_step_0'))).label;
      expect(label, contains('1 · Recepción'));
      expect(label, contains('nodo B'));
      expect(label, contains(hhmmss(1786371100000)));
      handle.dispose();
    });
  });

  group('dentro del detalle del incidente', () {
    Future<void> boot(WidgetTester t, IncidentDetail d) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(900, 1800);
      addTearDown(t.view.reset);
      final api = FakeApi(details: {'00000000000000a1-1': d});
      await t.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: '00000000000000a1-1', every: null, who: ValueNotifier('')))));
      await t.pumpAndSettle();
    }

    testWidgets('nodo anterior sin history: no hay panel y el detalle sigue funcionando', (t) async {
      await boot(t, detailWith(null));
      expect(find.byKey(const Key('detail_panel')), findsOneWidget);
      expect(find.byKey(const Key('history_panel')), findsNothing);
    });

    testWidgets('con history aparece el panel al final, plegado, sin quitar nada de lo demás', (t) async {
      await boot(t, detailWith(history()));
      expect(find.byKey(const Key('why_section')), findsOneWidget);
      expect(find.byKey(const Key('observations_section')), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('history_panel')));
      expect(find.byKey(const Key('history_panel')), findsOneWidget);
      expect(find.byKey(const Key('history_step_0')), findsNothing);
    });
  });
}
