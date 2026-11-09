import 'dart:io';

import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'support.dart';

/// El nodo reconstruye al arrancar qué tramas guarda a partir del log. Un `report.received` que NO viene de una
/// trama (el informe de un despachador no tiene `frame_seq`) no debe tumbar el arranque: sin esto, registrar un
/// solo informe y reiniciar dejaba el nodo muerto. La defensa es estructural (la forma del cuerpo), no por canal:
/// así también cubre cualquier evento futuro con otra forma.
void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-dispatch-start-');
    path = '${dir.path}/log.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Ingest open(EventLog log) => Ingest(log: log, key: testKey, clock: () => DateTime.fromMillisecondsSinceEpoch(1000));

  const sinTrama = <String, Object?>{
    'device_id': 'radio:estacion-3',
    'channel': 'dispatcher',
    'text': 'edificio con gente atrapada en la carrera 23',
    'flags': 0,
    'received_at': 1000,
  };

  test('un report.received sin frame_seq, escrito en el propio nodo, no impide reabrir el nodo', () {
    var log = EventLog.open(path, nodeId: 'A');
    log.append('report.received', sinTrama, reportKey: 'desp-uno', rev: 0);
    log.close();

    log = EventLog.open(path, nodeId: 'A');
    expect(() => open(log), returnsNormally);
    log.close();
  });

  test('lo mismo si el evento llegó por réplica desde otro nodo', () {
    final a = EventLog.open(':memory:', nodeId: 'A');
    a.append('report.received', sinTrama, reportKey: 'desp-uno', rev: 0);
    var b = EventLog.open(path, nodeId: 'B');
    expect(b.appendReplicated(a.all().single), isTrue);
    b.close();

    b = EventLog.open(path, nodeId: 'B');
    expect(() => open(b), returnsNormally);
    b.close();
    a.close();
  });

  test('un cuerpo con frame_seq pero sin device_id (o con tipos equivocados) tampoco lo tumba', () {
    final log = EventLog.open(path, nodeId: 'A');
    log.append('report.received', {'frame_seq': 3, 'text': 'x'}, reportKey: 'k-1', rev: 0);
    log.append('report.received', {'device_id': 7, 'frame_seq': 'tres'}, reportKey: 'k-2', rev: 0);
    log.append('report.received', {'device_id': 'abc', 'frame_seq': 2.5}, reportKey: 'k-3', rev: 0);
    expect(() => open(log), returnsNormally);
    log.close();
  });

  test('las tramas de verdad siguen contándose: un duplicado tras reabrir se vuelve a acusar sin evento nuevo', () {
    var log = EventLog.open(path, nodeId: 'A');
    open(log).handleFrame(vectorBytes('sos_min'));
    log.append('report.received', sinTrama, reportKey: 'desp-uno', rev: 0);
    log.close();

    log = EventLog.open(path, nodeId: 'A');
    final r = open(log).handleFrame(vectorBytes('sos_min'));
    expect(r.outcome, IngestOutcome.duplicate);
    expect(log.allOfType('report.received').length, 2);
    log.close();
  });
}
