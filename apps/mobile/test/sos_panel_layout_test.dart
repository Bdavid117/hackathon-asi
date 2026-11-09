import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_mobile/sos_screen.dart';

/// Hallazgo de la prueba manual en el emulador: al marcar «Atrapado» el chip se ensanchaba (aparecía
/// la palomita) y todo el bloque se reacomodaba; el siguiente toque, dado donde estaba «Herido»,
/// caía sobre «Atrapado» y lo desmarcaba. En una emergencia los botones no pueden moverse.
void main() {
  Future<Map<String, Rect> Function()> montar(
    WidgetTester tester, {
    required double anchoDp,
  }) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = Size(anchoDp * 2.625, 2400);
    addTearDown(tester.view.reset);
    var selected = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            body: SosPanel(
              selected: selected,
              onToggle: (bit) => setState(() => selected ^= bit),
              onSos: () {},
            ),
          ),
        ),
      ),
    );
    return () => {
      for (final (key, _, _) in kFlagChips)
        key: tester.getRect(find.byKey(Key(key))),
    };
  }

  for (final ancho in [411.0, 360.0]) {
    testWidgets(
      'marcar cualquier indicador no mueve ningún botón (teléfono de $ancho dp)',
      (tester) async {
        final rects = await montar(tester, anchoDp: ancho);
        final antes = rects();
        for (final (key, _, _) in kFlagChips) {
          await tester.tap(find.byKey(Key(key)));
          await tester
              .pumpAndSettle(); // la palomita del chip se anima: hay que medir ya asentado
          expect(
            rects(),
            antes,
            reason: 'al marcar $key se movió o cambió de tamaño algún botón',
          );
        }
        // y desmarcarlos tampoco los mueve
        for (final (key, _, _) in kFlagChips) {
          await tester.tap(find.byKey(Key(key)));
          await tester
              .pumpAndSettle(); // la palomita del chip se anima: hay que medir ya asentado
          expect(
            rects(),
            antes,
            reason: 'al desmarcar $key se movió o cambió de tamaño algún botón',
          );
        }
      },
    );
  }

  testWidgets(
    'cada indicador es un objetivo táctil de al menos 48 dp y no se solapan',
    (tester) async {
      final rects = await montar(tester, anchoDp: 360);
      final todos = rects().values.toList();
      for (final r in todos) {
        expect(r.height, greaterThanOrEqualTo(48));
        expect(r.width, greaterThanOrEqualTo(48));
      }
      for (var i = 0; i < todos.length; i++) {
        for (var j = i + 1; j < todos.length; j++) {
          expect(
            todos[i].overlaps(todos[j]),
            isFalse,
            reason: 'los indicadores $i y $j se solapan',
          );
        }
      }
    },
  );

  testWidgets(
    'un indicador marcado se distingue sin depender sólo del color (icono)',
    (tester) async {
      await montar(tester, anchoDp: 411);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      await tester.tap(find.byKey(const Key('flag_herido')));
      await tester
          .pumpAndSettle(); // la palomita del chip se anima: hay que medir ya asentado
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    },
  );
}
