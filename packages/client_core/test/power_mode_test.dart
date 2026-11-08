import 'package:sard_client_core/sard_client_core.dart';
import 'package:test/test.dart';

void main() {
  group('powerModeFor', () {
    test('batería desconocida → normal (nunca se degrada la función por no saber)', () {
      expect(powerModeFor(null), PowerMode.normal);
    });
    test('fronteras: ≥ 20 % normal; 19..5 % ahorro; < 5 % sólo SOS', () {
      expect(powerModeFor(100), PowerMode.normal);
      expect(powerModeFor(20), PowerMode.normal);
      expect(powerModeFor(19), PowerMode.saver);
      expect(powerModeFor(5), PowerMode.saver);
      expect(powerModeFor(4), PowerMode.sosOnly);
      expect(powerModeFor(0), PowerMode.sosOnly);
    });
    test('valores fuera de rango se acotan', () {
      expect(powerModeFor(150), PowerMode.normal);
      expect(powerModeFor(-3), PowerMode.sosOnly);
    });
  });

  group('batteryQFromPercent (4 bits)', () {
    test('100 % → 15 y 0 % → 0', () {
      expect(batteryQFromPercent(100), 15);
      expect(batteryQFromPercent(0), 0);
    });
    test('50 % → 8 (redondeo de 7,5)', () => expect(batteryQFromPercent(50), 8));
    test('se acota a 0..15', () {
      expect(batteryQFromPercent(140), 15);
      expect(batteryQFromPercent(-9), 0);
    });
    test('desconocida → el marcador 15, no un número inventado', () {
      expect(batteryQFromPercent(null), 15);
      expect(batteryQFromPercent(null, unknown: 7), 7);
    });
  });
}
