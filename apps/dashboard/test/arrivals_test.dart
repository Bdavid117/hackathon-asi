import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/arrivals.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

IncidentRow mk(String id, String urgency, int? receivedAt) {
  final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
  return IncidentRow.fromJson({...base, 'id': id, 'urgency': urgency, 'receivedAt': receivedAt});
}

List<String> ids(Iterable<IncidentRow> rows) => [for (final r in rows) r.id];

void main() {
  group('la primera lectura no avisa de nada', () {
    test('lo que ya estaba al abrir no es una novedad', () {
      final a = Arrivals();
      final rows = [mk('a', 'P1', 1000), mk('b', 'P3', 2000)];
      a.observe(rows);
      expect(a.news(rows), isEmpty);
    });

    test('pero si al abrir no había NADA, lo primero que llegue sí es una novedad', () {
      final a = Arrivals();
      a.observe(const []);
      expect(ids(a.news([mk('a', 'P1', 5000)])), ['a']);
    });
  });

  group('lo que el nodo recibe después', () {
    test('un incidente nuevo es una novedad; los que ya estaban, no', () {
      final a = Arrivals();
      final first = [mk('a', 'P1', 1000), mk('b', 'P3', 2000)];
      a.observe(first);
      final later = [...first, mk('c', 'P2', 3000)];
      a.observe(later);
      expect(ids(a.news(later)), ['c']);
    });

    test('un incidente que ya estaba pero recibió un reporte más es una novedad (su hora de recepción subió)', () {
      final a = Arrivals();
      a.observe([mk('a', 'P1', 1000)]);
      final later = [mk('a', 'P1', 4000)];
      a.observe(later);
      expect(ids(a.news(later)), ['a']);
    });

    test('si dos incidentes se funden y el id cambia, NO se inventa una novedad (se compara la hora, no el id)', () {
      final a = Arrivals();
      a.observe([mk('x1', 'P2', 1000), mk('x2', 'P2', 1500)]);
      final merged = [mk('x1', 'P2', 1500)];
      a.observe(merged);
      expect(a.news(merged), isEmpty);
      final renamed = [mk('a-nuevo-id', 'P2', 1500)];
      a.observe(renamed);
      expect(a.news(renamed), isEmpty);
    });

    test('las novedades se acumulan hasta que alguien las ve (no se pierden en el siguiente sondeo)', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      final r1 = [mk('a', 'P3', 1000), mk('n1', 'P3', 2000)];
      a.observe(r1);
      final r2 = [...r1, mk('n2', 'P1', 3000)];
      a.observe(r2);
      expect(ids(a.news(r2)).toSet(), {'n1', 'n2'});
    });

    test('vienen con el más urgente primero (a igual urgencia, el más reciente)', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      final rows = [mk('a', 'P3', 1000), mk('p3old', 'P3', 2000), mk('p3new', 'P3', 3000), mk('p1', 'P1', 2500), mk('p2', 'P2', 2600)];
      a.observe(rows);
      expect(ids(a.news(rows)), ['p1', 'p2', 'p3new', 'p3old']);
    });
  });

  group('verlas', () {
    test('al reconocerlas desaparecen, y lo que llegue después vuelve a avisar', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      final r = [mk('a', 'P3', 1000), mk('b', 'P1', 2000)];
      a.observe(r);
      expect(a.news(r), isNotEmpty);
      a.acknowledge(r);
      expect(a.news(r), isEmpty);
      final later = [...r, mk('c', 'P2', 3000)];
      a.observe(later);
      expect(ids(a.news(later)), ['c']);
    });

    test('al cambiar de vista (reset) la lectura siguiente no avisa de nada, aunque traiga cosas más nuevas', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      a.reset();
      final all = [mk('a', 'P3', 1000), mk('z', 'P1', 9000)];
      a.observe(all);
      expect(a.news(all), isEmpty);
    });

    test('un nodo anterior que no manda la hora nunca produce novedades (y no rompe)', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', null)]);
      final r = [mk('a', 'P3', null), mk('b', 'P1', null)];
      a.observe(r);
      expect(a.news(r), isEmpty);
    });
  });

  group('resumen', () {
    test('cuenta cuántas son y cuántas P1', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      final r = [mk('a', 'P3', 1000), mk('b', 'P1', 2000), mk('c', 'P1', 2100), mk('d', 'P3', 2200)];
      a.observe(r);
      final s = a.summary(r);
      expect((s.count, s.p1), (3, 2));
      expect(s.label, '3 novedades (2 P1)');
    });

    test('en singular y sin P1', () {
      final a = Arrivals();
      a.observe([mk('a', 'P3', 1000)]);
      final r = [mk('a', 'P3', 1000), mk('d', 'P3', 2200)];
      a.observe(r);
      expect(a.summary(r).label, '1 novedad');
      expect(a.summary([mk('a', 'P3', 1000)]).count, 0);
    });
  });
}
