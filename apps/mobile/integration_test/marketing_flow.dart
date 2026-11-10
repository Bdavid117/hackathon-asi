// Recorrido PAUSADO de la app para grabar el video de presentación (no es una prueba de regresión: se ejecuta a mano y por eso no se llama *_test.dart).
//   flutter test integration_test/marketing_flow.dart -d ID_SIMULADOR --dart-define=NODES=http://localhost:8081
// con un nodo en marcha (bash tool/expo.sh) y la grabación del simulador en otra terminal (xcrun simctl io ID recordVideo archivo.mov).
// La señal se «corta» con un canal con compuerta: el SOS se guarda, queda «Esperando señal» y sale solo al abrirla, que es lo que se cuenta.
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
import 'package:sard_protocol/sard_protocol.dart';

const String _node = String.fromEnvironment('NODES', defaultValue: 'http://localhost:8081');

/// Un canal que no deja pasar nada hasta que se abre: la red «caída».
class _GateChannel implements Channel {
  _GateChannel(this.inner);

  final Channel inner;
  bool open = false;

  @override
  Future<Uint8List?> send(Uint8List frame) async => open ? inner.send(frame) : null;
}

Future<void> hold(WidgetTester t, int ms) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await t.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recorrido pausado para el video', (tester) async {
    final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
    final dir = await getApplicationDocumentsDirectory();
    final outbox = Outbox.open(p.join(dir.path, 'video-outbox-${DateTime.now().microsecondsSinceEpoch}.db'), key: key);
    final gate = _GateChannel(HttpChannel(Uri.parse(_node), http.Client()));
    final scheduler = SendScheduler(outbox: outbox, channel: gate, key: key);
    await tester.pumpWidget(SardApp(outbox: outbox, scheduler: scheduler, refreshEvery: const Duration(milliseconds: 250)));
    await hold(tester, 2500); // la pantalla de inicio

    await tester.tap(find.byKey(const Key('flag_atrapado')));
    await hold(tester, 900);
    await tester.tap(find.byKey(const Key('flag_herido')));
    await hold(tester, 1200);
    await tester.tap(find.byKey(const Key('sos_button')));
    await hold(tester, 3500); // «Guardado en tu teléfono» y, tras el primer intento fallido, «Esperando señal»

    gate.open = true; // vuelve la señal
    await tester.runAsync(scheduler.pump);
    for (var i = 0; i < 40 && find.text('Enviado a un nodo').evaluate().isEmpty; i++) {
      await hold(tester, 250);
    }
    await hold(tester, 3000); // «Enviado a un nodo»

    final people = find.byKey(const Key('people_2'));
    if (people.evaluate().isNotEmpty) {
      await tester.ensureVisible(people);
      await hold(tester, 800);
      await tester.tap(people);
      await hold(tester, 1800); // «2–5 personas» enviado como revisión del mismo reporte
    }
    final phrase = find.byKey(const Key('phrase_field'));
    if (phrase.evaluate().isNotEmpty) {
      await tester.ensureVisible(phrase);
      await hold(tester, 600);
      await tester.enterText(phrase, 'mi mamá no puede salir del segundo piso');
      await hold(tester, 1500);
      final send = find.byKey(const Key('send_phrase'));
      if (send.evaluate().isNotEmpty) {
        await tester.ensureVisible(send);
        await tester.tap(send);
        await hold(tester, 3000);
      }
    }
    outbox.close();
  });
}
