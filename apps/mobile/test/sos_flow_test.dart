import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_mobile/state_labels.dart';
import 'package:sard_protocol/sard_protocol.dart';

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
