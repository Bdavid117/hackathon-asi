import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/app.dart';
import 'package:sard_protocol/sard_protocol.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000000);
DateTime now = t0;

class FakeLocation implements LocationProvider {
  FakeLocation({
    this.last,
    this.freshFix,
    this.throwOnLast = false,
    this.throwOnFresh = false,
    this.gate,
  });
  final LocationFix? last;
  final LocationFix? freshFix;
  final bool throwOnLast;
  final bool throwOnFresh;

  /// Si se da, `fresh` no responde hasta que se complete: controla CUÁNDO llega la lectura.
  final Completer<void>? gate;
  int freshCalls = 0;

  @override
  Future<LocationFix?> lastKnown() async {
    if (throwOnLast) throw Exception('sin permiso');
    return last;
  }

  @override
  Future<LocationFix?> fresh({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    freshCalls++;
    if (gate != null) await gate!.future;
    if (throwOnFresh) throw Exception('GPS apagado');
    return freshFix;
  }
}

LocationFix fix({
  required Duration ago,
  double accuracy = 20,
  double lat = 5.07,
  double lon = -75.51,
}) => LocationFix(
  lat: lat,
  lon: lon,
  accuracyMeters: accuracy,
  at: t0.subtract(ago),
);

void main() {
  late Outbox outbox;
  setUp(() {
    outbox = Outbox.open(':memory:', key: key);
    now = t0;
  });
  tearDown(() => outbox.close());

  Future<void> boot(WidgetTester tester, LocationProvider? location) async {
    await tester.pumpWidget(
      SardApp(
        outbox: outbox,
        refreshEvery: null,
        clock: () => now,
        location: location,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> sos(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sos_button')));
    await tester.pumpAndSettle();
  }

  List<ReportFrame> frames() => [
    for (final e in outbox.all()) decodeReportFrame(e.frame, key),
  ];

  testWidgets(
    'con una lectura reciente (30 s, ±20 m) el SOS ya sale con ubicación y no pide otra',
    (tester) async {
      final loc = FakeLocation(last: fix(ago: const Duration(seconds: 30)));
      await boot(tester, loc);
      await sos(tester);
      final f = frames().single;
      expect(f.locQuality, LocQuality.within50m);
      expect(f.lat, closeTo(5.07, 2e-5));
      expect(f.lon, closeTo(-75.51, 2e-5));
      expect(loc.freshCalls, 0);
    },
  );

  testWidgets(
    'con una lectura de hace 10 min se descarta: el SOS sale sin ubicación y llega una revisión',
    (tester) async {
      final loc = FakeLocation(
        last: fix(ago: const Duration(minutes: 10)),
        freshFix: fix(ago: Duration.zero, accuracy: 8, lat: 5.1, lon: -75.6),
      );
      await boot(tester, loc);
      await sos(tester);
      final fs = frames();
      expect(fs.length, 2);
      expect(fs[0].rev, 0);
      expect(fs[0].locQuality, LocQuality.none);
      expect(fs[1].rev, 1);
      expect(fs[1].locQuality, LocQuality.within10m);
      expect(fs[1].lat, closeTo(5.1, 2e-5));
      expect(
        fs[1].reportKey,
        fs[0].reportKey,
        reason: 'es una revisión del MISMO reporte, no uno nuevo',
      );
      expect(loc.freshCalls, 1);
    },
  );

  testWidgets(
    'el SOS se guarda al instante: con la lectura nueva aún sin llegar ya está en la bandeja',
    (tester) async {
      final gate = Completer<void>();
      final loc = FakeLocation(
        freshFix: fix(ago: Duration.zero),
        gate: gate,
      );
      await boot(tester, loc);
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(outbox.all().length, 1, reason: 'el guardado no espera al GPS');
      expect(frames().single.locQuality, LocQuality.none);
      expect(find.text('Guardado en tu teléfono'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        outbox.all().length,
        2,
        reason: 'al llegar la lectura se añade la revisión',
      );
    },
  );

  testWidgets(
    'si no llega ninguna lectura en el plazo no hay revisión y el SOS queda guardado',
    (tester) async {
      final loc = FakeLocation();
      await boot(tester, loc);
      await sos(tester);
      expect(outbox.all().length, 1);
      expect(frames().single.locQuality, LocQuality.none);
      expect(loc.freshCalls, 1);
    },
  );

  testWidgets(
    'si el proveedor lanza una excepción (sin permiso, GPS apagado) el SOS se guarda igual',
    (tester) async {
      final loc = FakeLocation(throwOnLast: true, throwOnFresh: true);
      await boot(tester, loc);
      await sos(tester);
      expect(outbox.all().length, 1);
      expect(frames().single.locQuality, LocQuality.none);
    },
  );

  testWidgets(
    'sin proveedor de ubicación el SOS sale sin ubicación y sin revisión',
    (tester) async {
      await boot(tester, null);
      await sos(tester);
      expect(outbox.all().length, 1);
    },
  );

  testWidgets('una lectura con precisión inválida no se usa como ubicación', (
    tester,
  ) async {
    final loc = FakeLocation(
      last: fix(ago: const Duration(seconds: 10), accuracy: -1),
      freshFix: fix(ago: Duration.zero, accuracy: 30),
    );
    await boot(tester, loc);
    await sos(tester);
    final fs = frames();
    expect(fs[0].locQuality, LocQuality.none);
    expect(fs[1].locQuality, LocQuality.within50m);
  });

  testWidgets('la revisión conserva las banderas marcadas al tocar SOS', (
    tester,
  ) async {
    final loc = FakeLocation(freshFix: fix(ago: Duration.zero));
    await boot(tester, loc);
    await tester.tap(find.byKey(const Key('flag_atrapado')));
    await tester.tap(find.byKey(const Key('flag_herido')));
    await sos(tester);
    final fs = frames();
    expect(fs.length, 2);
    expect(fs[1].flags, SituationFlags.atrapado | SituationFlags.herido);
    expect(fs[0].flags, fs[1].flags);
  });

  testWidgets(
    'dos SOS antes de que llegue ninguna lectura generan cada uno su propia revisión',
    (tester) async {
      final gate = Completer<void>();
      final loc = FakeLocation(
        freshFix: fix(ago: Duration.zero),
        gate: gate,
      );
      await boot(tester, loc);
      await tester.tap(find.byKey(const Key('sos_button')));
      now = now.add(const Duration(seconds: 3)); // pasado el filtro anti-pánico
      await tester.tap(find.byKey(const Key('sos_button')));
      await tester.pump();
      expect(outbox.all().length, 2);
      gate.complete();
      await tester.pumpAndSettle();
      expect(outbox.all().length, 4);
      expect(frames().map((f) => f.reportKey).toSet().length, 2);
    },
  );

  testWidgets(
    'un segundo SOS, con la lectura ya conocida, sale directamente con ubicación',
    (tester) async {
      final loc = FakeLocation(freshFix: fix(ago: Duration.zero));
      await boot(tester, loc);
      await sos(tester); // sin ubicación previa → revisión
      now = now.add(const Duration(seconds: 3));
      await sos(
        tester,
      ); // ahora la última lectura es reciente → ya sale con ubicación
      final fs = frames();
      expect(fs.length, 3);
      expect(fs[2].rev, 0);
      expect(fs[2].locQuality.hasCoordinates, isTrue);
      expect(loc.freshCalls, 1);
    },
  );
}
