import 'dart:io';
import 'dart:typed_data';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-ingest-');
    path = '${dir.path}/log.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Ingest open(EventLog log) => Ingest(log: log, key: testKey, clock: () => DateTime.fromMillisecondsSinceEpoch(1000));
  Ack ackOf(IngestResult r) => decodeAck(r.ack!, testKey);

  test('un reporte válido se guarda, genera un evento y se acusa', () {
    final log = EventLog.open(path, nodeId: 'A');
    final r = open(log).handleFrame(vectorBytes('sos_min'));
    expect(r.outcome, IngestOutcome.stored);
    expect(log.all().length, 1);
    final e = log.all().single;
    expect(e.type, 'report.received');
    expect(e.reportKey, '9a3c51e07b2d44f1-17');
    expect(e.body['frame_seq'], 17);
    expect(e.body['received_at'], 1000);
    expect(ackOf(r).covers(17), isTrue);
    log.close();
  });

  test('el mismo reporte otra vez es duplicado: sin evento nuevo pero con ACK', () {
    final log = EventLog.open(path, nodeId: 'A');
    final ingest = open(log);
    ingest.handleFrame(vectorBytes('sos_min'));
    final r = ingest.handleFrame(vectorBytes('sos_min'));
    expect(r.outcome, IngestOutcome.duplicate);
    expect(log.all().length, 1);
    expect(ackOf(r).covers(17), isTrue);
    log.close();
  });

  test('una trama con un byte alterado o recortada se rechaza sin ACK ni evento', () {
    final log = EventLog.open(path, nodeId: 'A');
    final ingest = open(log);
    final bad = Uint8List.fromList(vectorBytes('sos_min'))..[20] ^= 0xFF;
    final r1 = ingest.handleFrame(bad);
    final r2 = ingest.handleFrame(Uint8List.sublistView(vectorBytes('sos_min'), 0, 12));
    final r3 = ingest.handleFrame(Uint8List(0));
    for (final r in [r1, r2, r3]) {
      expect(r.outcome, IngestOutcome.rejected);
      expect(r.ack, isNull);
    }
    expect(log.all(), isEmpty);
    log.close();
  });

  test('una revisión que llega antes que su revisión 0 se guarda y se acusa sola', () {
    final log = EventLog.open(path, nodeId: 'A');
    final ingest = open(log);
    final r18 = ingest.handleFrame(vectorBytes('rev_with_text'));
    expect(r18.outcome, IngestOutcome.stored);
    expect(ackOf(r18).covers(18), isTrue);
    expect(ackOf(r18).covers(17), isFalse);
    final r17 = ingest.handleFrame(vectorBytes('sos_min'));
    expect(ackOf(r17).covers(17), isTrue);
    expect(log.all().length, 2);
    expect(log.all().map((e) => e.reportKey).toSet(), {'9a3c51e07b2d44f1-17'});
    log.close();
  });

  test('tras reiniciar el nodo, un duplicado se vuelve a acusar y el log no crece', () {
    final first = EventLog.open(path, nodeId: 'A');
    final i1 = open(first);
    i1.handleFrame(vectorBytes('sos_min'));
    i1.handleFrame(vectorBytes('rev_with_text'));
    first.close();

    final second = EventLog.open(path, nodeId: 'A');
    final i2 = open(second);
    final r = i2.handleFrame(vectorBytes('rev_with_text'));
    expect(r.outcome, IngestOutcome.duplicate);
    expect(ackOf(r).covers(18), isTrue);
    expect(ackOf(r).covers(17), isTrue);
    expect(second.all().length, 2);
    second.close();
  });

  test('failover: un nodo nuevo que sólo recibe las tramas 31..40 nunca acusa una que no tiene', () {
    final log = EventLog.open(path, nodeId: 'B');
    final ingest = open(log);
    late Ack last;
    for (var s = 31; s <= 40; s++) {
      final r = ingest.handleFrame(sosFrame(s));
      expect(r.outcome, IngestOutcome.stored);
      final ack = ackOf(r);
      for (var t = 0; t < 80; t++) {
        if (ack.covers(t)) expect(t >= 31 && t <= s, isTrue, reason: 'el ACK de $s cubre $t que el nodo no guarda');
      }
      last = ack;
    }
    for (var s = 31; s <= 40; s++) {
      expect(last.covers(s), isTrue, reason: 'seq $s');
    }
    expect(last.covers(30), isFalse);
    log.close();
  });
}
