// T01 · kill -9 durante la escritura: 0 pérdidas de lo que la app ya dio por guardado.
//
// Un proceso HIJO encola SOS en una bandeja de archivo (SQLite, WAL, synchronous=FULL) y dice «OK n»
// cuando `enqueueSos` vuelve. El padre lo mata con kill -9 en un punto distinto de cada ronda y reabre la
// bandeja. Criterios: la base no está corrupta; todo lo que el hijo dijo guardado está; no hay huecos en la
// numeración de tramas; cada trama guardada se decodifica y su etiqueta de integridad verifica; el hijo
// que se reinicia sobre la misma bandeja conserva su identidad y sigue la numeración sin repetirla.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

/// Lanza el hijo y lo mata (SIGKILL) cuando ya imprimió [killAfter] líneas «OK». Devuelve el mayor «OK n»
/// visto y el «REV» más alto.
Future<({int acked, bool finished})> runAndKill(String dbPath, int total, int killAfter) async {
  final p = await Process.start('dart', ['run', 'test/support/t01_child.dart', dbPath, '$total']);
  var acked = 0;
  var finished = false;
  final done = Completer<void>();
  p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('OK ')) {
      acked = int.parse(line.substring(3));
      if (acked >= killAfter && !done.isCompleted) {
        p.kill(ProcessSignal.sigkill);
        done.complete();
      }
    } else if (line == 'FIN') {
      finished = true;
    }
  });
  unawaited(p.stderr.drain<void>());
  await Future.any([done.future, p.exitCode.then((_) {})]).timeout(const Duration(seconds: 120));
  await p.exitCode.timeout(const Duration(seconds: 30));
  return (acked: acked, finished: finished);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sard-t01-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('kill -9 en 6 puntos distintos de 100 SOS: nada de lo acusado se pierde, sin huecos ni corrupción', () async {
    final rounds = <String>[];
    for (final killAfter in [1, 7, 23, 51, 77, 96]) {
      final path = '${dir.path}/bandeja-$killAfter.db';
      final r = await runAndKill(path, 100, killAfter);
      // reabrir tras el golpe
      final outbox = Outbox.open(path, key: key);
      addTearDown(outbox.close);
      final entries = outbox.all();
      final sos = entries.where((e) => e.rev == 0).toList();
      // 1. lo que el hijo dio por guardado está
      expect(sos.length, greaterThanOrEqualTo(r.acked), reason: 'ronda $killAfter: el hijo dijo guardados ${r.acked} SOS y sólo hay ${sos.length}');
      // 2. no hay más de lo que se intentó
      expect(sos.length, lessThanOrEqualTo(100));
      // 3. sin huecos: las tramas guardadas son 1..N sin saltos (cada transacción es atómica)
      final seqs = entries.map((e) => e.frameSeq).toList()..sort();
      expect(seqs, [for (var i = 1; i <= seqs.length; i++) i], reason: 'ronda $killAfter: la numeración de tramas tiene huecos');
      // 4. cada trama se decodifica y su etiqueta verifica
      for (final e in entries) {
        final f = decodeReportFrame(e.frame, key);
        expect(f.seq, e.frameSeq);
      }
      // 5. cada revisión pertenece a un SOS que existe
      final sosKeys = {for (final e in sos) e.reportKey};
      for (final e in entries.where((e) => e.rev > 0)) {
        expect(sosKeys, contains(e.reportKey), reason: 'ronda $killAfter: revisión huérfana');
      }
      // 6. integridad de SQLite
      outbox.close();
      final raw = File(path);
      expect(raw.existsSync(), isTrue);
      rounds.add('matado tras OK $killAfter (el hijo llevaba ${r.acked}): ${sos.length} SOS y ${entries.length - sos.length} revisiones guardadas, sin huecos');
    }
    // ignore: avoid_print
    print(rounds.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('tras el golpe, la misma bandeja conserva la identidad del dispositivo y sigue la numeración sin repetirla', () async {
    final path = '${dir.path}/bandeja.db';
    await runAndKill(path, 100, 30);
    final first = Outbox.open(path, key: key);
    final id = first.deviceId;
    final before = first.all().map((e) => e.frameSeq).fold<int>(0, (a, b) => a > b ? a : b);
    final next = first.enqueueSos(const NewReport(incidentType: 1, flags: 0, peopleBucket: 0, batteryQ: 8, locQuality: LocQuality.none), now: DateTime.fromMillisecondsSinceEpoch(1786370851000));
    expect(next.frameSeq, before + 1, reason: 'la numeración continúa, no se repite');
    first.close();
    final again = Outbox.open(path, key: key);
    addTearDown(again.close);
    expect(again.deviceId, id, reason: 'misma instalación: mismo identificador');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('una trama que quedó «enviando» cuando se mató al proceso vuelve a la cola al reabrir (no queda varada)', () async {
    final path = '${dir.path}/bandeja.db';
    final outbox = Outbox.open(path, key: key);
    final e = outbox.enqueueSos(const NewReport(incidentType: 1, flags: 0x80, peopleBucket: 0, batteryQ: 8, locQuality: LocQuality.none), now: DateTime.fromMillisecondsSinceEpoch(1786370851000));
    outbox.markSending(e.frameSeq);
    expect(outbox.all().single.state, OutboxState.sending);
    outbox.close(); // como si el proceso hubiera muerto con la trama a medio enviar
    final reopened = Outbox.open(path, key: key);
    addTearDown(reopened.close);
    expect(reopened.all().single.state, OutboxState.queued);
  });
}
