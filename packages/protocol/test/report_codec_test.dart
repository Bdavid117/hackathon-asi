import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void expectSameFrame(ReportFrame a, ReportFrame e) {
  expect(deviceIdToHex(a.deviceId), deviceIdToHex(e.deviceId));
  expect(a.seq, e.seq);
  expect(a.rev, e.rev);
  expect(a.refSeq, e.refSeq);
  expect(a.prioHint, e.prioHint);
  expect(a.incidentType, e.incidentType);
  expect(a.flags, e.flags);
  expect(a.peopleBucket, e.peopleBucket);
  expect(a.locQuality, e.locQuality);
  if (e.lat == null) {
    expect(a.lat, isNull);
    expect(a.lon, isNull);
  } else {
    expect(a.lat, closeTo(e.lat!, 1.1e-5));
    expect(a.lon, closeTo(e.lon!, 1.1e-5));
  }
  expect(a.capturedAt, e.capturedAt);
  expect(a.batteryQ, e.batteryQ);
  expect(a.text, e.text);
}

void main() {
  group('vectores de oro del oráculo de Python', () {
    for (final v in vectors(kind: 'report')) {
      final name = v['name']! as String;
      test('$name: codifica exactamente los bytes del oráculo', () {
        final f = frameFromInput(v['input']! as Map<String, Object?>);
        expect(encodeReportFrame(f, testKey), hexBytes(v['hex']! as String));
      });
      test('$name: decodifica y recupera todos los campos', () {
        final expected = frameFromInput(v['input']! as Map<String, Object?>);
        final decoded = decodeReportFrame(hexBytes(v['hex']! as String), testKey);
        expectSameFrame(decoded, expected);
      });
    }
  });

  group('tamaños medidos', () {
    int size(String n) => encodeReportFrame(frameFromInput(vector(n)['input']! as Map<String, Object?>), testKey).length;
    test('SOS mínimo = 33 B', () => expect(size('sos_min'), 33));
    test('revisión sin texto = 37 B', () => expect(size('rev_no_text'), 37));
    test('revisión con texto de 85 caracteres = 123 B', () => expect(size('rev_with_text'), 123));
    test('sin ubicación = 27 B', () => expect(size('no_location'), 27));
  });

  group('casos de borde', () {
    test('sin ubicación: lat y lon son nulos y la calidad es none', () {
      final d = decodeReportFrame(hexBytes(vector('no_location')['hex']! as String), testKey);
      expect(d.locQuality, LocQuality.none);
      expect(d.lat, isNull);
      expect(d.lon, isNull);
    });

    test('device_id con el bit alto y seq máximo viajan intactos', () {
      final d = decodeReportFrame(hexBytes(vector('high_bit_device')['hex']! as String), testKey);
      expect(deviceIdToHex(d.deviceId), 'ffffffffffffffff');
      expect(d.seq, 4294967295);
      expect(d.capturedAt, 4294967295);
    });

    test('texto de 140 bytes con acentos es válido; 142 bytes se rechaza', () {
      final d = decodeReportFrame(hexBytes(vector('text_accents_140')['hex']! as String), testKey);
      expect(d.text, 'á' * 70);
      final base = frameFromInput(vector('sos_min')['input']! as Map<String, Object?>);
      expect(
        () => ReportFrame(
          deviceId: base.deviceId, seq: 5, rev: 0, prioHint: 0, incidentType: 1, flags: 0, peopleBucket: 0,
          locQuality: LocQuality.none, capturedAt: 1, batteryQ: 1, text: 'á' * 71,
        ),
        throwsArgumentError,
      );
    });

    test('truncateUtf8 nunca parte un carácter', () {
      final t = truncateUtf8('á' * 100, 141);
      expect(t, 'á' * 70);
      expect(truncateUtf8('hola', 140), 'hola');
      expect(truncateUtf8('añoñ', 3), 'añ');
    });

    test('rev > 0 exige ref_seq y rev == 0 lo prohíbe', () {
      final id = Uint8List(8);
      ReportFrame make({required int rev, int? ref}) => ReportFrame(
            deviceId: id, seq: 2, rev: rev, refSeq: ref, prioHint: 0, incidentType: 1, flags: 0,
            peopleBucket: 0, locQuality: LocQuality.none, capturedAt: 1, batteryQ: 1,
          );
      expect(() => make(rev: 1), throwsArgumentError);
      expect(() => make(rev: 0, ref: 1), throwsArgumentError);
      expect(make(rev: 1, ref: 1).reportKey, '0000000000000000-1');
      expect(make(rev: 0).reportKey, '0000000000000000-2');
    });

    test('lat/lon sólo con calidad de ubicación 1..5', () {
      expect(
        () => ReportFrame(
          deviceId: Uint8List(8), seq: 1, rev: 0, prioHint: 0, incidentType: 1, flags: 0, peopleBucket: 0,
          locQuality: LocQuality.none, lat: 1, lon: 1, capturedAt: 1, batteryQ: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('prioHintFromFlags (única tabla de prioridad)', () {
    const atrapado = 0x80, herido = 0x40, incendio = 0x20, respira = 0x10, via = 0x08, estructura = 0x04, menores = 0x02;
    test('P1 (0)', () {
      expect(prioHintFromFlags(respira), 0);
      expect(prioHintFromFlags(atrapado | herido), 0);
      expect(prioHintFromFlags(atrapado | incendio), 0);
    });
    test('P2 (1): atrapado, incendio, herido, estructura — nunca peor que P2', () {
      for (final f in [atrapado, incendio, herido, estructura]) {
        expect(prioHintFromFlags(f), 1, reason: 'flags=$f');
      }
    });
    test('P3 (2): vía bloqueada, menores, medicación y SIN BANDERAS (sin datos nunca baja la urgencia)', () {
      expect(prioHintFromFlags(via), 2);
      expect(prioHintFromFlags(menores), 2);
      expect(prioHintFromFlags(0x01), 2);
      expect(prioHintFromFlags(0), 2, reason: 'un SOS sin detalle no es «poco urgente»: ficha del agente 2');
    });

    test('con banderas, el teléfono nunca propone P4 (3): ese nivel sólo lo da el triaje al ver una negación explícita', () {
      for (var f = 0; f < 256; f++) {
        expect(prioHintFromFlags(f), lessThanOrEqualTo(2), reason: 'flags=$f');
      }
    });
  });

  group('errores tipados', () {
    final good = hexBytes(vector('sos_min')['hex']! as String);

    test('un byte alterado en la carga → BadTag', () {
      final bad = Uint8List.fromList(good)..[20] ^= 0xFF;
      expect(() => decodeReportFrame(bad, testKey), throwsA(isA<BadTag>()));
    });
    test('clave equivocada → BadTag', () {
      expect(() => decodeReportFrame(good, Uint8List.fromList([1, 2, 3])), throwsA(isA<BadTag>()));
    });
    test('recortada a 10 bytes → TruncatedFrame', () {
      expect(() => decodeReportFrame(Uint8List.sublistView(good, 0, 10), testKey), throwsA(isA<TruncatedFrame>()));
    });
    test('recortada a 30 bytes → TruncatedFrame', () {
      expect(() => decodeReportFrame(Uint8List.sublistView(good, 0, 30), testKey), throwsA(isA<TruncatedFrame>()));
    });
    test('vacía → TruncatedFrame', () {
      expect(() => decodeReportFrame(Uint8List(0), testKey), throwsA(isA<TruncatedFrame>()));
    });
    test('versión distinta de 0 → UnsupportedVersion', () {
      final bad = Uint8List.fromList(good)..[0] = 0x11;
      expect(() => decodeReportFrame(bad, testKey), throwsA(isA<UnsupportedVersion>()));
    });
    test('bit FRAG activo → UnsupportedFeature', () {
      final bad = Uint8List.fromList(good)..[1] |= 0x80;
      expect(() => decodeReportFrame(bad, testKey), throwsA(isA<UnsupportedFeature>()));
    });
    test('un ACK pasado al decodificador de reportes → WrongType', () {
      final ack = hexBytes(vector('ack_basic')['hex']! as String);
      expect(() => decodeReportFrame(ack, testKey), throwsA(isA<WrongType>()));
    });
    test('bytes sobrantes tras la etiqueta → FrameException', () {
      final extra = Uint8List.fromList([...good, 0]);
      expect(() => decodeReportFrame(extra, testKey), throwsA(isA<FrameException>()));
    });
  });
}
