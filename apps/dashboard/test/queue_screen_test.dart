import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/queue_screen.dart';

Map<String, Object?> item(String key, String urgency, {String? text, List<String> signals = const [], int receivedAt = 0}) => {
      'reportKey': key,
      'urgency': urgency,
      'rev': 0,
      'text': text,
      'signals': signals,
      'receivedAt': receivedAt,
      'capturedAt': 0,
      'lat': null,
      'lon': null,
      'flags': 0,
    };

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('muestra los reportes en el orden recibido, con su insignia y el total', (tester) async {
    final items = [
      item('a-1', 'P1', text: 'Edificio colapsado', signals: ['atrapado', 'herido']),
      item('b-1', 'P2', signals: ['incendio']),
      item('c-1', 'P4'),
    ];
    await tester.pumpWidget(host(QueueScreen(fetch: () async => items, every: null)));
    await tester.pump();
    expect(find.byKey(const Key('item_a-1')), findsOneWidget);
    expect(find.text('P1'), findsOneWidget);
    expect(find.text('Edificio colapsado'), findsOneWidget);
    expect(find.text('3 reportes'), findsOneWidget);
    final order = [for (final k in ['a-1', 'b-1', 'c-1']) tester.getTopLeft(find.byKey(Key('item_$k'))).dy];
    expect(order, [...order]..sort());
  });

  testWidgets('un solo reporte usa el singular y una cola vacía lo dice', (tester) async {
    await tester.pumpWidget(host(QueueScreen(fetch: () async => [item('a-1', 'P3')], every: null)));
    await tester.pump();
    expect(find.text('1 reporte'), findsOneWidget);
    await tester.pumpWidget(host(QueueScreen(key: const ValueKey('vacia'), fetch: () async => [], every: null)));
    await tester.pump();
    expect(find.text('0 reportes'), findsOneWidget);
    expect(find.text('Sin reportes todavía'), findsOneWidget);
  });

  testWidgets('si el nodo no responde avisa y conserva lo último que vio', (tester) async {
    var up = true;
    await tester.pumpWidget(host(QueueScreen(
      fetch: () async {
        if (!up) throw Exception('sin red');
        return [item('a-1', 'P1')];
      },
      every: const Duration(milliseconds: 100),
    )));
    await tester.pump();
    expect(find.byKey(const Key('item_a-1')), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsNothing);
    up = false;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('Sin conexión'), findsOneWidget);
    expect(find.byKey(const Key('item_a-1')), findsOneWidget, reason: 'la vista parcial no se borra');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('un P1 nunca queda fuera de la vista inicial aunque haya cientos de reportes', (tester) async {
    final items = [
      item('p1-1', 'P1'),
      for (var i = 0; i < 300; i++) item('r$i-1', 'P4'),
    ];
    await tester.pumpWidget(host(QueueScreen(fetch: () async => items, every: null)));
    await tester.pump();
    expect(find.byKey(const Key('item_p1-1')), findsOneWidget);
    expect(find.text('301 reportes'), findsOneWidget);
  });
}
