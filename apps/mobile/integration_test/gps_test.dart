import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_mobile/main.dart' as app;

/// Requisitos previos (los pone el script de verificación, no la prueba):
///  - un nodo en marcha con una carpeta de datos nueva;
///  - el permiso de ubicación concedido a la app y el dispositivo con ubicación fijada en
///    5.0703, -75.5138 (Android: `adb emu geo fix -75.5138 5.0703`; iOS: `xcrun simctl location ID set 5.0703,-75.5138`).
/// Se lanza con `--dart-define=NODES=<url del nodo>`.
const String _node = String.fromEnvironment(
  'NODES',
  defaultValue: 'http://localhost:8081',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'main real con GPS: el SOS llega al nodo con la ubicación del dispositivo',
    (tester) async {
      final dir = await getApplicationDocumentsDirectory();
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File(p.join(dir.path, 'outbox.db$suffix'));
        if (f.existsSync()) f.deleteSync();
      }
      final client = http.Client();
      app.main();
      for (
        var i = 0;
        i < 50 && find.byKey(const Key('sos_button')).evaluate().isEmpty;
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

      Map<String, Object?>? item;
      for (var i = 0; i < 100 && item == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final queue = await tester.runAsync(() async {
          final r = await client.get(Uri.parse('$_node/api/queue'));
          return (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
        });
        item = queue!.where((q) => q['lat'] != null).firstOrNull;
      }
      expect(
        item,
        isNotNull,
        reason:
            'el nodo nunca recibió coordenadas: ¿permiso de ubicación y ubicación fijada?',
      );
      expect((item!['lat']! as num).toDouble(), closeTo(5.0703, 0.01));
      expect((item['lon']! as num).toDouble(), closeTo(-75.5138, 0.01));
    },
  );
}
