import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('locQualityFromAccuracy (PDF §7.2)', () {
    final cases = <double, LocQuality>{
      0: LocQuality.within10m,
      10: LocQuality.within10m,
      10.1: LocQuality.within50m,
      50: LocQuality.within50m,
      50.1: LocQuality.within200m,
      200: LocQuality.within200m,
      200.1: LocQuality.within1km,
      1000: LocQuality.within1km,
      1000.1: LocQuality.over1km,
      50000: LocQuality.over1km,
    };
    cases.forEach((meters, q) => test('$meters m → ${q.name}', () => expect(locQualityFromAccuracy(meters), q)));

    test('una precisión negativa, NaN o infinita no es una ubicación utilizable', () {
      expect(locQualityFromAccuracy(-1), LocQuality.none);
      expect(locQualityFromAccuracy(double.nan), LocQuality.none);
      expect(locQualityFromAccuracy(double.infinity), LocQuality.none);
    });
  });

  group('LocationFix', () {
    final t = DateTime.fromMillisecondsSinceEpoch(1000000000);
    test('age y isFresh', () {
      final fix = LocationFix(lat: 5, lon: -75, accuracyMeters: 20, at: t);
      expect(fix.age(t.add(const Duration(seconds: 90))), const Duration(seconds: 90));
      expect(fix.isFresh(t.add(const Duration(seconds: 119))), isTrue);
      expect(fix.isFresh(t.add(const Duration(minutes: 2))), isFalse);
      expect(fix.isFresh(t.add(const Duration(minutes: 5)), maxAge: const Duration(minutes: 10)), isTrue);
    });
    test('una lectura «del futuro» (reloj atrasado) cuenta como edad 0, no negativa', () {
      final fix = LocationFix(lat: 5, lon: -75, accuracyMeters: 20, at: t.add(const Duration(minutes: 1)));
      expect(fix.age(t), Duration.zero);
    });
    test('coordenadas fuera de rango no son una lectura válida', () {
      expect(() => LocationFix(lat: 95, lon: 0, accuracyMeters: 5, at: t), throwsArgumentError);
      expect(() => LocationFix(lat: 0, lon: 200, accuracyMeters: 5, at: t), throwsArgumentError);
    });
  });
}
