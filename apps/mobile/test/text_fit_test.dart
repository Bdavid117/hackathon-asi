import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_mobile/reports_screen.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'real_fonts.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);

/// Textos que se ven recortados con «…» en la tarjeta del aviso, medidos con Roboto real.
void main() {
  late Outbox outbox;
  setUpAll(loadRealFonts);
  setUp(() => outbox = Outbox.open(':memory:', key: key));
  tearDown(() => outbox.close());

  Future<void> boot(WidgetTester tester, double width) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = Size(width * 2.625, 914 * 2.625);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SardApp(outbox: outbox, refreshEvery: null, clock: () => t0));
    await tester.pump();
  }

  List<String> cut() => [
    for (final w in find.descendant(of: find.byType(IncidentCard), matching: find.byType(RichText)).evaluate())
      if ((w.renderObject! as RenderParagraph).didExceedMaxLines) (w.widget as RichText).text.toPlainText(),
  ];

  /// Cuánto se encoge la etiqueta de ubicación (1 = a tamaño natural): debajo del 90 % ya cuesta leerla.
  double locationScale(WidgetTester tester) {
    final text = find.textContaining(RegExp('(Con|Sin) ubicación'));
    final natural = tester.getSize(text).width;
    final shown = tester.getSize(find.ancestor(of: text, matching: find.byType(FittedBox)).first).width;
    return shown >= natural ? 1.0 : shown / natural;
  }

  test('sanidad: Roboto cargada, no Ahem (si esto falla, las demás pruebas de este archivo no miden nada)', () async {
    final p = TextPainter(text: const TextSpan(text: 'ahora mismo', style: TextStyle(fontFamily: 'Roboto', fontSize: 14)), textDirection: TextDirection.ltr)..layout();
    // Ahem: 11 letras × 14 = 154 px. Roboto: unos 70 px.
    expect(p.width, lessThan(100));
    expect(p.width, greaterThan(55));
  });

  group('ningún texto de la tarjeta del aviso se recorta con puntos suspensivos (Roboto real)', () {
    for (final width in [320.0, 360.0, 411.0]) {
      testWidgets('a $width dp, recién enviado el SOS (sin ubicación todavía)', (tester) async {
        await boot(tester, width);
        await tester.tap(find.byKey(const Key('sos_button')));
        await tester.pump();
        expect(find.textContaining('Sin ubicación'), findsOneWidget);
        expect(cut(), isEmpty);
        expect(locationScale(tester), greaterThanOrEqualTo(0.9), reason: 'la etiqueta no se encoge hasta ser ilegible');
      });

      testWidgets('a $width dp, con ubicación y con detalles marcados', (tester) async {
        outbox.enqueueSos(
          const NewReport(incidentType: 1, flags: 0x41, peopleBucket: 2, batteryQ: 5, locQuality: LocQuality.within50m, lat: 5.07, lon: -75.51),
          now: t0,
        );
        await boot(tester, width);
        expect(find.text('Con ubicación'), findsOneWidget);
        expect(cut(), isEmpty);
        expect(locationScale(tester), greaterThanOrEqualTo(0.9), reason: 'la etiqueta no se encoge hasta ser ilegible');
      });
    }
  });

  group('con la letra del sistema agrandada (accesibilidad) el pie de la tarjeta no se desborda', () {
    for (final scale in [1.3, 2.0]) {
      for (final width in [320.0, 411.0]) {
        testWidgets('letra ×$scale a $width dp, sin y con ubicación: la tarjeta (reports_screen.dart) no desborda', (tester) async {
          // Se recogen TODOS los errores de dibujo (takeException sólo da el primero) y se filtra por archivo.
          // `onError` se restaura en un finally DENTRO del test: con addTearDown, si un expect falla el binding se
          // cuelga («A test overrode FlutterError.onError…»).
          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          try {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await boot(tester, width);
            await tester.tap(find.byKey(const Key('sos_button')));
            await tester.pump();
            outbox.enqueueSos(
              const NewReport(incidentType: 1, flags: 0x41, peopleBucket: 2, batteryQ: 5, locQuality: LocQuality.within50m, lat: 5.07, lon: -75.51),
              now: t0,
            );
            await boot(tester, width);
          } finally {
            FlutterError.onError = previous;
            tester.platformDispatcher.clearAllTestValues();
          }
          final fromCard = [for (final e in errors) if (e.toString().contains('reports_screen.dart')) e.exceptionAsString().split('\n').first];
          expect(fromCard, isEmpty, reason: 'la tarjeta del aviso no puede desbordar con letra grande');
          if (scale <= 1.3) {
            expect(errors, isEmpty, reason: 'a ×1.3 la pantalla entera cabe');
          }
          // A ×2.0 la columna de chips de sos_screen.dart:307 se desborda 22 px (ya ocurría ANTES del cambio del pie:
          // se comprobó con 80e105d). Es un hallazgo abierto de accesibilidad, no de esta prueba.
        });
      }
    }
  });
}
