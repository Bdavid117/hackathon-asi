import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

final Uint8List key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));

void main() {
  final ds = generateDataset(const SynthConfig(seed: 5, incidents: 10, reports: 100, adversarialPairs: 2));

  test('todas las tramas decodifican y llevan lo que dice el reporte', () {
    final frames = synthFrames(ds.reports, key);
    expect(frames, hasLength(ds.reports.length));
    for (final f in frames) {
      final d = decodeReportFrame(f.bytes, key);
      expect(d.flags, f.source.flags);
      expect(d.reportKey, f.reportKey);
      expect(d.rev, 0);
      expect(d.text, isNot(equals('')));
    }
  });

  test('es determinista: las mismas entradas dan las mismas claves y bytes', () {
    final a = synthFrames(ds.reports, key), b = synthFrames(ds.reports, key);
    expect(a.map((f) => f.reportKey).toList(), b.map((f) => f.reportKey).toList());
    expect(a.first.bytes, b.first.bytes);
  });

  test('la secuencia se numera por dispositivo en el orden dado y las claves son únicas', () {
    final frames = synthFrames(ds.reports, key);
    expect(frames.map((f) => f.reportKey).toSet(), hasLength(frames.length));
    final byDev = <String, List<int>>{};
    for (final f in frames) {
      (byDev[f.source.deviceId] ??= []).add(int.parse(f.reportKey.split('-').last));
    }
    for (final seqs in byDev.values) {
      expect(seqs, [for (var i = 1; i <= seqs.length; i++) i]);
    }
  });

  group('textReportFrame (T12, T18, T19)', () {
    test('las pares dicen «encerrados» y las impares no; cada n da un dispositivo distinto y una trama que decodifica', () {
      final even = decodeReportFrame(textReportFrame(2, key), key), odd = decodeReportFrame(textReportFrame(3, key), key);
      expect(even.text, contains('encerrados'));
      expect(odd.text, isNot(contains('encerrados')));
      expect(even.deviceId, isNot(odd.deviceId));
      expect(even.flags, 0);
      expect(even.lat, isNotNull);
    });

    test('es determinista: el mismo n da la misma trama', () {
      expect(textReportFrame(7, key), textReportFrame(7, key));
    });
  });
}
