import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_mobile/state_labels.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);
DateTime now = t0;

void main() {
  late Outbox outbox;
  setUp(() {
    outbox = Outbox.open(':memory:', key: key);
    now = t0;
  });
  tearDown(() => outbox.close());

  Future<void> boot(WidgetTester tester, {Duration? refreshEvery}) =>
      tester.pumpWidget(
        SardApp(outbox: outbox, refreshEvery: refreshEvery, clock: () => now),
      );

  testWidgets(
    'un toque en SOS guarda el reporte y lo muestra como «Guardado en tu teléfono»',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      final e = outbox.all().single;
      expect(e.state, OutboxState.queued);
      expect(e.rev, 0);
      expect(find.text('Guardado en tu teléfono'), findsOneWidget);
    },
  );

  testWidgets('el chip «Atrapado» marcado antes del SOS viaja en la trama', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('flag_atrapado')));
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    final frame = decodeReportFrame(outbox.all().single.frame, key);
    expect(frame.flags & SituationFlags.atrapado, isNonZero);
    expect(frame.flags & SituationFlags.herido, isZero);
  });

  testWidgets(
    'tras el SOS se desmarcan los chips: el siguiente reporte empieza limpio',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('flag_herido')));
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.add(const Duration(seconds: 3)); // pasado el filtro anti-pánico
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      final flags = outbox
          .all()
          .map((e) => decodeReportFrame(e.frame, key).flags)
          .toList();
      expect(flags, [SituationFlags.herido, 0]);
    },
  );

  testWidgets('cuando llega el ACK la lista muestra «Enviado a un nodo»', (
    tester,
  ) async {
    await boot(tester, refreshEvery: const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    outbox.applyAck(Ack(deviceId: outbox.deviceId, ackSeq: 1, bitmap: 0));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Enviado a un nodo'), findsOneWidget);
    expect(find.text('Guardado en tu teléfono'), findsNothing);
    await tester.pumpWidget(
      const SizedBox(),
    ); // desmonta y cancela el temporizador
  });

  testWidgets(
    'al abrir con reportes ya guardados se muestran (sobreviven a reiniciar la app)',
    (tester) async {
      outbox.enqueueSos(
        const NewReport(
          incidentType: 1,
          flags: 0,
          peopleBucket: 0,
          batteryQ: 15,
          locQuality: LocQuality.none,
        ),
        now: t0,
      );
      await boot(tester);
      expect(find.byKey(const Key('report_1')), findsOneWidget);
    },
  );

  testWidgets(
    'el pánico (varios toques seguidos) crea un solo reporte, no uno por toque',
    (tester) async {
      await boot(tester);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.add(const Duration(milliseconds: 300));
      }
      await tester.pump();
      expect(outbox.all().length, 1);
    },
  );

  testWidgets('pasado el plazo anti-pánico, otro toque es otro reporte', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.byKey(const Key('sos_button')));
    now = now.add(const Duration(seconds: 3));
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    expect(outbox.all().length, 2);
  });

  testWidgets(
    'el toque de SOS pide el envío por la vía con control de red, no por un pump directo',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        SardApp(
          outbox: outbox,
          refreshEvery: null,
          clock: () => now,
          onNewReport: () async => requests++,
        ),
      );
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.tap(
        find.byKey(const Key('sos_button')),
      ); // pánico: no cuenta
      await tester.pump();
      expect(requests, 1);
    },
  );

  testWidgets(
    'si el reloj del teléfono retrocede (corrección de hora), el siguiente toque es un SOS nuevo, no «muy reciente»',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.subtract(const Duration(hours: 1));
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(outbox.all().length, 2);
    },
  );

  testWidgets(
    'banderas nuevas dentro de la ventana: una revisión del MISMO reporte con la unión de banderas',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.add(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('flag_atrapado')));
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.add(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('flag_herido')));
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      final fs = [
        for (final e in outbox.all()) decodeReportFrame(e.frame, key),
      ];
      expect(fs.length, 3);
      expect(
        fs.map((f) => f.reportKey).toSet().length,
        1,
        reason: 'todo es un solo reporte',
      );
      expect(fs.map((f) => f.rev), [0, 1, 2]);
      expect(fs[1].flags, SituationFlags.atrapado);
      expect(
        fs[2].flags,
        SituationFlags.atrapado | SituationFlags.herido,
        reason: 'la revisión lleva la unión, no sólo lo último',
      );
    },
  );

  testWidgets(
    'repetir las mismas banderas dentro de la ventana no genera nada',
    (tester) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('flag_atrapado')));
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.add(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('flag_atrapado')));
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(outbox.all().length, 1);
    },
  );

  testWidgets(
    'si guardar falla se avisa, y un reintento inmediato NO se descarta como duplicado',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('sard-sosfail-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/outbox.db';
      final locked = Outbox.open(path, key: key);
      final blocker = sql.sqlite3.open(path);
      addTearDown(() {
        blocker.close();
        locked.close();
      });
      await tester.pumpWidget(
        SardApp(outbox: locked, refreshEvery: null, clock: () => now),
      );
      await tester.pumpAndSettle();

      blocker.execute(
        'BEGIN EXCLUSIVE',
      ); // otra conexión retiene el bloqueo de escritura (disco ocupado)
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(
        find.byKey(const Key('save_error')),
        findsOneWidget,
        reason: 'no se debe fingir que se guardó',
      );
      expect(locked.all(), isEmpty);

      blocker.execute('COMMIT'); // se libera el bloqueo
      now = now.add(
        const Duration(milliseconds: 500),
      ); // dentro de los 2 s anti-pánico
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(
        locked.all().length,
        1,
        reason: 'un SOS que no llegó a guardarse no cuenta como «ya enviado»',
      );
      expect(find.byKey(const Key('save_error')), findsNothing);
    },
  );

  group('stateLabel', () {
    OutboxEntry entry(OutboxState s, int attempts) => OutboxEntry(
      frameSeq: 1,
      reportKey: 'k',
      rev: 0,
      prioHint: 0,
      state: s,
      attempts: attempts,
      nextTryAt: null,
      frame: Uint8List(0),
      createdAt: t0,
    );
    test('textos de la tabla del PDF §5.4', () {
      expect(
        stateLabel(entry(OutboxState.queued, 0)),
        'Guardado en tu teléfono',
      );
      expect(stateLabel(entry(OutboxState.queued, 2)), 'Esperando señal');
      expect(stateLabel(entry(OutboxState.sending, 0)), 'Enviando…');
      expect(stateLabel(entry(OutboxState.sent, 0)), 'Enviado a un nodo');
      expect(stateLabel(entry(OutboxState.confirmed, 0)), 'Recibido por SARD');
      expect(
        stateLabel(entry(OutboxState.expired, 0)),
        'Se enviará cuando haya señal',
      );
    });
  });
}
