import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_mobile/reports_screen.dart';
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

  Future<void> boot(
    WidgetTester tester, {
    ValueListenable<bool>? online,
  }) async {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(411 * 2.625, 914 * 2.625);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SardApp(
        outbox: outbox,
        refreshEvery: null,
        clock: () => now,
        online: online,
      ),
    );
    await tester.pump();
  }

  List<ReportFrame> frames() => [
    for (final e in outbox.all()) outbox.reportOf(e),
  ];

  group('detalles después del SOS: primero lo urgente, luego se cuenta qué pasa', () {
    testWidgets(
      'un indicador tocado tras el SOS sale solo, como actualización del MISMO aviso',
      (tester) async {
        await boot(tester);
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_herido')));
        await tester.pump();
        final all = outbox.all();
        expect(
          all,
          hasLength(2),
          reason: 'SOS + una actualización, sin volver a tocar SOS',
        );
        expect(all.map((e) => e.reportKey).toSet(), hasLength(1));
        expect(frames()[1].rev, 1);
        expect(frames()[1].flags, SituationFlags.herido);
      },
    );

    testWidgets(
      'los detalles se acumulan: la actualización lleva todo lo marcado hasta ahora',
      (tester) async {
        await boot(tester);
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_herido')));
        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_atrapado')));
        await tester.pump();
        expect(
          frames().last.flags,
          SituationFlags.herido | SituationFlags.atrapado,
        );
      },
    );

    testWidgets(
      'lo que ya salió no se puede quitar: tocar un indicador enviado no hace nada',
      (tester) async {
        await boot(tester);
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_herido')));
        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_herido')));
        await tester.pump();
        expect(outbox.all(), hasLength(2));
      },
    );

    testWidgets(
      'pasados 10 minutos el aviso ya no está vivo: el indicador sólo se marca para el próximo SOS',
      (tester) async {
        await boot(tester);
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.add(const Duration(minutes: 11));
        await tester.tap(find.byKey(const Key('flag_incendio')));
        await tester.pump();
        expect(
          outbox.all(),
          hasLength(1),
          reason: 'no se manda nada hasta que se toque SOS',
        );
        await tester.tap(find.byKey(const Key('sos_button')));
        await tester.pump();
        expect(frames().last.flags, SituationFlags.incendio);
        expect(
          outbox.all().map((e) => e.reportKey).toSet(),
          hasLength(2),
          reason: 'es un SOS nuevo',
        );
      },
    );

    testWidgets(
      'si el reloj retrocede, un indicador no se pega a un aviso «vivo» imposible de medir',
      (tester) async {
        await boot(tester);
        await tester.tap(find.byKey(const Key('sos_button')));
        now = now.subtract(const Duration(hours: 1));
        await tester.tap(find.byKey(const Key('flag_incendio')));
        await tester.pump();
        expect(outbox.all(), hasLength(1));
      },
    );

    testWidgets('si guardar la actualización falla se avisa', (tester) async {
      final dir = Directory.systemTemp.createTempSync('sard-ux-');
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
      await tester.pumpWidget(
        SardApp(outbox: locked, refreshEvery: null, clock: () => now),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(locked.all(), hasLength(1));
      blocker.execute(
        'BEGIN EXCLUSIVE',
      ); // otra conexión retiene el bloqueo de escritura
      now = now.add(const Duration(seconds: 30));
      await tester.tap(find.byKey(const Key('flag_herido')));
      await tester.pump();
      expect(
        find.byKey(const Key('save_error')),
        findsOneWidget,
        reason: 'no se debe fingir que se guardó',
      );
      blocker.execute('ROLLBACK');
    });
  });

  group('un aviso, una tarjeta', () {
    testWidgets(
      'tras el SOS el estado aparece justo debajo del botón, con lo que hay que hacer (nada)',
      (tester) async {
        await boot(tester);
        expect(
          find.text(kSosHintForTest),
          findsOneWidget,
          reason: 'sin avisos se explica el botón',
        );
        await tester.tap(find.byKey(const Key('sos_button')));
        await tester.pump();
        expect(find.byKey(const Key('last_status')), findsOneWidget);
        expect(find.text('Guardado en tu teléfono'), findsOneWidget);
        expect(
          find.textContaining('No hace falta volver a tocar'),
          findsOneWidget,
        );
        expect(find.text(kSosHintForTest), findsNothing);
      },
    );

    testWidgets('la ubicación que llega después no crea otra tarjeta', (
      tester,
    ) async {
      await boot(tester);
      await tester.tap(find.byKey(const Key('sos_button')));
      final key0 = outbox.all().single.reportKey;
      outbox.enqueueRevision(
        key0,
        const NewReport(
          incidentType: 1,
          flags: 0,
          peopleBucket: 0,
          batteryQ: 5,
          locQuality: LocQuality.within50m,
          lat: 5.07,
          lon: -75.51,
        ),
        now: now,
      );
      await tester.pump();
      await tester.pumpWidget(
        SardApp(outbox: outbox, refreshEvery: null, clock: () => now),
      );
      await tester.pump();
      expect(find.byKey(const Key('last_status')), findsOneWidget);
      expect(find.textContaining('Detalle #'), findsNothing);
      expect(find.text('Con ubicación'), findsOneWidget);
    });

    testWidgets('una actualización pendiente se dice con claridad', (
      tester,
    ) async {
      final sos = outbox.enqueueSos(
        const NewReport(
          incidentType: 1,
          flags: 0,
          peopleBucket: 0,
          batteryQ: 5,
          locQuality: LocQuality.none,
        ),
        now: now,
      );
      outbox.enqueueRevision(
        sos.reportKey,
        const NewReport(
          incidentType: 1,
          flags: 0x40,
          peopleBucket: 0,
          batteryQ: 5,
          locQuality: LocQuality.none,
        ),
        now: now,
      );
      outbox.applyAck(
        Ack(deviceId: outbox.deviceId, ackSeq: sos.frameSeq, bitmap: 0),
      );
      await boot(tester);
      expect(find.text('Enviado a un nodo'), findsOneWidget);
      expect(find.byKey(const Key('update_pending')), findsOneWidget);
    });

    testWidgets(
      'un aviso viejo y ya enviado pasa al historial «Tus avisos»; el nuevo va grande',
      (tester) async {
        final old = outbox.enqueueSos(
          const NewReport(
            incidentType: 1,
            flags: 0x40,
            peopleBucket: 0,
            batteryQ: 5,
            locQuality: LocQuality.none,
          ),
          now: t0,
        );
        outbox.applyAck(
          Ack(deviceId: outbox.deviceId, ackSeq: old.frameSeq, bitmap: 0),
        );
        now = t0.add(const Duration(hours: 2));
        await boot(tester);
        expect(
          find.byKey(const Key('last_status')),
          findsNothing,
          reason: 'nada en curso que destacar',
        );
        expect(find.text('Tus avisos'), findsOneWidget);
        expect(find.textContaining('SOS de las'), findsOneWidget);
        await tester.tap(find.byKey(const Key('sos_button')));
        await tester.pump();
        expect(find.byKey(const Key('last_status')), findsOneWidget);
        expect(find.text('Tus avisos'), findsOneWidget);
      },
    );
  });

  group('la pantalla no se mueve bajo el dedo', () {
    // Hallazgo de la prueba manual: tocar «Atrapado» y luego «Herido» fallaba porque, al llegar el
    // GPS, la tarjeta de estado crecía y empujaba la cuadrícula. Los indicadores deben quedarse
    // EXACTAMENTE donde están pase lo que pase con el aviso.
    testWidgets(
      'los indicadores no se mueven con el SOS, el GPS, el acuse del nodo ni los detalles',
      (tester) async {
        tester.view.devicePixelRatio = 2.625;
        tester.view.physicalSize = const Size(411 * 2.625, 914 * 2.625);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          SardApp(
            outbox: outbox,
            refreshEvery: const Duration(milliseconds: 100),
            clock: () => now,
          ),
        );
        await tester.pump();
        Rect herido() => tester.getRect(find.byKey(const Key('flag_herido')));
        final inicial = herido();

        await tester.tap(find.byKey(const Key('sos_button')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          herido(),
          inicial,
          reason: 'tras el primer SOS (aparece la tarjeta de estado)',
        );

        final sos = outbox.all().single;
        outbox.enqueueRevision(
          sos.reportKey,
          const NewReport(
            incidentType: 1,
            flags: SituationFlags.atrapado,
            peopleBucket: 0,
            batteryQ: 5,
            locQuality: LocQuality.within50m,
            lat: 5.07,
            lon: -75.51,
          ),
          now: now,
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          herido(),
          inicial,
          reason: 'al llegar la ubicación y los detalles a la tarjeta',
        );

        outbox.applyAck(
          Ack(deviceId: outbox.deviceId, ackSeq: sos.frameSeq + 1, bitmap: 1),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          herido(),
          inicial,
          reason: 'al pasar de «Guardado» a «Enviado a un nodo»',
        );

        now = now.add(const Duration(seconds: 30));
        await tester.tap(find.byKey(const Key('flag_incendio')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          herido(),
          inicial,
          reason: 'al añadir un detalle después del SOS',
        );
      },
    );
  });

  group('sin señal', () {
    testWidgets(
      'el aviso aparece cuando no hay red y desaparece cuando vuelve',
      (tester) async {
        final online = ValueNotifier<bool>(true);
        await boot(tester, online: online);
        expect(find.byKey(const Key('offline_banner')), findsNothing);
        online.value = false;
        await tester.pump();
        expect(find.byKey(const Key('offline_banner')), findsOneWidget);
        expect(find.textContaining('saldrá solo'), findsOneWidget);
        online.value = true;
        await tester.pump();
        expect(find.byKey(const Key('offline_banner')), findsNothing);
      },
    );

    testWidgets('sin ese dato (null) no se afirma nada sobre la señal', (
      tester,
    ) async {
      await boot(tester);
      expect(find.byKey(const Key('offline_banner')), findsNothing);
    });
  });

  group('agoLabel', () {
    final at = DateTime(2026, 11, 8, 18, 7);
    test(
      'menos de un minuto: ahora mismo',
      () => expect(
        agoLabel(at.add(const Duration(seconds: 40)), at),
        'ahora mismo',
      ),
    );
    test(
      'minutos',
      () => expect(
        agoLabel(at.add(const Duration(minutes: 5)), at),
        'hace 5 min',
      ),
    );
    test(
      'más de una hora: la hora',
      () => expect(agoLabel(at.add(const Duration(hours: 2)), at), '18:07'),
    );
    test(
      'reloj que retrocede: nunca un tiempo negativo',
      () => expect(
        agoLabel(at.subtract(const Duration(hours: 1)), at),
        'ahora mismo',
      ),
    );
  });
}

const String kSosHintForTest =
    'Toca una vez. Se guarda y sale solo, aunque no tengas señal.';
