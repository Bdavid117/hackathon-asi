import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('PeopleBucket: escala de personas afectadas (3 bits del códec)', () {
    test('la escala tiene 6 valores fijos y estables (forman parte del formato en el cable)', () {
      expect(PeopleBucket.values.map((b) => b.code).toList(), [0, 1, 2, 3, 4, 5]);
      expect(PeopleBucket.unknown.code, 0, reason: '0 = no indicado: es lo que lleva un SOS sin detalle');
      expect(PeopleBucket.values.map((b) => b.label).toList(), ['No indicado', '1', '2–5', '6–20', '21–100', 'Más de 100']);
    });

    test('todos caben en los 3 bits que reserva la trama', () {
      for (final b in PeopleBucket.values) {
        expect(b.code, inInclusiveRange(0, 7));
      }
    });

    test('fromCode: los códigos conocidos vuelven a su valor y los desconocidos NO rompen (se leen como no indicado)', () {
      for (final b in PeopleBucket.values) {
        expect(PeopleBucket.fromCode(b.code), b);
      }
      expect(PeopleBucket.fromCode(6), PeopleBucket.unknown, reason: 'una versión futura podría definir 6 y 7');
      expect(PeopleBucket.fromCode(7), PeopleBucket.unknown);
      expect(PeopleBucket.fromCode(-1), PeopleBucket.unknown);
      expect(PeopleBucket.fromCode(null), PeopleBucket.unknown);
    });

    test('fromCount cae en el cajón correcto, incluidos los bordes', () {
      expect(PeopleBucket.fromCount(0), PeopleBucket.unknown);
      expect(PeopleBucket.fromCount(1), PeopleBucket.one);
      expect(PeopleBucket.fromCount(2), PeopleBucket.twoToFive);
      expect(PeopleBucket.fromCount(5), PeopleBucket.twoToFive);
      expect(PeopleBucket.fromCount(6), PeopleBucket.sixToTwenty);
      expect(PeopleBucket.fromCount(20), PeopleBucket.sixToTwenty);
      expect(PeopleBucket.fromCount(21), PeopleBucket.twentyOneToHundred);
      expect(PeopleBucket.fromCount(100), PeopleBucket.twentyOneToHundred);
      expect(PeopleBucket.fromCount(101), PeopleBucket.overHundred);
      expect(PeopleBucket.fromCount(1000000), PeopleBucket.overHundred);
    });

    test('un número negativo no es una cantidad: se lee como no indicado', () {
      expect(PeopleBucket.fromCount(-3), PeopleBucket.unknown);
    });

    test('lo que escribe la app sobrevive al códec: el cajón viaja en la trama y vuelve igual', () {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      for (final b in PeopleBucket.values) {
        final frame = ReportFrame(
          deviceId: Uint8List.fromList(List.generate(8, (i) => i + 1)),
          seq: 1,
          rev: 0,
          prioHint: 2,
          incidentType: 1,
          flags: 0x80,
          peopleBucket: b.code,
          locQuality: LocQuality.none,
          capturedAt: 1786370851,
          batteryQ: 8,
        );
        expect(PeopleBucket.fromCode(decodeReportFrame(encodeReportFrame(frame, key), key).peopleBucket), b);
      }
    });
  });
}
