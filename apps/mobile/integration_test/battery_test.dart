import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_mobile/main.dart' as app;

/// Comprueba que el `main()` real lee la batería de VERDAD (plugin `battery_plus`) y cambia de
/// modo. El script `tool/android_battery_check.sh` fija el nivel del emulador y pasa lo que se
/// espera con `--dart-define=EXPECT=normal|saver|sosOnly`.
const String _expect = String.fromEnvironment('EXPECT', defaultValue: 'normal');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('batería real → modo $_expect', (tester) async {
    final dir = await getApplicationDocumentsDirectory();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File(p.join(dir.path, 'outbox.db$suffix'));
      if (f.existsSync()) f.deleteSync();
    }
    app.main();
    for (
      var i = 0;
      i < 100 && find.byKey(const Key('sos_button')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('sos_button')), findsOneWidget);

    // La lectura de batería es asíncrona: se espera a que el banner aparezca (o a que se
    // agote el plazo si no debe aparecer).
    for (
      var i = 0;
      i < 40 && find.byKey(const Key('power_banner')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    switch (_expect) {
      case 'normal':
        expect(find.byKey(const Key('power_banner')), findsNothing);
        expect(find.byKey(const Key('flag_atrapado')), findsOneWidget);
      case 'saver':
        expect(find.text('Modo ahorro de batería'), findsOneWidget);
        expect(find.byKey(const Key('flag_atrapado')), findsOneWidget);
      case 'sosOnly':
        expect(find.text('Sólo SOS: batería muy baja'), findsOneWidget);
        expect(find.byKey(const Key('flag_atrapado')), findsNothing);
        expect(find.byKey(const Key('sos_button')), findsOneWidget);
      default:
        fail('EXPECT desconocido: $_expect');
    }
  });
}
