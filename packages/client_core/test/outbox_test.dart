import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);

NewReport sos({int flags = SituationFlags.atrapado, bool withLocation = true, String? text}) => NewReport(
      incidentType: 3,
      flags: flags,
      peopleBucket: 2,
      batteryQ: 3,
      locQuality: withLocation ? LocQuality.within50m : LocQuality.none,
      lat: withLocation ? 5.07 : null,
      lon: withLocation ? -75.51 : null,
      text: text,
    );

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-outbox-');
    path = '${dir.path}/outbox.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('enqueueSos con ubicación: entrada queued, 0 intentos y una trama de 33 B', () {
    final ob = Outbox.open(path, key: key);
    final e = ob.enqueueSos(sos(), now: t0);
    expect(e.state, OutboxState.queued);
    expect(e.attempts, 0);
    expect(e.frameSeq, 1);
    expect(e.rev, 0);
    expect(e.frame.length, 33);
    expect(e.reportKey, '${deviceIdToHex(ob.deviceId)}-1');
    ob.close();
  });

  test('sin ubicación la trama mide 27 B', () {
    final ob = Outbox.open(path, key: key);
    expect(ob.enqueueSos(sos(withLocation: false), now: t0).frame.length, 27);
    ob.close();
  });

  test('reabrir el archivo conserva entradas, deviceId e intentos', () {
    final a = Outbox.open(path, key: key);
    final id = deviceIdToHex(a.deviceId);
    final e = a.enqueueSos(sos(), now: t0);
    a.markSending(e.frameSeq);
    a.markFailed(e.frameSeq, nextTryAt: t0.add(const Duration(seconds: 2)));
    a.close();

    final b = Outbox.open(path, key: key);
    expect(deviceIdToHex(b.deviceId), id);
    final back = b.all().single;
    expect(back.attempts, 1);
    expect(back.nextTryAt, t0.add(const Duration(seconds: 2)));
    expect(b.enqueueSos(sos(), now: t0).frameSeq, 2);
    b.close();
  });

  test('enqueueRevision: frameSeq 2, rev 1, 37 B sin texto y apunta al reporte original', () {
    final ob = Outbox.open(path, key: key);
    final first = ob.enqueueSos(sos(), now: t0);
    final rev = ob.enqueueRevision(first.reportKey, sos(), now: t0);
    expect(rev.frameSeq, 2);
    expect(rev.rev, 1);
    expect(rev.frame.length, 37);
    expect(rev.reportKey, first.reportKey);
    final decoded = decodeReportFrame(rev.frame, key);
    expect(decoded.refSeq, 1);
    expect(decoded.reportKey, first.reportKey);
    expect(ob.enqueueRevision(first.reportKey, sos(text: 'bajo la losa'), now: t0).rev, 2);
    ob.close();
  });

  test('enqueueRevision de un reporte desconocido lanza ArgumentError', () {
    final ob = Outbox.open(path, key: key);
    expect(() => ob.enqueueRevision('0000000000000000-9', sos(), now: t0), throwsArgumentError);
    ob.close();
  });

  test('un texto demasiado largo falla sin consumir un frameSeq ni dejar nada', () {
    final ob = Outbox.open(path, key: key);
    expect(() => ob.enqueueSos(sos(text: 'á' * 71), now: t0), throwsArgumentError);
    expect(ob.all(), isEmpty);
    expect(ob.enqueueSos(sos(), now: t0).frameSeq, 1);
    ob.close();
  });

  test('due entrega primero lo de menor prioHint y respeta el límite', () {
    final ob = Outbox.open(path, key: key);
    ob.enqueueSos(sos(flags: SituationFlags.viaBloqueada), now: t0);
    ob.enqueueSos(sos(flags: SituationFlags.atrapado | SituationFlags.herido), now: t0);
    expect(ob.due(t0).map((e) => e.frameSeq), [2, 1]);
    for (var i = 0; i < 10; i++) {
      ob.enqueueSos(sos(), now: t0);
    }
    expect(ob.due(t0).length, 8);
    expect(ob.due(t0, limit: 3).length, 3);
    ob.close();
  });

  test('markFailed oculta la entrada hasta nextTryAt y cuenta el intento', () {
    final ob = Outbox.open(path, key: key);
    final e = ob.enqueueSos(sos(), now: t0);
    ob.markSending(e.frameSeq);
    expect(ob.all().single.state, OutboxState.sending);
    expect(ob.due(t0), isEmpty);
    final later = t0.add(const Duration(seconds: 5));
    ob.markFailed(e.frameSeq, nextTryAt: later);
    expect(ob.all().single.state, OutboxState.queued);
    expect(ob.all().single.attempts, 1);
    expect(ob.due(t0.add(const Duration(seconds: 4))), isEmpty);
    expect(ob.due(later).single.frameSeq, 1);
    ob.close();
  });

  test('applyAck marca sent las tramas cubiertas y sólo ésas', () {
    final ob = Outbox.open(path, key: key);
    for (var i = 0; i < 3; i++) {
      ob.enqueueSos(sos(), now: t0);
    }
    ob.applyAck(Ack(deviceId: ob.deviceId, ackSeq: 3, bitmap: 2)); // 3 y (bit 1) → 1
    final byState = {for (final e in ob.all()) e.frameSeq: e.state};
    expect(byState, {1: OutboxState.sent, 2: OutboxState.queued, 3: OutboxState.sent});
    ob.close();
  });

  test('un ACK de otro dispositivo no cambia nada', () {
    final ob = Outbox.open(path, key: key);
    ob.enqueueSos(sos(), now: t0);
    ob.applyAck(Ack(deviceId: deviceIdFromHex('ffffffffffffffff'), ackSeq: 1, bitmap: 0));
    expect(ob.all().single.state, OutboxState.queued);
    ob.close();
  });

  test('una entrada dejada en sending y reabierta vuelve a queued con sus intentos', () {
    final a = Outbox.open(path, key: key);
    final e = a.enqueueSos(sos(), now: t0);
    a.markSending(e.frameSeq);
    a.markFailed(e.frameSeq, nextTryAt: t0);
    a.markSending(e.frameSeq); // intento en vuelo cuando "mata" la app
    a.close();
    final b = Outbox.open(path, key: key);
    final back = b.all().single;
    expect(back.state, OutboxState.queued);
    expect(back.attempts, 1);
    expect(b.due(t0).single.frameSeq, 1);
    b.close();
  });

  test('lo guardado sobrevive a la muerte del proceso (la fila está confirmada en disco)', () {
    final ob = Outbox.open(path, key: key);
    ob.enqueueSos(sos(), now: t0);
    // Se lee con otra conexión sin cerrar la primera: el commit ya es visible y durable.
    final other = sqlite3.open(path);
    expect(other.select('SELECT COUNT(*) AS c FROM outbox').first['c'], 1);
    other.close();
    ob.close();
  });
}
