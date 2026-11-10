import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/incident_card.dart';
import 'package:sard_dashboard/incident_filter.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

const String b1 = '00000000000000b1-1', b2 = '00000000000000b2-1';

Map<String, Object?> pairJson({Object? contradictions = _absent}) {
  final j = fixture('detail_pair.json');
  return {
    ...j,
    if (!identical(contradictions, _absent)) 'contradictions': contradictions,
    'observations': [
      {...((j['observations']! as List)[0] as Map).cast<String, Object?>(), 'text': 'puente colapsado calle veinte carros abajo sin heridos'},
      {...((j['observations']! as List)[1] as Map).cast<String, Object?>(), 'text': 'puente colapsado calle veinte carros abajo, hay un herido'},
    ],
  };
}

const Object _absent = Object();

Map<String, Object?> negacion() => {'kind': 'negacion', 'code': 'herido', 'a': b1, 'b': b2};

void main() {
  group('el modelo', () {
    test('Counters.withContradictions: sobre el total; un nodo anterior no lo manda (0) y un valor raro tampoco rompe', () {
      final c = (fixture('incidents_short.json')['counters']! as Map).cast<String, Object?>();
      expect(Counters.fromJson({...c, 'withContradictions': 4}).withContradictions, 4);
      expect(Counters.fromJson(c).withContradictions, 0);
      expect(Counters.fromJson({...c, 'withContradictions': 'x'}).withContradictions, 0);
    });

    test('la fila cuenta las contradicciones: un entero en el resumen, una lista en el detalle, nada en un nodo anterior', () {
      final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
      expect(IncidentRow.fromJson({...base, 'contradictions': 2}).contradictionCount, 2);
      expect(IncidentRow.fromJson({...base, 'contradictions': [negacion(), negacion()]}).contradictionCount, 2);
      expect(IncidentRow.fromJson({...base}..remove('contradictions')).contradictionCount, 0);
      expect(IncidentRow.fromJson({...base, 'contradictions': -5}).contradictionCount, 0);
      expect(IncidentRow.fromJson({...base, 'contradictions': [negacion(), 'basura', 7]}).contradictionCount, 1, reason: 'sólo se cuentan las bien formadas');
    });

    test('el detalle distingue «el nodo no lo dice» (nulo) de «no hay» (vacío) y de «hay» (lista)', () {
      expect(IncidentDetail.fromJson(pairJson()).contradictions, isNull);
      expect(IncidentDetail.fromJson(pairJson(contradictions: const [])).contradictions, isEmpty);
      final d = IncidentDetail.fromJson(pairJson(contradictions: [negacion()]));
      expect(d.contradictions!.single.kind, 'negacion');
      expect((d.contradictions!.single.code, d.contradictions!.single.a, d.contradictions!.single.b), ('herido', b1, b2));
    });

    test('una contradicción mal formada se ignora sin romper el detalle', () {
      final d = IncidentDetail.fromJson(pairJson(contradictions: [negacion(), 'basura', {'kind': 'negacion'}, {'kind': 7, 'a': 1}]));
      expect(d.contradictions, hasLength(1));
    });
  });

  group('el filtro', () {
    test('«Con contradicciones» deja los que tienen al menos una', () {
      final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
      final withOne = IncidentRow.fromJson({...base, 'id': 'x', 'contradictions': 1});
      final without = IncidentRow.fromJson({...base, 'id': 'y', 'contradictions': 0});
      final r = const IncidentFilter(flags: {FilterFlag.contradictions}).apply([withOne, without]);
      expect([for (final x in r.shown) x.id], ['x']);
      expect(FilterFlag.contradictions.label, 'Con contradicciones');
    });
  });

  group('la tarjeta', () {
    Future<void> pumpCard(WidgetTester t, int n) async {
      final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
      final row = IncidentRow.fromJson({...base, 'id': 'zz', 'contradictions': n});
      await t.pumpWidget(MaterialApp(home: Scaffold(body: IncidentCard(row: row, now: DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000), selected: false, onTap: () {}))));
    }

    testWidgets('dice cuántas contradicciones tiene', (t) async {
      await pumpCard(t, 2);
      expect(find.descendant(of: find.byKey(const Key('contradictions_zz')), matching: find.text('Contradicciones (2)')), findsOneWidget);
    });

    testWidgets('con una, en singular; con ninguna, no hay etiqueta', (t) async {
      await pumpCard(t, 1);
      expect(find.text('1 contradicción'), findsOneWidget);
      await pumpCard(t, 0);
      expect(find.byKey(const Key('contradictions_zz')), findsNothing);
    });
  });

  group('el detalle', () {
    Future<void> boot(WidgetTester tester, IncidentDetail d) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      final api = FakeApi(details: {b1: d});
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: b1, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000), who: ValueNotifier<String>('')))));
      await tester.pumpAndSettle();
    }

    testWidgets('una negación: dice cuál y enseña LOS DOS reportes con lo que dijo cada uno', (tester) async {
      await boot(tester, IncidentDetail.fromJson(pairJson(contradictions: [negacion()])));
      final sec = find.byKey(const Key('contradictions_section'));
      expect(sec, findsOneWidget);
      expect(find.descendant(of: sec, matching: find.textContaining('niega «Herido»')), findsOneWidget);
      expect(find.descendant(of: sec, matching: find.textContaining('sin heridos')), findsOneWidget);
      expect(find.descendant(of: sec, matching: find.textContaining('hay un herido')), findsOneWidget);
      expect(find.descendant(of: sec, matching: find.textContaining('no se resuelve sola')), findsOneWidget, reason: 'se conserva para que decida una persona');
    });

    testWidgets('personas incompatibles: dice qué dijo cada uno', (tester) async {
      final c = {'kind': 'personas', 'a': b1, 'b': b2, 'aValue': '1', 'bValue': '6–20'};
      await boot(tester, IncidentDetail.fromJson(pairJson(contradictions: [c])));
      expect(find.descendant(of: find.byKey(const Key('contradictions_section')), matching: find.textContaining('1 persona')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('contradictions_section')), matching: find.textContaining('6–20')), findsOneWidget);
    });

    testWidgets('sin contradicciones: dice QUÉ se evaluó y que lo demás no (no afirma que no las haya)', (tester) async {
      await boot(tester, IncidentDetail.fromJson(pairJson(contradictions: const [])));
      final t = tester.widget<Text>(find.byKey(const Key('contradictions_none')));
      expect(t.data, contains('negación explícita'));
      expect(t.data, contains('cantidad de personas'));
      expect(t.data, contains('no se evalúan'));
    });

    testWidgets('un nodo anterior que no manda la lista: se sigue diciendo «no evaluadas»', (tester) async {
      await boot(tester, IncidentDetail.fromJson(pairJson()));
      expect(find.textContaining('Contradicciones entre reportes: no evaluadas'), findsOneWidget);
    });
  });

  group('el contador de la pantalla', () {
    testWidgets('«Con contradicciones» sale del nodo (sobre el total) y se ve siempre', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final j = fixture('incidents_short.json');
      final page = IncidentsPage.fromJson({...j, 'counters': {...(j['counters']! as Map).cast<String, Object?>(), 'withContradictions': 3}});
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: FakeApi(short: page), every: null)));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('counter_withContradictions')), matching: find.text('3')), findsOneWidget);
    });
  });
}
