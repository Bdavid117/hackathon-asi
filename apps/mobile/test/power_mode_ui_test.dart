import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_protocol/sard_protocol.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000000);

void main() {
  late Outbox outbox;
  setUp(() => outbox = Outbox.open(':memory:', key: key));
  tearDown(() => outbox.close());

  Future<void> boot(WidgetTester tester, Future<int?> Function() battery) async {
    await tester.pumpWidget(SardApp(outbox: outbox, refreshEvery: null, clock: () => t0, battery: battery));
    await tester.pumpAndSettle();
  }

  testWidgets('con 15 % se avisa del modo ahorro y los indicadores siguen disponibles', (tester) async {
    await boot(tester, () async => 15);
    expect(find.byKey(const Key('power_banner')), findsOneWidget);
    expect(find.text('Modo ahorro de batería'), findsOneWidget);
    expect(find.byKey(const Key('flag_atrapado')), findsOneWidget);
  });

  testWidgets('con 3 % sólo queda el botón SOS: sin indicadores ni lista', (tester) async {
    await boot(tester, () async => 3);
    expect(find.text('Sólo SOS: batería muy baja'), findsOneWidget);
    expect(find.byKey(const Key('flag_atrapado')), findsNothing);
    expect(find.text('Aún no has enviado ningún reporte.'), findsNothing);
    expect(find.byKey(const Key('sos_button')), findsOneWidget);
  });

  testWidgets('en modo sólo SOS el SOS sigue guardando el reporte', (tester) async {
    await boot(tester, () async => 3);
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    expect(outbox.all().length, 1);
    expect(decodeReportFrame(outbox.all().single.frame, key).batteryQ, 0); // 3 % → 0 de 15
  });

  testWidgets('con 100 % no hay aviso', (tester) async {
    await boot(tester, () async => 100);
    expect(find.byKey(const Key('power_banner')), findsNothing);
  });

  testWidgets('batería desconocida (null): sin aviso y el reporte lleva el marcador 15', (tester) async {
    await boot(tester, () async => null);
    expect(find.byKey(const Key('power_banner')), findsNothing);
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    expect(decodeReportFrame(outbox.all().single.frame, key).batteryQ, 15);
  });

  testWidgets('si el lector de batería lanza una excepción el SOS funciona igual', (tester) async {
    await boot(tester, () async => throw Exception('sin plugin'));
    expect(find.byKey(const Key('power_banner')), findsNothing);
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    expect(outbox.all().length, 1);
  });

  testWidgets('con 50 % el reporte lleva batteryQ = 8', (tester) async {
    await boot(tester, () async => 50);
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pump();
    expect(decodeReportFrame(outbox.all().single.frame, key).batteryQ, 8);
  });
}
