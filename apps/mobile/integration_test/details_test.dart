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
/// `flutter test integration_test/details_test.dart -d ID_DISPOSITIVO --dart-define=NODES=http://localhost:8081`
const String _node = String.fromEnvironment('NODES', defaultValue: 'http://localhost:8081');
const String _phrase = 'hay una persona atrapada bajo la losa del segundo piso';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SOS → «2–5» → una frase: el nodo real muestra las personas, el texto y el triaje que sale del texto',
    (tester) async {
      final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, 'it-details-${DateTime.now().microsecondsSinceEpoch}.db');
      final client = http.Client();
      final outbox = Outbox.open(path, key: key);
      final scheduler = SendScheduler(outbox: outbox, channel: HttpChannel(Uri.parse(_node), client), key: key);
      await tester.pumpWidget(SardApp(outbox: outbox, scheduler: scheduler, refreshEvery: const Duration(milliseconds: 200)));

      Future<void> wait(Future<bool> Function() done, String what) async {
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          await tester.pump(const Duration(milliseconds: 200));
          if (await tester.runAsync(done) ?? false) return;
        }
        fail('no ocurrió a tiempo: $what');
      }

      Future<Map<String, Object?>?> nodeItem(String reportKey) async {
        final r = await client.get(Uri.parse('$_node/api/queue'));
        for (final i in (jsonDecode(r.body) as List).cast<Map<String, Object?>>()) {
          if (i['reportKey'] == reportKey) return i;
        }
        return null;
      }

      // 1. SOS de un toque, sin datos: sale solo y el nodo lo tiene.
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      final reportKey = outbox.all().single.reportKey;
      await wait(() async => (await nodeItem(reportKey)) != null, 'el nodo debía tener el SOS');
      final sosOnly = (await tester.runAsync(() => nodeItem(reportKey)))!;
      expect(sosOnly['text'], isNull, reason: 'el SOS no lleva texto');
      expect(sosOnly['peopleLabel'], 'No indicado');

      // 2. Después del SOS: «2–5 personas».
      await tester.ensureVisible(find.byKey(const Key('people_2')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('people_2')));
      await tester.pump();

      // 3. Una frase con el aviso vivo.
      await tester.ensureVisible(find.byKey(const Key('phrase_field')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('phrase_field')), _phrase);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('send_phrase')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_phrase')));
      await tester.pump();
      expect(find.text('Frase enviada: «$_phrase»'), findsOneWidget);

      // 4. El nodo real lo muestra: personas, texto y el triaje que sale de la frase (con su cita).
      Map<String, Object?>? item;
      await wait(() async {
        item = await nodeItem(reportKey);
        return item != null && item!['text'] == _phrase && item!['peopleLabel'] == '2–5';
      }, 'el nodo debía mostrar las personas y la frase');
      expect(item!['text'], _phrase);
      expect(item!['people'], 2);
      expect(item!['peopleLabel'], '2–5');
      expect(item!['signals'], contains('atrapado'), reason: 'la frase dice «atrapada»: el triaje la lee');
      final quotes = [
        for (final e in (item!['evidence'] as List).cast<Map<String, Object?>>())
          if (e['quote'] != null) e['quote']! as String,
      ];
      expect(quotes, isNotEmpty, reason: 'el triaje cita el texto que lo justifica');
      for (final q in quotes) {
        expect(_phrase, contains(q), reason: 'una cita debe ser subcadena exacta de la frase');
      }
      // 5. Las tres tramas son del MISMO reporte (revisiones), no tres reportes.
      expect(outbox.all().map((e) => e.reportKey).toSet(), {reportKey});
      expect(outbox.all().map((e) => e.rev).toList(), [0, 1, 2]);

      await tester.pumpWidget(const SizedBox());
      client.close();
      outbox.close();
    },
  );
}
