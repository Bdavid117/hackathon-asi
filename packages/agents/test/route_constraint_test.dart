import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'rec_support.dart';

/// El incidente está en (5.0703, -75.5138); la ambulancia más cercana, AMB-01, en (5.0710, -75.5140): a ≈ 80 m.
/// Un punto a [metersNorth] / [metersEast] del incidente.
(double, double) near({double metersNorth = 0, double metersEast = 0}) => (5.0703 + metersNorth / 111320, -75.5138 + metersEast / (111320 * 0.9963));

RoadBlock block(double lat, double lon, {String source = 'otro-1'}) => RoadBlock(lat: lat, lon: lon, source: source);

Recommendation rec(List<RoadBlock> blocks, {List<Resource>? res, String id = 'aa-1'}) {
  final v = view([member('aa-1', flags: SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada')], id: id);
  return recommend(v, res ?? resources, blockedRoads: blocks) as Recommendation;
}

void main() {
  group('distanceToSegmentMeters', () {
    // Un segmento de ≈ 1 km hacia el este, a la latitud de Manizales.
    const aLat = 5.07, aLon = -75.52;
    final bLon = aLon + 1000 / (111320 * 0.9963);

    test('un punto sobre el segmento está a ≈ 0 m', () {
      expect(distanceToSegmentMeters(aLat, aLon + 0.004, aLat, aLon, aLat, bLon), lessThan(1));
    });

    test('a un lado: la distancia perpendicular (≈ 300 m al norte)', () {
      expect(distanceToSegmentMeters(aLat + 300 / 111320, aLon + 0.004, aLat, aLon, aLat, bLon), closeTo(300, 3));
    });

    test('más allá de un extremo: la distancia a ese extremo, no a la recta infinita', () {
      final pLon = bLon + 500 / (111320 * 0.9963); // 500 m después de B
      expect(distanceToSegmentMeters(aLat, pLon, aLat, aLon, aLat, bLon), closeTo(500, 5));
      expect(distanceToSegmentMeters(aLat, aLon - 500 / (111320 * 0.9963), aLat, aLon, aLat, bLon), closeTo(500, 5));
    });

    test('la corrección por la latitud importa a 60° (un grado de longitud mide la mitad): 500 m más allá del extremo siguen siendo 500 m', () {
      const lat = 60.0, lon = 10.0;
      final bLon60 = lon + 1000 / (111320 * 0.5);
      final pLon = bLon60 + 500 / (111320 * 0.5);
      expect(distanceToSegmentMeters(lat, pLon, lat, lon, lat, bLon60), closeTo(500, 6));
    });

    test('un segmento degenerado (A = B) es la distancia al punto', () {
      expect(distanceToSegmentMeters(aLat + 200 / 111320, aLon, aLat, aLon, aLat, aLon), closeTo(200, 3));
    });

    test('es simétrico: A y B intercambiados dan lo mismo', () {
      final x = distanceToSegmentMeters(aLat + 123 / 111320, aLon + 0.003, aLat, aLon, aLat, bLon);
      final y = distanceToSegmentMeters(aLat + 123 / 111320, aLon + 0.003, aLat, bLon, aLat, aLon);
      expect(x, closeTo(y, 0.01));
    });
  });

  group('«confirmar_ruta»: una vía bloqueada cerca del trayecto', () {
    test('sin bloqueos conocidos, no se pide', () {
      expect(rec(const []).pending, isNot(contains('confirmar_ruta')));
    });

    test('un bloqueo sobre el trayecto unidad → incidente: se pide confirmar la ruta', () {
      final (la, lo) = near(metersNorth: 40, metersEast: -10); // entre AMB-01 y el incidente
      expect(rec([block(la, lo)]).pending, contains('confirmar_ruta'));
    });

    test('un bloqueo junto al INCIDENTE (≤ 500 m): se pide', () {
      final (la, lo) = near(metersEast: 400);
      expect(rec([block(la, lo)]).pending, contains('confirmar_ruta'));
    });

    test('un bloqueo junto a la UNIDAD (≤ 500 m): se pide', () {
      final (la, lo) = (5.0710 + 300 / 111320, -75.5140);
      expect(rec([block(la, lo)]).pending, contains('confirmar_ruta'));
    });

    test('un bloqueo lejos del trayecto (3 km): no se pide', () {
      final (la, lo) = near(metersNorth: 3000);
      expect(rec([block(la, lo)]).pending, isNot(contains('confirmar_ruta')));
    });

    test('un bloqueo EN MEDIO de un trayecto largo se detecta aunque quede lejos de los dos extremos (el trayecto cuenta, no sólo los extremos)', () {
      final far = [resources.firstWhere((r) => r.id == 'AMB-02')]; // a ≈ 16 km del incidente: la única unidad
      final mid = ((5.0703 + 5.15) / 2, (-75.5138 + -75.4) / 2);
      final off = (mid.$1 + 3000 / 111320, mid.$2); // a 3 km del trayecto
      expect(rec([block(mid.$1, mid.$2)], res: far).pending, contains('confirmar_ruta'));
      expect(rec([block(off.$1, off.$2)], res: far).pending, isNot(contains('confirmar_ruta')));
    });

    test('justo fuera del radio (600 m) no se pide; justo dentro (400 m) sí', () {
      final (farLa, farLo) = near(metersEast: 600);
      final (nearLa, nearLo) = near(metersEast: 400);
      expect(rec([block(farLa, farLo)]).pending, isNot(contains('confirmar_ruta')));
      expect(rec([block(nearLa, nearLo)]).pending, contains('confirmar_ruta'));
    });

    test('el bloqueo que es DEL MISMO incidente no cuenta contra sí mismo', () {
      final (la, lo) = near();
      expect(rec([block(la, lo, source: 'aa-1')], id: 'aa-1').pending, isNot(contains('confirmar_ruta')));
    });

    test('sin ninguna unidad disponible igual se avisa si el bloqueo está junto al incidente', () {
      final (la, lo) = near(metersEast: 300);
      final none = [for (final r in resources) Resource(id: r.id, kind: r.kind, label: r.label, lat: r.lat, lon: r.lon, available: false)];
      expect(rec([block(la, lo)], res: none).pending, contains('confirmar_ruta'));
    });

    test('NO cambia nada más: acciones, recursos, identificador, justificación ni incertidumbre (una aprobación vigente no caduca por esto)', () {
      final (la, lo) = near(metersEast: 200);
      final without = rec(const []), withBlock = rec([block(la, lo)]);
      expect(withBlock.id, without.id);
      expect(withBlock.actions, without.actions);
      expect(withBlock.resourceIds, without.resourceIds);
      expect(withBlock.uncertainty, without.uncertainty);
      expect(withBlock.justification.length, without.justification.length);
      expect(withBlock.pending.where((p) => p != 'confirmar_ruta'), without.pending);
    });

    test('el orden de los bloqueos no importa, y varios no repiten el aviso', () {
      final (a1, a2) = near(metersEast: 200);
      final (b1, b2) = near(metersNorth: 100);
      final x = rec([block(a1, a2), block(b1, b2, source: 'otro-2')]).pending;
      final y = rec([block(b1, b2, source: 'otro-2'), block(a1, a2)]).pending;
      expect(x, y);
      expect(x.where((p) => p == 'confirmar_ruta').length, 1);
    });

    test('un bloqueo con coordenadas absurdas (no finitas) se ignora sin romper', () {
      expect(rec([block(double.nan, 0), block(double.infinity, 0)]).pending, isNot(contains('confirmar_ruta')));
    });
  });
}
