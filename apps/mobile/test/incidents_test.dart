import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_mobile/incidents.dart';
import 'package:sard_protocol/sard_protocol.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);

NewReport rep({int flags = 0, bool loc = false}) => NewReport(
  incidentType: 1,
  flags: flags,
  peopleBucket: 0,
  batteryQ: 5,
  locQuality: loc ? LocQuality.within50m : LocQuality.none,
  lat: loc ? 5.07 : null,
  lon: loc ? -75.51 : null,
);

void main() {
  late Outbox ob;
  setUp(() => ob = Outbox.open(':memory:', key: key));
  tearDown(() => ob.close());

  List<Incident> group() => groupIncidents(ob.all(), ob.reportOf);

  test(
    'una revisión (p. ej. la ubicación que llega después) se pliega dentro de su SOS: un solo incidente',
    () {
      final sos = ob.enqueueSos(rep(flags: SituationFlags.atrapado), now: t0);
      ob.enqueueRevision(
        sos.reportKey,
        rep(flags: SituationFlags.atrapado, loc: true),
        now: t0,
      );
      final g = group();
      expect(g, hasLength(1));
      expect(
        g.single.frame.rev,
        1,
        reason: 'se muestra lo último que se ha dicho',
      );
      expect(g.single.hasLocation, isTrue);
      expect(g.single.flags, SituationFlags.atrapado);
    },
  );

  test('el más reciente va primero y cada SOS es su propio incidente', () {
    ob.enqueueSos(rep(flags: SituationFlags.herido), now: t0);
    ob.enqueueSos(
      rep(flags: SituationFlags.incendio),
      now: t0.add(const Duration(minutes: 5)),
    );
    final g = group();
    expect(g, hasLength(2));
    expect(g.first.flags, SituationFlags.incendio);
    expect(g.last.flags, SituationFlags.herido);
  });

  test(
    'el estado del incidente es el del SOS, no el de una actualización posterior pendiente',
    () {
      final sos = ob.enqueueSos(rep(), now: t0);
      ob.enqueueRevision(sos.reportKey, rep(loc: true), now: t0);
      // el nodo acusa sólo la trama del SOS
      ob.applyAck(Ack(deviceId: ob.deviceId, ackSeq: sos.frameSeq, bitmap: 0));
      final inc = group().single;
      expect(inc.sos.state, OutboxState.sent);
      expect(
        inc.updatePending,
        isTrue,
        reason: 'queda una actualización por enviar',
      );
    },
  );

  test(
    'sin actualizaciones pendientes cuando todas las tramas ya salieron',
    () {
      final sos = ob.enqueueSos(rep(), now: t0);
      final rev = ob.enqueueRevision(sos.reportKey, rep(loc: true), now: t0);
      ob.applyAck(Ack(deviceId: ob.deviceId, ackSeq: rev.frameSeq, bitmap: 1));
      final inc = group().single;
      expect(inc.sos.state, OutboxState.sent);
      expect(inc.updatePending, isFalse);
    },
  );

  test('banderas del incidente en orden estable, listas para mostrar', () {
    ob.enqueueSos(
      rep(flags: SituationFlags.herido | SituationFlags.atrapado),
      now: t0,
    );
    expect(group().single.flagLabels, ['Atrapado', 'Herido']);
  });

  test('sin banderas no hay etiquetas', () {
    ob.enqueueSos(rep(), now: t0);
    expect(group().single.flagLabels, isEmpty);
  });
}
