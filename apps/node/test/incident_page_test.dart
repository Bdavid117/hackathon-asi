import 'dart:convert';
import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

/// Un incidente sintético con sólo lo que la vista corta necesita.
IncidentData fake(
  String id,
  Urgency u, {
  bool bare = false,
  bool highUncertainty = false,
  bool needsReview = false,
  int lastAt = 1000,
  int size = 1,
}) => IncidentData(
  id: id,
  urgency: u,
  firstAt: lastAt,
  summary: {
    'id': id,
    'urgency': u.name.toUpperCase(),
    'size': size,
    'bareSos': bare,
    'highUncertainty': highUncertainty,
    'needsReview': needsReview,
    'firstAt': lastAt,
    'lastAt': lastAt,
  },
  detail: {'id': id},
);

Map<String, Object?> page(IncidentIndex ix, {String view = 'short', String? urgency, bool? bare, int offset = 0, int limit = 200}) =>
    (jsonDecode(ix.page(view: view, urgency: urgency, bare: bare, offset: offset, limit: limit)) as Map).cast<String, Object?>();

List<String> ids(Map<String, Object?> p) => [for (final i in p['items']! as List) (i as Map)['id']! as String];

void main() {
  group('contadores honestos', () {
    final data = [
      fake('p1a', Urgency.p1, lastAt: 10),
      fake('p1b', Urgency.p1, lastAt: 20, highUncertainty: true),
      fake('p2a', Urgency.p2, lastAt: 30, highUncertainty: true, needsReview: true),
      fake('p3a', Urgency.p3, lastAt: 40, size: 3),
      fake('p4a', Urgency.p4, lastAt: 50),
      fake('b1', Urgency.p3, bare: true, lastAt: 60),
      fake('b2', Urgency.p3, bare: true, lastAt: 70),
    ];
    final c = (page(IncidentIndex.build(data))['counters']! as Map).cast<String, Object?>();

    test('total de incidentes y de reportes', () {
      expect(c['incidents'], 7);
      expect(c['reports'], 1 + 1 + 1 + 3 + 1 + 1 + 1);
    });

    test('por urgencia (los SOS sin detalle cuentan en P3, que es lo que son)', () {
      expect(c['byUrgency'], {'P1': 2, 'P2': 1, 'P3': 3, 'P4': 1});
    });

    test('SOS sin detalle, incertidumbre alta y a revisar', () {
      expect(c['bareSos'], 2);
      expect(c['highUncertainty'], 2);
      expect(c['needsReview'], 1);
    });

    test('con pocos incidentes todo cabe en la vista corta: nada «en seguimiento fuera»', () {
      expect(c['inShortView'], 5);
      expect(c['followUp'], 0);
    });
  });

  group('vista corta (decisión 11)', () {
    test('todos los P1 y P2, los 20 P3/P4 informativos más recientes y UNA fila agregada de SOS sin detalle', () {
      final data = [
        for (var i = 0; i < 30; i++) fake('p1-$i', Urgency.p1, lastAt: i),
        for (var i = 0; i < 30; i++) fake('p2-$i', Urgency.p2, lastAt: i),
        for (var i = 0; i < 50; i++) fake('p3-${i.toString().padLeft(2, '0')}', i.isEven ? Urgency.p3 : Urgency.p4, lastAt: 100 + i),
        for (var i = 0; i < 400; i++) fake('b-${i.toString().padLeft(3, '0')}', Urgency.p3, bare: true, lastAt: 500 + i),
      ];
      final p = page(IncidentIndex.build(data));
      final got = ids(p);
      expect(got.where((x) => x.startsWith('p1-')), hasLength(30), reason: 'ningún P1 fuera');
      expect(got.where((x) => x.startsWith('p2-')), hasLength(30));
      final informative = got.where((x) => x.startsWith('p3-')).toList()..sort();
      expect(informative, [for (var i = 30; i < 50; i++) 'p3-$i'], reason: 'los 20 más recientes');
      expect(got.where((x) => x.startsWith('b-')), isEmpty, reason: 'los SOS sin detalle no inundan la lista');
      final agg = (p['bareSos']! as Map).cast<String, Object?>();
      expect(agg['count'], 400);
      expect(agg['newestAt'], 899);
      expect(agg['oldestAt'], 500);
      expect(agg['sampleIds'], hasLength(5));
      final c = (p['counters']! as Map).cast<String, Object?>();
      expect(c['inShortView'], 30 + 30 + 20);
      expect(c['followUp'], 30, reason: 'P3/P4 informativos que quedaron fuera de la vista corta');
    });

    test('la vista corta IGNORA offset y limit: pedir una página no puede dejar un P1 fuera', () {
      final data = [for (var i = 0; i < 30; i++) fake('p1-$i', Urgency.p1, lastAt: i)];
      final ix = IncidentIndex.build(data);
      expect(ids(page(ix, offset: 7, limit: 1)), hasLength(30));
    });

    test('los filtros no valen con la vista corta (se rechazan, no se ignoran en silencio)', () {
      final ix = IncidentIndex.build([fake('a', Urgency.p1)]);
      expect(() => ix.page(urgency: 'P1'), throwsArgumentError);
      expect(() => ix.page(bare: true), throwsArgumentError);
    });

    test('la lista corta mantiene el orden: más grave primero, luego el más antiguo', () {
      final data = [fake('a', Urgency.p2, lastAt: 5), fake('b', Urgency.p1, lastAt: 9), fake('c', Urgency.p1, lastAt: 3), fake('d', Urgency.p3, lastAt: 1)];
      expect(ids(page(IncidentIndex.build(data))), ['c', 'b', 'a', 'd']);
    });

    test('sin SOS sin detalle, bareSos es null (no hay fila agregada que mostrar)', () {
      expect(page(IncidentIndex.build([fake('a', Urgency.p1)]))['bareSos'], isNull);
    });

    test('sin incidentes: todo vacío y sin fallar', () {
      final p = page(IncidentIndex.build(const []));
      expect(p['items'], isEmpty);
      expect(p['bareSos'], isNull);
      expect((p['counters']! as Map)['incidents'], 0);
    });

    test('PROPIEDAD: ningún P1 ni P2 queda fuera de la vista corta, con cualquier mezcla', () {
      final rng = Random(14);
      for (var round = 0; round < 40; round++) {
        final data = [
          for (var i = 0; i < 300; i++)
            fake('i${i.toString().padLeft(3, '0')}', Urgency.values[rng.nextInt(4)], bare: rng.nextInt(3) == 0, lastAt: rng.nextInt(1000)),
        ];
        // un SOS sin detalle es P3 por definición
        final fixed = [for (final d in data) d.summary['bareSos'] == true ? fake(d.id, Urgency.p3, bare: true, lastAt: d.firstAt) : d];
        final shown = ids(page(IncidentIndex.build(fixed))).toSet();
        for (final d in fixed) {
          if (d.urgency == Urgency.p1 || d.urgency == Urgency.p2) expect(shown, contains(d.id), reason: 'ronda $round: ${d.id}');
        }
      }
    });

    test('el desempate de «más recientes» es determinista (mismo lastAt: por id)', () {
      final data = [for (var i = 0; i < 25; i++) fake('x${i.toString().padLeft(2, '0')}', Urgency.p3, lastAt: 100)];
      final a = ids(page(IncidentIndex.build(data)));
      final b = ids(page(IncidentIndex.build(data.reversed.toList())));
      expect(a, b);
      expect(a, hasLength(20));
    });
  });

  group('vista completa, con filtros y páginas', () {
    final data = [
      for (var i = 0; i < 12; i++) fake('r${i.toString().padLeft(2, '0')}', Urgency.values[i % 4], lastAt: i),
      fake('b0', Urgency.p3, bare: true, lastAt: 50),
      fake('b1', Urgency.p3, bare: true, lastAt: 51),
    ];
    final ix = IncidentIndex.build(data);

    test('view=all trae todos, incluidos los SOS sin detalle, con el total', () {
      final p = page(ix, view: 'all');
      expect(ids(p), hasLength(14));
      expect(p['total'], 14);
      expect(p['bareSos'], isNull);
    });

    test('páginas: offset y limit recorren la lista completa en el mismo orden sin repetir', () {
      final all = ids(page(ix, view: 'all'));
      final pieces = [for (var o = 0; o < 14; o += 5) ...ids(page(ix, view: 'all', offset: o, limit: 5))];
      expect(pieces, all);
    });

    test('filtro por urgencia', () {
      final p = page(ix, view: 'all', urgency: 'P1');
      expect(ids(p), everyElement(startsWith('r')));
      expect(ids(p), hasLength(3));
      expect(p['total'], 3, reason: 'el total es el de los que cumplen el filtro');
    });

    test('bare=true trae sólo los SOS sin detalle («ver» de la fila agregada); bare=false los excluye', () {
      expect(ids(page(ix, view: 'all', bare: true)), ['b0', 'b1']);
      expect(ids(page(ix, view: 'all', bare: false)), hasLength(12));
    });

    test('un offset más allá del final devuelve una lista vacía, no un error', () {
      expect(ids(page(ix, view: 'all', offset: 999)), isEmpty);
    });

    test('limit se acota a 1000 y debe ser positivo', () {
      expect(() => ix.page(view: 'all', limit: 0), throwsArgumentError);
      expect(() => ix.page(view: 'all', limit: -3), throwsArgumentError);
      expect(() => ix.page(view: 'all', offset: -1), throwsArgumentError);
      expect(ids(page(ix, view: 'all', limit: 5000)), hasLength(14), reason: 'se acota, no falla');
    });

    test('el tope de 1 000 filas por página se aplica de verdad (con más de 1 000 incidentes)', () {
      final big = IncidentIndex.build([for (var i = 0; i < 1200; i++) fake('i${i.toString().padLeft(4, '0')}', Urgency.p3, lastAt: i)]);
      final p = page(big, view: 'all', limit: 5000);
      expect(ids(p), hasLength(1000));
      expect(p['limit'], 1000);
      expect(p['total'], 1200);
      expect(ids(page(big, view: 'all', offset: 1000, limit: 5000)), hasLength(200));
    });

    test('vista o urgencia desconocidas son un error de uso', () {
      expect(() => ix.page(view: 'todo'), throwsArgumentError);
      expect(() => ix.page(view: 'all', urgency: 'P9'), throwsArgumentError);
    });
  });

  group('tamaño y tiempo con 10 000 incidentes', () {
    test('la vista corta pesa poco y se arma deprisa aunque haya 10 000 incidentes', () {
      final rng = Random(5);
      final data = [
        for (var i = 0; i < 10000; i++)
          () {
            final bare = rng.nextInt(10) < 7;
            final u = bare ? Urgency.p3 : Urgency.values[rng.nextInt(4)];
            return fake('i${i.toString().padLeft(5, '0')}', u, bare: bare, lastAt: rng.nextInt(100000));
          }(),
      ];
      final ix = IncidentIndex.build(data);
      final sw = Stopwatch()..start();
      final body = ix.page();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200));
      final shortRows = ids((jsonDecode(body) as Map).cast<String, Object?>()).length;
      expect(shortRows, lessThan(2000), reason: 'P1+P2 (~25 % de los 3 000 informativos) + 20');
      expect(body.length, lessThan(shortRows * 400 + 4000), reason: 'el tamaño crece con lo mostrado, no con los 10 000');
    });
  });
}
