import 'dart:math';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

final Uint8List _id = deviceIdFromHex('9a3c51e07b2d44f1');

void main() {
  group('Ack', () {
    test('ack_basic: codifica exactamente los bytes del oráculo (22 B)', () {
      final v = vector('ack_basic');
      final i = v['input']! as Map<String, Object?>;
      final ack = Ack(deviceId: deviceIdFromHex(i['device_id']! as String), ackSeq: i['ack_seq']! as int, bitmap: i['bitmap']! as int);
      final bytes = encodeAck(ack, testKey);
      expect(bytes, hexBytes(v['hex']! as String));
      expect(bytes.length, 22);
    });

    test('ida y vuelta', () {
      final back = decodeAck(hexBytes(vector('ack_basic')['hex']! as String), testKey);
      expect(deviceIdToHex(back.deviceId), '9a3c51e07b2d44f1');
      expect(back.ackSeq, 17);
      expect(back.bitmap, 5);
    });

    test('covers: la trama respondida y los bits hacia atrás', () {
      final a = Ack(deviceId: _id, ackSeq: 17, bitmap: 5); // bits 0 y 2 → tramas 16 y 14
      expect(a.covers(17), isTrue);
      expect(a.covers(16), isTrue);
      expect(a.covers(15), isFalse);
      expect(a.covers(14), isTrue);
      expect(a.covers(13), isFalse);
      expect(a.covers(18), isFalse);
    });

    test('covers: el borde de la ventana de 32 tramas', () {
      final a = Ack(deviceId: _id, ackSeq: 40, bitmap: 0x80000000); // bit 31 → trama 8
      expect(a.covers(8), isTrue);
      expect(a.covers(7), isFalse);
      expect(a.covers(9), isFalse);
    });

    test('etiqueta alterada → BadTag; recortado → TruncatedFrame; un REPORT → WrongType', () {
      final good = hexBytes(vector('ack_basic')['hex']! as String);
      expect(() => decodeAck(Uint8List.fromList(good)..[15] ^= 1, testKey), throwsA(isA<BadTag>()));
      expect(() => decodeAck(Uint8List.sublistView(good, 0, 21), testKey), throwsA(isA<TruncatedFrame>()));
      expect(() => decodeAck(hexBytes(vector('sos_min')['hex']! as String), testKey), throwsA(isA<WrongType>()));
    });
  });

  group('AckTracker', () {
    test('cubre lo que el nodo guarda y no cubre los huecos', () {
      final t = AckTracker()..record(1)..record(2)..record(4);
      final a = t.build(_id, 4);
      expect(a.covers(4), isTrue);
      expect(a.covers(2), isTrue);
      expect(a.covers(1), isTrue);
      expect(a.covers(3), isFalse);
    });

    test('no se puede acusar una trama que no se tiene', () {
      final t = AckTracker()..record(1)..record(2)..record(4);
      expect(() => t.build(_id, 3), throwsStateError);
    });

    test('nodo nuevo que sólo recibe 31..40: el ACK de 40 cubre 40..31 y no 30 ni 41', () {
      final t = AckTracker();
      for (var s = 31; s <= 40; s++) {
        t.record(s);
      }
      final a = t.build(_id, 40);
      for (var s = 31; s <= 40; s++) {
        expect(a.covers(s), isTrue, reason: 'seq $s');
      }
      expect(a.covers(30), isFalse);
      expect(a.covers(41), isFalse);
    });

    test('propiedad: un ACK jamás cubre una trama que el nodo no guarda', () {
      final rng = Random(7);
      for (var round = 0; round < 200; round++) {
        final seen = <int>{for (var i = 0; i < rng.nextInt(60) + 1; i++) rng.nextInt(120) + 1};
        final t = AckTracker();
        seen.forEach(t.record);
        for (final ackSeq in seen) {
          final a = t.build(_id, ackSeq);
          for (var s = 0; s < 200; s++) {
            if (a.covers(s)) {
              expect(seen.contains(s), isTrue, reason: 'ronda $round: el ACK de $ackSeq cubre $s que no se guarda');
            } else if (s <= ackSeq && ackSeq - s <= 32 && seen.contains(s)) {
              fail('ronda $round: el ACK de $ackSeq no cubre $s, que sí se guarda y cabe en la ventana');
            }
          }
        }
      }
    });
  });
}
