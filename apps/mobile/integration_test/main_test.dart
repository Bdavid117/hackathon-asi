import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_mobile/main.dart' as app;

/// Ejecuta el `main()` REAL de la app (path_provider, planificador periódico, canal HTTP),
/// no un `SardApp` armado a mano. Se lanza con
/// `flutter test integration_test/main_test.dart -d ID_DISPOSITIVO --dart-define=NODES=http://localhost:8081`.
const String _node = String.fromEnvironment('NODES', defaultValue: 'http://localhost:8081');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('main real: arranca, el SOS se guarda y llega al nodo, que lo normaliza y lo triaja', (tester) async {
    // Estado limpio: borra la bandeja que dejó una ejecución anterior.
    final dir = await getApplicationDocumentsDirectory();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File(p.join(dir.path, 'outbox.db$suffix'));
      if (f.existsSync()) f.deleteSync();
    }
    final client = http.Client();
    Future<List<Object?>> events() async => await tester.runAsync(() async {
          final r = await client.get(Uri.parse('$_node/api/events?origin=A&after=0&limit=1000'));
          return jsonDecode(r.body) as List<Object?>;
        }) as List<Object?>;
    final before = (await events()).length;

    app.main();
    for (var i = 0; i < 50 && find.byKey(const Key('sos_button')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('sos_button')), findsOneWidget, reason: 'el main real debe llegar a mostrar la app');

    await tester.tap(find.byKey(const Key('flag_herido')));
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();

    var sent = false;
    for (var i = 0; i < 150 && !sent; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 200));
      sent = find.text('Enviado a un nodo').evaluate().isNotEmpty;
    }
    expect(sent, isTrue, reason: 'el nodo en $_node no acusó la trama enviada por el main real');

    final added = ((await events()).skip(before)).cast<Map<String, Object?>>().map((e) => e['type']).toList();
    expect(added, ['report.received', 'report.normalized', 'triage.assessed']);
  });
}
