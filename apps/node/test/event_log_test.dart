import 'dart:io';

import 'package:sard_node/sard_node.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Event _remote(String origin, int seq, {String type = 'report.received'}) => Event(
      id: '$origin:${seq.toString().padLeft(6, '0')}',
      origin: origin,
      seq: seq,
      type: type,
      hlc: '0-$seq-$origin',
      body: const {'k': 'v'},
    );

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-eventlog-');
    path = '${dir.path}/log.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('append asigna A:000001, A:000002 y conserva el orden', () {
    final log = EventLog.open(path, nodeId: 'A');
    final e1 = log.append('report.received', {'x': 1}, reportKey: 'k-1', rev: 0);
    final e2 = log.append('report.normalized', {'x': 2}, reportKey: 'k-1', rev: 0, inputs: [e1.id]);
    expect(e1.id, 'A:000001');
    expect(e2.id, 'A:000002');
    expect(e2.inputs, ['A:000001']);
    expect(log.all().map((e) => e.id), ['A:000001', 'A:000002']);
    log.close();
  });

  test('reabrir el archivo conserva los eventos y sigue la numeración', () {
    final a = EventLog.open(path, nodeId: 'A');
    a.append('t', {'n': 1});
    a.append('t', {'n': 2});
    a.close();
    final b = EventLog.open(path, nodeId: 'A');
    expect(b.all().length, 2);
    expect(b.append('t', {'n': 3}).id, 'A:000003');
    b.close();
  });

  test('appendReplicated es idempotente', () {
    final log = EventLog.open(path, nodeId: 'A');
    expect(log.appendReplicated(_remote('B', 1)), isTrue);
    expect(log.appendReplicated(_remote('B', 1)), isFalse);
    expect(log.all().length, 1);
    expect(log.has('B:000001'), isTrue);
    expect(log.has('B:000002'), isFalse);
    log.close();
  });

  test('appendReplicated rechaza un evento de este mismo origen que no está en el log', () {
    final log = EventLog.open(path, nodeId: 'A');
    expect(() => log.appendReplicated(_remote('A', 7)), throwsStateError);
    log.close();
  });

  test('versionVector da el mayor seq contiguo por origen', () {
    final log = EventLog.open(path, nodeId: 'A');
    log.append('t', {});
    for (final s in [1, 2, 4]) {
      log.appendReplicated(_remote('B', s));
    }
    expect(log.versionVector(), {'A': 1, 'B': 2});
    log.appendReplicated(_remote('B', 3));
    expect(log.versionVector()['B'], 4);
    log.close();
  });

  test('readAfter devuelve los eventos de un origen con seq mayor, en orden y con límite', () {
    final log = EventLog.open(path, nodeId: 'A');
    for (var i = 0; i < 5; i++) {
      log.append('t', {'i': i});
    }
    expect(log.readAfter('A', 2).map((e) => e.seq), [3, 4, 5]);
    expect(log.readAfter('A', 0, limit: 2).map((e) => e.seq), [1, 2]);
    expect(log.readAfter('Z', 0), isEmpty);
    log.close();
  });

  test('es append-only: UPDATE y DELETE directos sobre la base fallan', () {
    final log = EventLog.open(path, nodeId: 'A');
    log.append('t', {});
    final raw = sqlite3.open(path);
    expect(() => raw.execute("UPDATE events SET type = 'otro'"), throwsA(isA<SqliteException>()));
    expect(() => raw.execute('DELETE FROM events'), throwsA(isA<SqliteException>()));
    raw.close();
    log.close();
  });

  test('Event.toJson y fromJson hacen ida y vuelta', () {
    final e = Event(
      id: 'A:000001', origin: 'A', seq: 1, type: 'triage.assessed', reportKey: 'k-1', rev: 2,
      hlc: '1-1-A', body: const {'urgency': 'P1', 'signals': ['atrapado']}, inputs: const ['A:000000'],
    );
    final back = Event.fromJson(e.toJson());
    expect(back.toJson(), e.toJson());
  });

  test('find localiza un evento por tipo, reportKey y rev', () {
    final log = EventLog.open(path, nodeId: 'A');
    log.append('report.received', {'a': 1}, reportKey: 'k-1', rev: 0);
    final second = log.append('report.received', {'a': 2}, reportKey: 'k-1', rev: 1);
    expect(log.find('report.received', 'k-1', 1)?.id, second.id);
    expect(log.find('report.received', 'k-1', 2), isNull);
    expect(log.find('triage.assessed', 'k-1', 1), isNull);
    log.close();
  });

  test('count devuelve el número de eventos sin cargarlos', () {
    final log = EventLog.open(path, nodeId: 'A');
    expect(log.count(), 0);
    log.append('t', {});
    log.appendReplicated(_remote('B', 1));
    expect(log.count(), 2);
    log.close();
  });

  test('allOfType devuelve sólo los eventos de ese tipo, en orden de llegada', () {
    final log = EventLog.open(':memory:', nodeId: 'A');
    addTearDown(log.close);
    final a = log.append('report.received', {'n': 1}, reportKey: 'k-1', rev: 0);
    log.append('report.normalized', {'n': 2}, reportKey: 'k-1', rev: 0);
    final c = log.append('report.received', {'n': 3}, reportKey: 'k-2', rev: 0);
    expect(log.allOfType('report.received').map((e) => e.id), [a.id, c.id]);
    expect(log.allOfType('nada'), isEmpty);
  });

  group('lotes y conteos baratos', () {
    test('countOfTypes cuenta sólo los tipos pedidos', () {
      final log = EventLog.open(':memory:', nodeId: 'A');
      addTearDown(log.close);
      log.append('report.received', {'n': 1}, reportKey: 'k-1', rev: 0);
      log.append('report.normalized', {'n': 2}, reportKey: 'k-1', rev: 0);
      log.append('incident.linked', {'n': 3}, reportKey: 'k-1', rev: 0);
      log.append('report.received', {'n': 4}, reportKey: 'k-2', rev: 0);
      expect(log.countOfTypes(['report.received']), 2);
      expect(log.countOfTypes(['report.received', 'report.normalized']), 3);
      expect(log.countOfTypes(['nada']), 0);
      expect(log.countOfTypes(const []), 0);
    });

    test('appendAll escribe varios eventos en UNA transacción, con ids consecutivos y encadenando entradas', () {
      final log = EventLog.open(':memory:', nodeId: 'A');
      addTearDown(log.close);
      final before = log.append('report.received', {'x': 1}, reportKey: 'k-1', rev: 0);
      final out = log.appendAll([
        NewEvent('report.normalized', {'a': 1}, reportKey: 'k-1', rev: 0, inputs: [before.id]),
        NewEvent('triage.assessed', {'b': 2}, reportKey: 'k-1', rev: 0, chainPrevious: true),
      ]);
      expect(out.map((x) => x.id), ['A:000002', 'A:000003']);
      expect(out[1].inputs, [out[0].id]);
      expect(log.count(), 3);
      expect(log.find('triage.assessed', 'k-1', 0)!.inputs, [out[0].id]);
    });

    test('appendAll es atómico: si un evento no se puede escribir no queda ninguno', () {
      final log = EventLog.open(':memory:', nodeId: 'A');
      addTearDown(log.close);
      expect(
        () => log.appendAll([
          NewEvent('report.normalized', {'a': 1}, reportKey: 'k-1', rev: 0),
          NewEvent('triage.assessed', {'b': Object()}, reportKey: 'k-1', rev: 0), // no es JSON
        ]),
        throwsA(anything),
      );
      expect(log.count(), 0);
      // y el contador de secuencia no se desordena: el siguiente evento es el 1
      expect(log.append('report.received', {'x': 1}, reportKey: 'k-9', rev: 0).id, 'A:000001');
    });

    test('appendAll con la lista vacía no hace nada', () {
      final log = EventLog.open(':memory:', nodeId: 'A');
      addTearDown(log.close);
      expect(log.appendAll(const []), isEmpty);
    });
  });
}
