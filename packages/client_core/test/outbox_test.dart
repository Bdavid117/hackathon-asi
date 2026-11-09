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

  group('envejecimiento y cuota anti-inanición', () {
    final base = DateTime.fromMillisecondsSinceEpoch(1000000000); // lejos de 1970: permite restar minutos
    const flagsP1 = SituationFlags.atrapado | SituationFlags.herido; // prioHint 0
    const flagsP3 = SituationFlags.viaBloqueada; // prioHint 2
    // El teléfono ya no propone P4 desde las banderas (sin datos ⇒ P3). Para ejercitar el
    // envejecimiento de una entrada de la prioridad más baja —que una versión anterior de la app
    // pudo dejar en la bandeja— se fuerza prio_hint = 3 directamente en la base.
    OutboxEntry enqueueP4(Outbox ob, {required DateTime now}) {
      final e = ob.enqueueSos(sos(flags: 0), now: now);
      final db = sqlite3.open(path);
      db.execute('UPDATE outbox SET prio_hint = 3 WHERE frame_seq = ?', [e.frameSeq]);
      db.close();
      return e;
    }
    const never = Duration(days: 1000);

    test('el envejecimiento sube la prioridad de lo que espera', () {
      final ob = Outbox.open(path, key: key);
      final old = enqueueP4(ob, now: base.subtract(const Duration(minutes: 35)));
      ob.enqueueSos(sos(flags: flagsP3), now: base);
      expect(ob.due(base, limit: 1).single.frameSeq, old.frameSeq);
      ob.close();
    });

    test('el envejecimiento nunca iguala a un P1: un P4 de 3 horas sigue yendo detrás de un P1 nuevo', () {
      final ob = Outbox.open(path, key: key);
      enqueueP4(ob, now: base.subtract(const Duration(hours: 3)));
      final p1 = ob.enqueueSos(sos(flags: flagsP1), now: base);
      expect(ob.due(base, limit: 1).single.frameSeq, p1.frameSeq);
      ob.close();
    });

    test('el envejecimiento sí lleva un P4 muy antiguo por delante de un P2 nuevo', () {
      final ob = Outbox.open(path, key: key);
      final old = enqueueP4(ob, now: base.subtract(const Duration(hours: 3)));
      ob.enqueueSos(sos(flags: SituationFlags.atrapado), now: base); // prioHint 1 (P2)
      // P4 envejecido queda en P2 y gana el desempate por antigüedad al P2 nuevo.
      expect(ob.due(base, limit: 1).single.frameSeq, old.frameSeq);
      ob.close();
    });

    test('sin envejecer, un P4 reciente va detrás de un P3', () {
      final ob = Outbox.open(path, key: key);
      enqueueP4(ob, now: base);
      final p3 = ob.enqueueSos(sos(flags: flagsP3), now: base);
      expect(ob.due(base, limit: 1).single.frameSeq, p3.frameSeq);
      ob.close();
    });

    test('la cuota hace salir al más antiguo aunque haya una avalancha de P1', () {
      final ob = Outbox.open(path, key: key);
      final old = enqueueP4(ob, now: base.subtract(const Duration(minutes: 5)));
      for (var i = 0; i < 30; i++) {
        ob.enqueueSos(sos(flags: flagsP1), now: base);
      }
      final batch = ob.due(base, limit: 5, agingStep: never);
      expect(batch.length, 5);
      expect(batch.map((e) => e.frameSeq), contains(old.frameSeq));
      expect(batch.last.frameSeq, old.frameSeq, reason: 'ocupa la quinta posición');
      ob.close();
    });

    test('sin la cuota (lote de 4) sólo salen P1', () {
      final ob = Outbox.open(path, key: key);
      enqueueP4(ob, now: base.subtract(const Duration(minutes: 5)));
      for (var i = 0; i < 30; i++) {
        ob.enqueueSos(sos(flags: flagsP1), now: base);
      }
      expect(ob.due(base, limit: 4, agingStep: never).every((e) => e.prioHint == 0), isTrue);
      ob.close();
    });

    test('un lote de 10 reserva dos posiciones: los dos más antiguos', () {
      final ob = Outbox.open(path, key: key);
      final a = enqueueP4(ob, now: base.subtract(const Duration(minutes: 9)));
      final b = enqueueP4(ob, now: base.subtract(const Duration(minutes: 8)));
      for (var i = 0; i < 30; i++) {
        ob.enqueueSos(sos(flags: flagsP1), now: base);
      }
      final seqs = ob.due(base, limit: 10, agingStep: never).map((e) => e.frameSeq).toList();
      expect(seqs.length, 10);
      expect(seqs[4], a.frameSeq);
      expect(seqs[9], b.frameSeq);
      ob.close();
    });

    test('no repite entradas ni excede el límite', () {
      final ob = Outbox.open(path, key: key);
      for (var i = 0; i < 25; i++) {
        ob.enqueueSos(sos(flags: [flagsP1, flagsP3, 0][i % 3]), now: base.subtract(Duration(minutes: i)));
      }
      final seqs = ob.due(base, limit: 8).map((e) => e.frameSeq).toList();
      expect(seqs.length, 8);
      expect(seqs.toSet().length, 8);
      ob.close();
    });

    test('lo que aún no venció su espera no entra por la cuota', () {
      final ob = Outbox.open(path, key: key);
      final old = enqueueP4(ob, now: base.subtract(const Duration(minutes: 5)));
      ob.markSending(old.frameSeq);
      ob.markFailed(old.frameSeq, nextTryAt: base.add(const Duration(hours: 1)));
      for (var i = 0; i < 30; i++) {
        ob.enqueueSos(sos(flags: flagsP1), now: base);
      }
      expect(ob.due(base, limit: 5, agingStep: never).map((e) => e.frameSeq), isNot(contains(old.frameSeq)));
      ob.close();
    });

    test('con muchas esperas, al cabo de varias rondas todo el mundo sale (sin inanición)', () {
      final ob = Outbox.open(path, key: key);
      final old = enqueueP4(ob, now: base);
      var now = base;
      var round = 0;
      var sent = false;
      while (!sent && round < 20) {
        ob.enqueueSos(sos(flags: flagsP1), now: now); // llegan P1 sin parar
        for (final e in ob.due(now, limit: 5, agingStep: never)) {
          ob.markSending(e.frameSeq);
          ob.applyAck(Ack(deviceId: ob.deviceId, ackSeq: e.frameSeq, bitmap: 0));
          if (e.frameSeq == old.frameSeq) sent = true;
        }
        now = now.add(const Duration(seconds: 1));
        round++;
      }
      expect(sent, isTrue);
      ob.close();
    });
  });

  test('releaseBackoff vuelve a poner vencido lo que esperaba un reintento, sin tocar los intentos', () {
    final ob = Outbox.open(path, key: key);
    final e = ob.enqueueSos(sos(), now: t0);
    ob.markSending(e.frameSeq);
    ob.markFailed(e.frameSeq, nextTryAt: t0.add(const Duration(minutes: 5)));
    expect(ob.due(t0), isEmpty);
    ob.releaseBackoff();
    expect(ob.due(t0).single.frameSeq, e.frameSeq);
    expect(ob.all().single.attempts, 1);
    ob.close();
  });

  test('releaseBackoff no resucita lo ya enviado', () {
    final ob = Outbox.open(path, key: key);
    final e = ob.enqueueSos(sos(), now: t0);
    ob.applyAck(Ack(deviceId: ob.deviceId, ackSeq: e.frameSeq, bitmap: 0));
    ob.releaseBackoff();
    expect(ob.due(t0), isEmpty);
    expect(ob.all().single.state, OutboxState.sent);
    ob.close();
  });

  test('un reloj absurdo (antes de 1970 o más allá de 2106) no impide guardar el SOS: la hora se acota al rango del protocolo', () {
    final ob = Outbox.open(path, key: key);
    final early = ob.enqueueSos(sos(), now: DateTime.fromMillisecondsSinceEpoch(-5000000));
    final late = ob.enqueueSos(sos(), now: DateTime.fromMillisecondsSinceEpoch(5000000000000));
    expect(decodeReportFrame(early.frame, key).capturedAt, 0);
    expect(decodeReportFrame(late.frame, key).capturedAt, 4294967295);
    ob.close();
  });

  test('reportOf devuelve lo que lleva una trama (indicadores, ubicación, revisión) para mostrarlo a la persona', () {
    final ob = Outbox.open(path, key: key);
    final e0 = ob.enqueueSos(sos(flags: SituationFlags.atrapado, withLocation: false), now: t0);
    final e1 = ob.enqueueRevision(
      e0.reportKey,
      sos(flags: SituationFlags.atrapado | SituationFlags.herido),
      now: t0.add(const Duration(seconds: 5)),
    );
    final r0 = ob.reportOf(e0);
    final r1 = ob.reportOf(e1);
    expect(r0.rev, 0);
    expect(r0.flags, SituationFlags.atrapado);
    expect(r0.locQuality.hasCoordinates, isFalse);
    expect(r1.rev, 1);
    expect(r1.flags, SituationFlags.atrapado | SituationFlags.herido);
    expect(r1.locQuality.hasCoordinates, isTrue);
    ob.close();
  });

  group('atomicidad de una escritura (fallo inyectado a mitad; complementa a T01, que sólo la ve por casualidad)', () {
    // Un disparador en `report` hace fallar la ÚLTIMA sentencia de `enqueueSos` después de que la fila de la
    // trama y el contador de secuencia ya se escribieron: si la escritura no es atómica, queda un resto.
    test('si falla a mitad de enqueueSos NO queda nada: ni la trama, ni el contador adelantado', () {
      final path = '${dir.path}/atomica.db';
      final outbox = Outbox.open(path, key: key);
      addTearDown(outbox.close);
      final ok = outbox.enqueueSos(sos(), now: t0);
      expect(ok.frameSeq, 1);

      final other = sqlite3.open(path);
      addTearDown(other.close);
      other.execute("CREATE TRIGGER falla BEFORE INSERT ON report BEGIN SELECT RAISE(ABORT, 'fallo inyectado'); END");

      expect(() => outbox.enqueueSos(sos(), now: t0), throwsA(anything));
      expect(outbox.all(), hasLength(1), reason: 'la trama del intento fallido no debe quedar guardada');

      other.execute('DROP TRIGGER falla');
      final next = outbox.enqueueSos(sos(), now: t0);
      expect(next.frameSeq, 2, reason: 'el contador no avanzó con el intento fallido: no se salta ni se repite un número');
      expect(outbox.all().map((e) => e.frameSeq), [1, 2]);
    });

    test('lo mismo para una revisión', () {
      final path = '${dir.path}/atomica2.db';
      final outbox = Outbox.open(path, key: key);
      addTearDown(outbox.close);
      final first = outbox.enqueueSos(sos(), now: t0);
      final other = sqlite3.open(path);
      addTearDown(other.close);
      other.execute("CREATE TRIGGER falla BEFORE UPDATE ON report BEGIN SELECT RAISE(ABORT, 'fallo inyectado'); END");
      expect(() => outbox.enqueueRevision(first.reportKey, sos(), now: t0), throwsA(anything));
      expect(outbox.all(), hasLength(1));
      other.execute('DROP TRIGGER falla');
      expect(outbox.enqueueRevision(first.reportKey, sos(), now: t0).frameSeq, 2);
    });
  });
}
