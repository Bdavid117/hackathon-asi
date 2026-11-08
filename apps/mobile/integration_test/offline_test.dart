import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_mobile/main.dart' as app;

/// Prueba del escenario central del enunciado: SOS sin conexión → queda guardado → al volver la
/// señal sale solo. La orquesta un script externo que apaga y enciende la red del dispositivo
/// al ver `SOS_TAPPED` en la salida (la red se apaga ANTES de lanzar la prueba). Se lanza con `--dart-define=NODES=<url del nodo>`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'main real sin red: el SOS se guarda y sale solo cuando vuelve la conectividad',
    (tester) async {
      final dir = await getApplicationDocumentsDirectory();
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File(p.join(dir.path, 'outbox.db$suffix'));
        if (f.existsSync()) f.deleteSync();
      }
      app.main();
      for (
        var i = 0;
        i < 80 && find.byKey(const Key('sos_button')).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('sos_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      // ignore: avoid_print
      print('SOS_TAPPED');
      final saved =
          find.text('Guardado en tu teléfono').evaluate().isNotEmpty ||
          find.text('Esperando señal').evaluate().isNotEmpty;
      expect(
        saved,
        isTrue,
        reason:
            'sin red el reporte queda guardado (o esperando señal), nunca perdido',
      );
      expect(
        find.text('Enviado a un nodo'),
        findsNothing,
        reason: 'sin red no puede haberse enviado',
      );

      var sent = false;
      for (var i = 0; i < 600 && !sent; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump(const Duration(milliseconds: 250));
        sent = find.text('Enviado a un nodo').evaluate().isNotEmpty;
      }
      // ignore: avoid_print
      print(sent ? 'SENT_AFTER_RECONNECT' : 'NEVER_SENT');
      expect(
        sent,
        isTrue,
        reason: 'al volver la red el reporte debía salir solo',
      );
    },
  );
}
