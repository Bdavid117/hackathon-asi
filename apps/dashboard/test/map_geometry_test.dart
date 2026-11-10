import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/map_geometry.dart';

const double _mPerDegLat = 111320.0;

/// Un punto a [north] metros al norte y [east] al este de [o] (aproximación local: sirve para comparar).
GeoPoint at(GeoPoint o, {double north = 0, double east = 0}) =>
    GeoPoint(o.lat + north / _mPerDegLat, o.lon + east / (_mPerDegLat * math.cos(o.lat * math.pi / 180)));

double dist(Px a, Px b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

void main() {
  const manizales = GeoPoint(5.0689, -75.5174);

  group('MapFrame.around: el encuadre', () {
    test('con un solo punto no se acerca sin límite: abarca al menos el span mínimo', () {
      final f = MapFrame.around([manizales], minSpanMeters: 1000);
      expect(f.contains(manizales), isTrue);
      expect((f.north - f.south) * _mPerDegLat, greaterThanOrEqualTo(1000));
      expect(f.center.lat, closeTo(manizales.lat, 1e-9));
      expect(f.center.lon, closeTo(manizales.lon, 1e-9));
    });

    test('contiene todos los puntos y los deja dentro del lienzo con margen', () {
      final pts = [manizales, at(manizales, north: 3000, east: -2000), at(manizales, north: -1500, east: 4000)];
      final f = MapFrame.around(pts, margin: 0.15);
      for (final p in pts) {
        expect(f.contains(p), isTrue);
        final px = f.project(p, width: 800, height: 600);
        expect(px.x, inInclusiveRange(0, 800));
        expect(px.y, inInclusiveRange(0, 600));
      }
      // «con margen»: el punto más extremo no queda pegado al borde del lienzo.
      final xs = [for (final p in pts) f.project(p, width: 800, height: 600).x];
      final ys = [for (final p in pts) f.project(p, width: 800, height: 600).y];
      expect([xs.reduce(math.min), 800 - xs.reduce(math.max), ys.reduce(math.min), 600 - ys.reduce(math.max)].reduce(math.min), greaterThan(8));
    });

    test('los cuatro bordes cuentan como dentro, y un paso más allá ya es fuera', () {
      const f = MapFrame(south: 5.0, north: 5.1, west: -75.6, east: -75.5);
      for (final p in const [GeoPoint(5.0, -75.55), GeoPoint(5.1, -75.55), GeoPoint(5.05, -75.6), GeoPoint(5.05, -75.5)]) {
        expect(f.contains(p), isTrue, reason: '$p está justo en el borde');
      }
      for (final p in const [GeoPoint(4.9999, -75.55), GeoPoint(5.1001, -75.55), GeoPoint(5.05, -75.6001), GeoPoint(5.05, -75.4999)]) {
        expect(f.contains(p), isFalse, reason: '$p está fuera');
      }
    });

    test('sin puntos no inventa un encuadre: es nulo', () {
      expect(MapFrame.aroundOrNull(const []), isNull);
    });
  });

  group('MapFrame.project: la proyección', () {
    final f = MapFrame.around([manizales, at(manizales, north: 2000, east: 2000), at(manizales, north: -2000, east: -2000)]);

    test('el centro cae en el centro del lienzo', () {
      final c = f.project(f.center, width: 800, height: 600);
      expect(c.x, closeTo(400, 1e-6));
      expect(c.y, closeTo(300, 1e-6));
    });

    test('el norte queda arriba y el este a la derecha', () {
      final c = f.project(f.center, width: 800, height: 600);
      expect(f.project(at(f.center, north: 500), width: 800, height: 600).y, lessThan(c.y));
      expect(f.project(at(f.center, east: 500), width: 800, height: 600).x, greaterThan(c.x));
    });

    test('la escala es la misma en los dos ejes: 1 km al norte y 1 km al este miden lo mismo', () {
      final c = f.project(f.center, width: 800, height: 600);
      final n = f.project(at(f.center, north: 1000), width: 800, height: 600);
      final e = f.project(at(f.center, east: 1000), width: 800, height: 600);
      expect(dist(c, e) / dist(c, n), closeTo(1.0, 0.01));
    });

    test('la escala sigue siendo igual a una latitud alta, donde el coseno importa (60°: 1° de longitud mide la mitad)', () {
      const north60 = GeoPoint(60.0, 10.0);
      final g = MapFrame.around([north60, at(north60, north: 2000, east: 2000), at(north60, north: -2000, east: -2000)]);
      final c = g.project(g.center, width: 800, height: 600);
      final n = g.project(at(g.center, north: 1000), width: 800, height: 600);
      final e = g.project(at(g.center, east: 1000), width: 800, height: 600);
      expect(dist(c, e) / dist(c, n), closeTo(1.0, 0.01));
    });

    test('y lo APROVECHA: el eje que limita llena el lienzo de borde a borde (a 5° y a 60° de latitud)', () {
      for (final origin in const [GeoPoint(5.0689, -75.5174), GeoPoint(60.0, 10.0)]) {
        final g = MapFrame.around([origin, at(origin, north: 2000, east: 2000), at(origin, north: -2000, east: -2000)]);
        for (final (w, h) in [(800.0, 600.0), (300.0, 900.0), (900.0, 300.0)]) {
          final a = g.project(GeoPoint(g.south, g.west), width: w, height: h);
          final b = g.project(GeoPoint(g.north, g.east), width: w, height: h);
          final fillsWidth = (a.x - 0).abs() < 1e-6 && (b.x - w).abs() < 1e-6;
          final fillsHeight = (b.y - 0).abs() < 1e-6 && (a.y - h).abs() < 1e-6;
          expect(fillsWidth || fillsHeight, isTrue, reason: 'en ${origin.lat}° y un lienzo de $w×$h el encuadre no llena ningún eje');
        }
      }
    });

    test('todo el encuadre cabe en lienzos de cualquier forma (ancho, alto, cuadrado)', () {
      for (final (w, h) in [(1200.0, 300.0), (300.0, 1200.0), (500.0, 500.0)]) {
        for (final p in [GeoPoint(f.south, f.west), GeoPoint(f.south, f.east), GeoPoint(f.north, f.west), GeoPoint(f.north, f.east)]) {
          final px = f.project(p, width: w, height: h);
          expect(px.x, inInclusiveRange(-1e-6, w + 1e-6), reason: 'x en $w×$h');
          expect(px.y, inInclusiveRange(-1e-6, h + 1e-6), reason: 'y en $w×$h');
        }
      }
    });
  });

  group('metros y píxeles: el anillo de precisión y la barra de escala', () {
    final f = MapFrame.around([manizales, at(manizales, north: 2000, east: 2000), at(manizales, north: -2000, east: -2000)]);

    test('metersToPixels coincide con lo que miden de verdad 1 km al norte y 1 km al este', () {
      final c = f.project(f.center, width: 800, height: 600);
      final n = f.project(at(f.center, north: 1000), width: 800, height: 600);
      final e = f.project(at(f.center, east: 1000), width: 800, height: 600);
      final px = f.metersToPixels(1000, width: 800, height: 600);
      expect(dist(c, n), closeTo(px, px * 0.005));
      expect(dist(c, e), closeTo(px, px * 0.005));
    });

    test('metersToPixels también cuadra a 60° de latitud, donde el coseno es 0,5', () {
      const n60 = GeoPoint(60.0, 10.0);
      final g = MapFrame.around([n60, at(n60, north: 2000, east: 2000), at(n60, north: -2000, east: -2000)]);
      final c = g.project(g.center, width: 800, height: 600);
      final e = g.project(at(g.center, east: 1000), width: 800, height: 600);
      final px = g.metersToPixels(1000, width: 800, height: 600);
      expect(dist(c, e), closeTo(px, px * 0.01));
    });

    test('al duplicar los metros se duplican los píxeles', () {
      expect(f.metersToPixels(400, width: 800, height: 600), closeTo(2 * f.metersToPixels(200, width: 800, height: 600), 1e-9));
    });

    test('niceScaleMeters elige la cifra redonda más grande que cabe', () {
      expect(niceScaleMeters(0.4, maxPx: 140), 200, reason: '140 px = 350 m → la redonda ≤ 350 es 200');
      expect(niceScaleMeters(0.01, maxPx: 140), 10000, reason: '140 px = 14 000 m');
      expect(niceScaleMeters(10, maxPx: 140), 10, reason: '140 px = 14 m');
      expect(niceScaleMeters(0.14, maxPx: 140), 1000, reason: '140 px = 1000 m justos');
      expect(niceScaleMeters(0.25, maxPx: 140), 500, reason: '140 px = 560 m → la redonda ≤ 560 es 500');
    });

    test('con una escala absurda no se rompe: nunca devuelve algo que no quepa salvo el mínimo de 1 m', () {
      expect(niceScaleMeters(1000, maxPx: 140), 1);
      expect(niceScaleMeters(0.0000001, maxPx: 140), greaterThan(1000000));
    });
  });

  group('MapFrame: el encuadre NO se mueve solo (los datos llegan cada 2 s)', () {
    final f = MapFrame.around([manizales, at(manizales, north: 2000, east: 1500)]);

    test('un punto nuevo dentro no cambia dónde cae ninguno de los demás', () {
      final before = f.project(manizales, width: 800, height: 600);
      final fresh = at(manizales, north: 900, east: 700);
      expect(f.contains(fresh), isTrue);
      expect(f.outside([manizales, fresh]), isEmpty);
      final after = f.project(manizales, width: 800, height: 600);
      expect((after.x, after.y), (before.x, before.y));
    });

    test('un punto nuevo FUERA se avisa, y el encuadre sigue igual hasta que alguien lo pida', () {
      final far = at(manizales, north: 20000, east: -15000);
      expect(f.contains(far), isFalse);
      expect(f.outside([manizales, far]), [far]);
      // sin pedirlo, nada se movió:
      expect(f.project(manizales, width: 800, height: 600).x, MapFrame.around([manizales, at(manizales, north: 2000, east: 1500)]).project(manizales, width: 800, height: 600).x);
    });

    test('reencuadrar es explícito: ajustar de nuevo a TODOS los puntos abarca el lejano y los de antes', () {
      final far = at(manizales, north: 20000, east: -15000);
      final old = at(manizales, north: 2000, east: 1500);
      final g = MapFrame.around([manizales, old, far]);
      for (final p in [manizales, old, far]) {
        expect(g.contains(p), isTrue);
      }
    });
  });

  group('clusterMarkers: dos incidentes en el mismo sitio no se tapan', () {
    MapMarker m(String id, String u, double x, double y) => MapMarker(id: id, urgency: u, at: Px(x, y));

    test('dos en el mismo punto son UN grupo de 2, con el más urgente encima', () {
      final cs = clusterMarkers([m('a', 'P3', 50, 50), m('b', 'P1', 50, 50)], radiusPx: 14);
      expect(cs, hasLength(1));
      expect(cs.single.count, 2);
      expect(cs.single.urgency, 'P1');
      expect(cs.single.members.first.id, 'b');
    });

    test('lejanos son grupos separados', () {
      final cs = clusterMarkers([m('a', 'P3', 10, 10), m('b', 'P3', 300, 200)], radiusPx: 14);
      expect(cs, hasLength(2));
      expect(cs.every((c) => c.count == 1), isTrue);
    });

    test('un P1 cerca de un P3 nunca se esconde: el grupo es P1', () {
      final cs = clusterMarkers([m('x', 'P3', 100, 100), m('y', 'P3', 104, 103), m('z', 'P1', 108, 100)], radiusPx: 14);
      expect(cs.map((c) => c.urgency), contains('P1'));
      expect(cs.expand((c) => c.members).map((e) => e.id).toSet(), {'x', 'y', 'z'});
    });

    test('no inventa posiciones: el grupo se dibuja donde está su miembro más urgente', () {
      final cs = clusterMarkers([m('a', 'P3', 60, 60), m('b', 'P2', 64, 62)], radiusPx: 14);
      expect((cs.single.at.x, cs.single.at.y), (64.0, 62.0));
    });

    test('el resultado no depende del orden de entrada', () {
      final input = [for (var i = 0; i < 40; i++) m('i$i', ['P1', 'P2', 'P3', 'P4'][i % 4], (i * 37 % 200).toDouble(), (i * 53 % 150).toDouble())];
      String sig(List<MarkerCluster> cs) {
        final parts = [for (final c in cs) (c.members.map((e) => e.id).toList()..sort()).join(',')]..sort();
        return parts.join('|');
      }
      final rnd = math.Random(7);
      final base = sig(clusterMarkers(input, radiusPx: 14));
      for (var k = 0; k < 20; k++) {
        expect(sig(clusterMarkers([...input]..shuffle(rnd), radiusPx: 14)), base);
      }
    });

    test('el desempate por identificador hace que a, b, c en cadena den el MISMO resultado se entren como se entren', () {
      // a–b y b–c están a 10 px (dentro del radio de 14), a–c a 20 px (fuera): el grupo depende de quién ancla.
      final a = m('a', 'P3', 0, 0), b = m('b', 'P3', 10, 0), c = m('c', 'P3', 20, 0);
      String sig(List<MarkerCluster> cs) => ([for (final k in cs) (k.members.map((e) => e.id).toList()..sort()).join('+')]..sort()).join(' | ');
      final expected = sig(clusterMarkers([a, b, c], radiusPx: 14));
      expect(expected, 'a+b | c', reason: 'ancla a (el primero por id): b se une, c queda aparte');
      expect(sig(clusterMarkers([c, b, a], radiusPx: 14)), expected);
      expect(sig(clusterMarkers([b, c, a], radiusPx: 14)), expected);
    });

    test('dos incidentes separados SÓLO en vertical son dos grupos', () {
      final cs = clusterMarkers([m('a', 'P3', 50, 50), m('b', 'P3', 50, 100)], radiusPx: 14);
      expect(cs, hasLength(2));
    });

    test('propiedad: no se pierde ningún incidente', () {
      final rnd = math.Random(11);
      for (var round = 0; round < 50; round++) {
        final n = 1 + rnd.nextInt(60);
        final input = [for (var i = 0; i < n; i++) m('r$round-$i', ['P1', 'P2', 'P3', 'P4'][rnd.nextInt(4)], rnd.nextDouble() * 120, rnd.nextDouble() * 90)];
        final cs = clusterMarkers(input, radiusPx: 14);
        expect(cs.fold<int>(0, (s, c) => s + c.count), n);
        expect(cs.expand((c) => c.members).map((e) => e.id).toSet(), {for (final e in input) e.id});
      }
    });
  });

  group('hitTest: tocar un marcador', () {
    MapMarker m(String id, String u, double x, double y) => MapMarker(id: id, urgency: u, at: Px(x, y));

    test('elige el grupo más cercano dentro del radio', () {
      final cs = clusterMarkers([m('a', 'P3', 50, 50), m('b', 'P3', 200, 50)], radiusPx: 14);
      expect(hitTest(cs, const Px(54, 52), radiusPx: 18)?.members.single.id, 'a');
      expect(hitTest(cs, const Px(196, 48), radiusPx: 18)?.members.single.id, 'b');
    });

    test('con dos al alcance elige el MÁS CERCANO, no el primero', () {
      final cs = clusterMarkers([m('a', 'P3', 50, 50), m('b', 'P3', 66, 50)], radiusPx: 4);
      expect(cs, hasLength(2));
      expect(hitTest(cs, const Px(64, 50), radiusPx: 18)?.members.single.id, 'b', reason: 'b está a 2 px; a, a 14 px');
      expect(hitTest(cs, const Px(52, 50), radiusPx: 18)?.members.single.id, 'a');
    });

    test('a igual distancia elige el más urgente', () {
      final cs = clusterMarkers([m('a', 'P3', 40, 50), m('b', 'P1', 60, 50)], radiusPx: 4);
      expect(hitTest(cs, const Px(50, 50), radiusPx: 18)?.members.single.id, 'b');
    });

    test('fuera del radio no elige nada', () {
      final cs = clusterMarkers([m('a', 'P3', 50, 50)], radiusPx: 14);
      expect(hitTest(cs, const Px(120, 120), radiusPx: 18), isNull);
    });
  });
}
