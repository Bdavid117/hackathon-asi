import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('la distancia entre un punto y él mismo es 0', () {
    expect(distanceMeters(5.07, -75.52, 5.07, -75.52), 0);
  });

  test('0,001° de latitud son ≈ 111 m; 0,001° de longitud a 5° N, ≈ 111 m × cos(5°)', () {
    expect(distanceMeters(5.07, -75.52, 5.071, -75.52), closeTo(111.2, 0.6));
    expect(distanceMeters(5.07, -75.52, 5.07, -75.519), closeTo(110.8, 0.6));
  });

  test('es simétrica', () {
    expect(distanceMeters(5.07, -75.52, 5.08, -75.50), closeTo(distanceMeters(5.08, -75.50, 5.07, -75.52), 1e-6));
  });

  test('σ por calidad de ubicación: 10, 50, 200, 1 000 y 3 000 m; manual = 3 000; ninguna = null', () {
    expect(sigmaMeters(LocQuality.within10m), 10);
    expect(sigmaMeters(LocQuality.within50m), 50);
    expect(sigmaMeters(LocQuality.within200m), 200);
    expect(sigmaMeters(LocQuality.within1km), 1000);
    expect(sigmaMeters(LocQuality.over1km), 3000);
    expect(sigmaMeters(LocQuality.manual), 3000);
    expect(sigmaMeters(LocQuality.none), isNull);
  });
}
