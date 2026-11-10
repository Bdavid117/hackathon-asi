import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import '../tool/expo_scenario.dart';

void main() {
  const nowMs = 1800000000000;

  List<CoverageReport> asCoverage(List<ExpoReport> rs) => [for (final r in rs) CoverageReport(lat: r.lat, lon: r.lon, receivedAtMs: nowMs - r.minutesAgo * 60 * 1000, urgent: r.urgent)];

  group('el escenario de exposición (datos SINTÉTICOS: seis zonas de Manizales y seis horas de historia)', () {
    test('es reproducible: la misma semilla da lo mismo, otra semilla da otra historia', () {
      String sig(List<ExpoReport> r) => r.map((e) => '${e.minutesAgo}/${e.zone}/${e.flags}/${e.device}/${e.lat.toStringAsFixed(5)}').join('|');
      expect(sig(buildExpoScenario(seed: 7)), sig(buildExpoScenario(seed: 7)));
      expect(sig(buildExpoScenario(seed: 7)), isNot(sig(buildExpoScenario(seed: 8))));
    });

    test('viene ordenado del más viejo al más nuevo y todo cae en la ventana de seis horas, sin tocar los últimos 3 minutos (se dejan para lo que se haga en vivo)', () {
      final rs = buildExpoScenario();
      for (var i = 1; i < rs.length; i++) {
        expect(rs[i].minutesAgo, lessThanOrEqualTo(rs[i - 1].minutesAgo), reason: 'de más viejo a más nuevo');
      }
      expect(rs.first.minutesAgo, lessThanOrEqualTo(kExpoWindowMinutes));
      expect(rs.last.minutesAgo, greaterThanOrEqualTo(3));
    });

    test('cada reporte lleva un dispositivo distinto (un reporte por dispositivo: no se confunde con una revisión)', () {
      final rs = buildExpoScenario();
      expect({for (final r in rs) r.device}.length, rs.length);
      for (final r in rs) {
        expect(r.device, matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });

    test('cada zona cabe en UNA celda de la rejilla del nodo (así «una zona» y «una celda» son lo mismo)', () {
      for (final r in buildExpoScenario()) {
        final zone = kExpoZones.firstWhere((z) => z.name == r.zone);
        expect((r.lat - zone.lat).abs(), lessThan(kCoverageCellDeg / 2));
        expect((r.lon - zone.lon).abs(), lessThan(kCoverageCellDeg / 2));
      }
    });

    test('hay reportes de varias urgencias y alguno sin ubicación utilizable no existe: todos tienen coordenadas', () {
      final rs = buildExpoScenario();
      expect(rs.where((r) => r.urgent).length, greaterThanOrEqualTo(5), reason: 'hay urgentes (P1/P2)');
      expect(rs.where((r) => !r.urgent).length, greaterThanOrEqualTo(10), reason: 'y no urgentes');
      expect(rs.every((r) => r.lat.isFinite && r.lon.isFinite), isTrue);
    });

    test('el detector marca EXACTAMENTE las zonas que el guion promete: las que callaron hace 30 min o más', () {
      final c = buildCoverage(asCoverage(buildExpoScenario()), nowMs: nowMs, withoutLocation: 0);
      final silentIds = {for (final z in (c['cells']! as List).cast<Map<String, Object?>>()) z['id']! as String};
      final expected = {for (final z in kExpoZones) if (z.silentSinceMinutes != null) z.cellId};
      expect(silentIds, expected);
      expect(c['silentTotal'], expected.length);
      expect(c['activeCells'], kExpoZones.where((z) => z.silentSinceMinutes == null).length, reason: 'las demás siguen reportando');
    });

    test('al pasar el tiempo SIN reportes nuevos, las zonas activas también acaban en silencio (por eso se dice cuándo se sembró)', () {
      final later = nowMs + 60 * 60 * 1000;
      final c = buildCoverage(asCoverage(buildExpoScenario()), nowMs: later, withoutLocation: 0);
      expect(c['silentTotal'], kExpoZones.length);
      expect(c['activeCells'], 0);
    });

    test('una zona silenciosa con un solo reporte existe (el caso «un mensaje suelto») y otra silenciosa tuvo un urgente', () {
      final rs = buildExpoScenario();
      final single = kExpoZones.where((z) => z.silentSinceMinutes != null && rs.where((r) => r.zone == z.name).length == 1);
      expect(single, isNotEmpty);
      final withUrgent = kExpoZones.where((z) => z.silentSinceMinutes != null && rs.any((r) => r.zone == z.name && r.urgent));
      expect(withUrgent, isNotEmpty);
    });

    test('las zonas en silencio no tienen NINGÚN reporte más reciente que su silencio declarado', () {
      for (final r in buildExpoScenario()) {
        final zone = kExpoZones.firstWhere((z) => z.name == r.zone);
        if (zone.silentSinceMinutes != null) expect(r.minutesAgo, greaterThanOrEqualTo(zone.silentSinceMinutes!), reason: '${zone.name} calló hace ${zone.silentSinceMinutes} min');
      }
    });
  });
}
