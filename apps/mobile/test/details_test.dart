import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000000);
DateTime now = t0;

void main() {
  late Outbox outbox;
  setUp(() {
    outbox = Outbox.open(':memory:', key: key);
    now = t0;
  });
  tearDown(() => outbox.close());

  Future<void> boot(WidgetTester tester, {Future<int?> Function()? battery, Duration? refreshEvery}) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(411 * 2.625, 914 * 2.625);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SardApp(outbox: outbox, refreshEvery: refreshEvery, clock: () => now, battery: battery));
    await tester.pump();
  }

  List<ReportFrame> frames() => [for (final e in outbox.all()) decodeReportFrame(e.frame, key)];
  Finder people(PeopleBucket b) => find.byKey(Key('people_${b.code}'));
  Finder field() => find.byKey(const Key('phrase_field'));
  Finder sendPhrase() => find.byKey(const Key('send_phrase'));
  /// Como lo haría una persona: desplaza hasta que el control se vea y entonces lo toca.
  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await tester.pump();
  }

  Future<void> sos(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('sos_button'))); // por si la lista quedó desplazada
    await tester.pump();
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
  }

  group('¿Cuántas personas?', () {
    testWidgets('hay cinco rangos (1, 2–5, 6–20, 21–100, Más de 100) y «No indicado» no es una opción que tocar', (tester) async {
      await boot(tester);
      expect(find.text('¿Cuántas personas?'), findsOneWidget);
      for (final b in PeopleBucket.values.where((b) => b != PeopleBucket.unknown)) {
        expect(people(b), findsOneWidget, reason: b.label);
      }
      expect(people(PeopleBucket.unknown), findsNothing);
    });

    testWidgets('marcado ANTES del SOS, viaja en la revisión 0', (tester) async {
      await boot(tester);
      await tester.tap(people(PeopleBucket.twoToFive));
      await sos(tester);
      final f = frames().single;
      expect(f.rev, 0);
      expect(f.peopleBucket, PeopleBucket.twoToFive.code);
    });

    testWidgets('sin marcar nada, el SOS sale con «No indicado» (0): el SOS nunca pide datos', (tester) async {
      await boot(tester);
      await sos(tester);
      expect(frames().single.peopleBucket, 0);
    });

    testWidgets('es de selección única: marcar otro rango sustituye al anterior, y tocar el marcado lo quita', (tester) async {
      await boot(tester);
      await tester.tap(people(PeopleBucket.one));
      await tester.tap(people(PeopleBucket.sixToTwenty));
      await sos(tester);
      expect(frames().single.peopleBucket, PeopleBucket.sixToTwenty.code);

      now = now.add(const Duration(minutes: 20)); // el aviso anterior ya no está vivo
      await tester.tap(people(PeopleBucket.one));
      await tester.tap(people(PeopleBucket.one));
      await sos(tester);
      expect(frames().last.peopleBucket, 0);
    });

    testWidgets('marcado DESPUÉS del SOS (aviso vivo), sale enseguida como revisión del MISMO reporte', (tester) async {
      await boot(tester);
      await sos(tester);
      now = now.add(const Duration(seconds: 30));
      await tester.tap(people(PeopleBucket.sixToTwenty));
      await tester.pump();
      final all = outbox.all();
      expect(all, hasLength(2));
      expect(all[1].rev, 1);
      expect(all[1].reportKey, all[0].reportKey);
      expect(frames()[1].peopleBucket, PeopleBucket.sixToTwenty.code);
    });

    testWidgets('después del SOS se puede CORREGIR el rango (otra revisión con el nuevo), pero tocar el ya enviado no repite nada', (tester) async {
      await boot(tester);
      await sos(tester);
      now = now.add(const Duration(seconds: 10));
      await tester.tap(people(PeopleBucket.twoToFive));
      await tester.pump();
      await tester.tap(people(PeopleBucket.twoToFive));
      await tester.pump();
      expect(outbox.all(), hasLength(2), reason: 'el mismo rango otra vez no genera otra trama');
      await tester.tap(people(PeopleBucket.sixToTwenty));
      await tester.pump();
      expect(outbox.all(), hasLength(3));
      expect(frames().last.peopleBucket, PeopleBucket.sixToTwenty.code);
    });

    testWidgets('las revisiones posteriores (otro indicador) llevan las personas vigentes y las banderas unidas', (tester) async {
      await boot(tester);
      await tester.tap(people(PeopleBucket.twoToFive));
      await tester.tap(find.byKey(const Key('flag_atrapado')));
      await sos(tester);
      now = now.add(const Duration(seconds: 30));
      await tester.tap(find.byKey(const Key('flag_herido')));
      await tester.pump();
      final last = frames().last;
      expect(last.rev, 1);
      expect(last.peopleBucket, PeopleBucket.twoToFive.code, reason: 'las personas no se pierden al añadir un indicador');
      expect(last.flags, SituationFlags.atrapado | SituationFlags.herido);
    });

    testWidgets('el rango enviado se ve marcado como enviado (no sólo por color)', (tester) async {
      await boot(tester);
      await sos(tester);
      now = now.add(const Duration(seconds: 5));
      await tester.tap(people(PeopleBucket.one));
      await tester.pump();
      expect(find.descendant(of: people(PeopleBucket.one), matching: find.byIcon(Icons.check_circle)), findsOneWidget);
    });
  });

  group('Una frase (opcional, sólo con un aviso vivo)', () {
    testWidgets('el SOS NO lleva texto: el campo no se ofrece como paso previo', (tester) async {
      await boot(tester);
      await sos(tester);
      expect(frames().single.text, isNull);
    });

    testWidgets('sin aviso vivo, el botón «Enviar frase» está desactivado aunque se escriba', (tester) async {
      await boot(tester);
      await tester.enterText(field(), 'hay una persona atrapada');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(sendPhrase()).onPressed, isNull);
    });

    testWidgets('con aviso vivo y texto, «Enviar frase» envía UNA revisión con el texto', (tester) async {
      await boot(tester);
      await sos(tester);
      now = now.add(const Duration(seconds: 20));
      await tester.enterText(field(), 'mi mamá no puede salir del segundo piso');
      await tester.pump();
      await tapVisible(tester, sendPhrase());
      final all = outbox.all();
      expect(all, hasLength(2));
      expect(all[1].rev, 1);
      expect(all[1].reportKey, all[0].reportKey);
      expect(frames()[1].text, 'mi mamá no puede salir del segundo piso');
    });

    testWidgets('un texto vacío o sólo espacios no se envía (el botón sigue desactivado)', (tester) async {
      await boot(tester);
      await sos(tester);
      await tester.enterText(field(), '   ');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(sendPhrase()).onPressed, isNull);
    });

    testWidgets('el texto se recorta de espacios y, enviado, el campo queda vacío y listo para otra frase', (tester) async {
      await boot(tester);
      await sos(tester);
      await tester.enterText(field(), '  hay humo  ');
      await tester.pump();
      await tapVisible(tester, sendPhrase());
      expect(frames().last.text, 'hay humo');
      expect(tester.widget<TextField>(field()).controller!.text, '');
      expect(tester.widget<ElevatedButton>(sendPhrase()).onPressed, isNull, reason: 'vacío otra vez');
    });

    testWidgets('el aviso deja de estar vivo a los 10 min: ya no se puede enviar la frase', (tester) async {
      await boot(tester);
      await sos(tester);
      await tester.enterText(field(), 'hay humo');
      await tester.pump();
      now = now.add(const Duration(minutes: 11));
      await tester.pump();
      // el botón se reevalúa con el reloj: lo que se lee ahora ya no vale
      await tapVisible(tester, sendPhrase());
      expect(outbox.all(), hasLength(1), reason: 'no se mezcla una frase con un aviso que ya no está en curso');
    });

    testWidgets('no se puede escribir de más de 140 BYTES: la letra con tilde y el emoji pesan más que 1', (tester) async {
      await boot(tester);
      await sos(tester);
      // 100 letras «ñ» pesan 200 bytes: sólo caben 70
      await tester.enterText(field(), 'ñ' * 100);
      await tester.pump();
      final text = tester.widget<TextField>(field()).controller!.text;
      expect(utf8.encode(text).length, lessThanOrEqualTo(kMaxTextBytes));
      expect(text.length, 70);
      // el emoji (4 bytes) no se parte a la mitad
      await tester.enterText(field(), 'a' * 138 + '🔥');
      await tester.pump();
      final t2 = tester.widget<TextField>(field()).controller!.text;
      expect(utf8.encode(t2).length, lessThanOrEqualTo(kMaxTextBytes));
      expect(t2, isNot(contains('�')));
      expect(t2.runes.every((r) => r != 0xD83D && r != 0xDD25 || r > 0xFFFF), isTrue);
    });

    testWidgets('la confirmación «Frase enviada» aparece al enviar y NO sobrevive a un aviso nuevo', (tester) async {
      await boot(tester);
      await sos(tester);
      await tester.enterText(field(), 'hay humo');
      await tester.pump();
      expect(find.textContaining('Frase enviada'), findsNothing);
      await tapVisible(tester, sendPhrase());
      expect(find.text('Frase enviada: «hay humo»'), findsOneWidget);

      now = now.add(const Duration(minutes: 20)); // el aviso venció
      await sos(tester); // uno nuevo
      expect(find.textContaining('Frase enviada'), findsNothing, reason: 'la frase era del aviso anterior');
    });

    testWidgets('lo que cabe exactamente (140 B) se envía completo y decodifica', (tester) async {
      await boot(tester);
      await sos(tester);
      final exact = 'a' * kMaxTextBytes;
      await tester.enterText(field(), exact);
      await tester.pump();
      await tapVisible(tester, sendPhrase());
      expect(frames().last.text, exact);
    });

    testWidgets('lo escrito SOBREVIVE al refresco de cada segundo (y de cada 5 s en modo ahorro)', (tester) async {
      await boot(tester, refreshEvery: const Duration(seconds: 1));
      await sos(tester);
      await tester.enterText(field(), 'estamos en el techo');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.widget<TextField>(field()).controller!.text, 'estamos en el techo');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('en modo ahorro (15 %) también sobrevive, con refresco más lento', (tester) async {
      await boot(tester, battery: () async => 15, refreshEvery: const Duration(seconds: 1));
      await tester.pump();
      await sos(tester);
      await tester.enterText(field(), 'estamos en el techo');
      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.widget<TextField>(field()).controller!.text, 'estamos en el techo');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('un fallo al guardar la frase la conserva en el campo, avisa, y al reintentar sale', (tester) async {
      final dir = Directory.systemTemp.createTempSync('sard-phrasefail-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/outbox.db';
      final locked = Outbox.open(path, key: key);
      final blocker = sql.sqlite3.open(path);
      addTearDown(() {
        blocker.close();
        locked.close();
      });
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(411 * 2.625, 914 * 2.625);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SardApp(outbox: locked, refreshEvery: null, clock: () => now));
      await tester.pump();
      await sos(tester);
      await tester.enterText(field(), 'hay humo');
      await tester.pump();

      blocker.execute('BEGIN EXCLUSIVE'); // otra conexión retiene el bloqueo de escritura
      await tapVisible(tester, sendPhrase());
      expect(find.byKey(const Key('save_error')), findsOneWidget);
      expect(tester.widget<TextField>(field()).controller!.text, 'hay humo', reason: 'no se pierde lo escrito');
      expect(locked.all(), hasLength(1));

      blocker.execute('COMMIT');
      await tapVisible(tester, sendPhrase());
      expect(locked.all(), hasLength(2));
      expect(find.byKey(const Key('save_error')), findsNothing);
    });
  });

  group('con el teclado abierto', () {
    testWidgets('el campo queda por encima del teclado, y arrastrar la lista lo cierra para volver a alcanzar el SOS', (tester) async {
      await boot(tester);
      await sos(tester);
      tester.view.viewInsets = FakeViewPadding(bottom: 320 * 2.625); // teclado de 320 dp
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();

      await tester.ensureVisible(field());
      await tester.pump();
      await tester.tap(field());
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue, reason: 'tocar el campo abre el teclado');
      const usable = 914.0 - 320.0;
      expect(tester.getRect(field()).bottom, lessThanOrEqualTo(usable), reason: 'el campo no queda tapado por el teclado');

      await tester.enterText(field(), 'hay humo');
      await tester.pump();
      await tester.ensureVisible(sendPhrase());
      await tester.pump();
      expect(tester.getRect(sendPhrase()).bottom, lessThanOrEqualTo(usable), reason: 'el botón de enviar tampoco');

      // Arrastrar la lista hacia abajo cierra el teclado y deja el SOS a un gesto de distancia.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse, reason: 'arrastrar cierra el teclado');
      expect(find.byKey(const Key('sos_button')).hitTestable(), findsOneWidget, reason: 'el SOS vuelve a poder tocarse');
    });
  });

  group('en «sólo SOS» (batería < 5 %) no hay personas ni frase', () {
    testWidgets('ni los rangos ni el campo se ofrecen', (tester) async {
      await boot(tester, battery: () async => 3);
      await tester.pump();
      expect(find.byKey(const Key('people_2')), findsNothing);
      expect(field(), findsNothing);
      expect(sendPhrase(), findsNothing);
      expect(find.byKey(const Key('sos_button')), findsOneWidget);
    });
  });

  group('el historial muestra lo que se dijo', () {
    testWidgets('el aviso lista el rango de personas', (tester) async {
      await boot(tester, refreshEvery: const Duration(seconds: 1));
      await tester.tap(people(PeopleBucket.twoToFive));
      await sos(tester);
      // El aviso ya salió (acuse del nodo) y pasaron 30 min: deja de ser el grande y pasa al historial.
      outbox.applyAck(Ack(deviceId: outbox.deviceId, ackSeq: outbox.all().last.frameSeq, bitmap: 0));
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(seconds: 2));
      // el historial queda bajo el pliegue: se desplaza hasta verlo, como haría la persona
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pump();
      expect(find.textContaining('2–5 personas'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('la frase enviada se conserva aunque una revisión posterior (ubicación) no la repita', (tester) async {
      await boot(tester, refreshEvery: const Duration(seconds: 1));
      await sos(tester);
      now = now.add(const Duration(seconds: 20));
      await tester.enterText(field(), 'hay humo en el segundo piso');
      await tester.pump();
      await tapVisible(tester, sendPhrase());
      final key0 = outbox.all().first.reportKey;
      outbox.enqueueRevision(
        key0,
        const NewReport(incidentType: 1, flags: 0, peopleBucket: 0, batteryQ: 8, locQuality: LocQuality.within50m, lat: 5.07, lon: -75.51),
        now: now,
      );
      outbox.applyAck(Ack(deviceId: outbox.deviceId, ackSeq: outbox.all().last.frameSeq, bitmap: 3)); // la 3 y las dos anteriores
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(seconds: 2));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pump();
      expect(find.textContaining('hay humo en el segundo piso'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
