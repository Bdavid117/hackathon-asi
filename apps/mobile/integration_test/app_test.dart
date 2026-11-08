import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';

/// Se ejecuta en un dispositivo o simulador real, con un nodo en marcha:
/// `flutter test integration_test -d ID_DISPOSITIVO --dart-define=NODES=http://localhost:8081`
const String _node = String.fromEnvironment(
  'NODES',
  defaultValue: 'http://localhost:8081',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SOS en dispositivo: se guarda, llega al nodo real y sobrevive a reabrir la bandeja',
    (tester) async {
      final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(
        dir.path,
        'it-outbox-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final client = http.Client();

      var outbox = Outbox.open(
        path,
        key: key,
      ); // sqlite3 nativo en el dispositivo
      final scheduler = SendScheduler(
        outbox: outbox,
        channel: HttpChannel(Uri.parse(_node), client),
        key: key,
      );
      await tester.pumpWidget(
        SardApp(
          outbox: outbox,
          scheduler: scheduler,
          refreshEvery: const Duration(milliseconds: 200),
        ),
      );

      await tester.tap(find.byKey(const Key('flag_atrapado')));
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(
        outbox.all().length,
        1,
        reason: 'el reporte debe estar guardado antes de cualquier envío',
      );

      // Espera (hasta 20 s) a que el nodo acuse la trama.
      var sent = false;
      for (var i = 0; i < 100 && !sent; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        sent = find.text('Enviado a un nodo').evaluate().isNotEmpty;
      }
      expect(sent, isTrue, reason: 'el nodo en $_node no acusó la trama');

      // El nodo real tiene el reporte.
      final queue = await tester.runAsync(() async {
        final r = await client.get(Uri.parse('$_node/api/queue'));
        return jsonDecode(r.body) as List<Object?>;
      });
      expect(
        queue!.cast<Map<String, Object?>>().any(
          (i) =>
              i['urgency'] == 'P2' &&
              (i['signals'] as List).contains('atrapado'),
        ),
        isTrue,
      );

      // «Matar y reabrir la app»: se desmonta todo y se abre la misma base.
      await tester.pumpWidget(const SizedBox());
      outbox.close();
      outbox = Outbox.open(path, key: key);
      final back = outbox.all().single;
      expect(back.state, OutboxState.sent);
      expect(back.rev, 0);
      outbox.close();
    },
  );
}
