import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

class _Counting implements Channel {
  int calls = 0;
  @override
  Future<Uint8List?> send(Uint8List frame) async {
    calls++;
    return Uint8List.fromList([7]);
  }
}

final Uint8List _frame = Uint8List.fromList([1]);

void main() {
  final start = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  late VirtualClock clock;
  late _Counting inner;
  late WindowedChannel ch;
  setUp(() {
    clock = VirtualClock(start);
    inner = _Counting();
    ch = WindowedChannel(inner, clock: clock, open: const Duration(seconds: 3), closed: const Duration(seconds: 57));
  });

  test('la fase abierta delega en el canal interno', () async {
    expect(await ch.send(_frame), [7]);
    expect(inner.calls, 1);
  });

  test('la fase cerrada devuelve null sin tocar el canal interno', () async {
    clock.advance(const Duration(seconds: 10));
    expect(await ch.send(_frame), isNull);
    expect(inner.calls, 0);
  });

  test('el borde exacto de la apertura ya está cerrado; un milisegundo antes sigue abierto', () async {
    clock.advance(const Duration(milliseconds: 2999));
    expect(ch.isOpenAt(clock.now()), isTrue);
    clock.advance(const Duration(milliseconds: 1));
    expect(ch.isOpenAt(clock.now()), isFalse);
  });

  test('el ciclo se repite cada 60 s', () async {
    for (final s in [60, 120, 600]) {
      expect(ch.isOpenAt(start.add(Duration(seconds: s))), isTrue, reason: 't=$s');
      expect(ch.isOpenAt(start.add(Duration(seconds: s + 3))), isFalse, reason: 't=${s + 3}');
    }
  });

  test('antes de la época el ciclo también está definido (módulo positivo)', () {
    expect(ch.isOpenAt(start.subtract(const Duration(seconds: 60))), isTrue);
    expect(ch.isOpenAt(start.subtract(const Duration(seconds: 1))), isFalse);
  });

  test('nextOpenAtOrAfter y windowEndFor', () {
    expect(ch.nextOpenAtOrAfter(start), start);
    expect(ch.nextOpenAtOrAfter(start.add(const Duration(seconds: 10))), start.add(const Duration(seconds: 60)));
    expect(ch.windowEndFor(start.add(const Duration(seconds: 1))), start.add(const Duration(seconds: 3)));
    expect(ch.windowEndFor(start.add(const Duration(seconds: 10))), start.add(const Duration(seconds: 63)));
  });

  test('VirtualClock sólo avanza cuando se le ordena', () {
    final c = VirtualClock(start);
    expect(c.now(), start);
    c.advance(const Duration(minutes: 5));
    expect(c.now(), start.add(const Duration(minutes: 5)));
  });

  group('FakeNodeChannel', () {
    final key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
    Uint8List frame(int seq) => encodeReportFrame(
          ReportFrame(
            deviceId: deviceIdFromHex('9a3c51e07b2d44f1'), seq: seq, rev: 0, prioHint: 0, incidentType: 1, flags: 0x80,
            peopleBucket: 0, locQuality: LocQuality.none, capturedAt: 1, batteryQ: 1,
          ),
          key,
        );

    test('acusa una trama válida con un ACK real que la cubre', () async {
      final node = FakeNodeChannel(key);
      final ack = decodeAck((await node.send(frame(5)))!, key);
      expect(ack.covers(5), isTrue);
      expect(node.received, 1);
    });

    test('un duplicado se vuelve a acusar pero no cuenta como recibido de nuevo', () async {
      final node = FakeNodeChannel(key);
      await node.send(frame(5));
      expect(await node.send(frame(5)), isNotNull);
      expect(node.received, 1);
      expect(node.deliveries, 2);
    });

    test('una trama inválida no se acusa', () async {
      final node = FakeNodeChannel(key);
      expect(await node.send(Uint8List.fromList([1, 2, 3])), isNull);
      expect(node.received, 0);
    });
  });
}
