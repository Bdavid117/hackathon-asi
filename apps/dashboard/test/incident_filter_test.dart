import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/incident_filter.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

IncidentRow mk(String id, String urgency, {List<String> signals = const ['atrapado'], bool located = true, int sources = 1, int fromDispatch = 0, int size = 1, bool high = false, bool review = false, String rec = 'informacion_requerida', String approval = 'pendiente'}) {
  final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
  return IncidentRow.fromJson({
    ...base,
    'id': id,
    'urgency': urgency,
    'signals': signals,
    'lat': located ? 5.07 : null,
    'lon': located ? -75.51 : null,
    'sources': sources,
    'size': size,
    'fromDispatch': fromDispatch,
    'highUncertainty': high,
    'needsReview': review,
    'bareSos': false,
    'recommendation': {'state': rec, 'id': 'r-$id', 'actions': ['enviar_rescate']},
    'approval': {'status': approval, 'discrepancy': false, 'decisions': 0},
  });
}

List<String> ids(Iterable<IncidentRow> rows) => [for (final r in rows) r.id];

void main() {
  final rows = [
    mk('a', 'P1', signals: const ['atrapado', 'herido']),
    mk('b', 'P2', signals: const ['incendio'], located: false, high: true),
    mk('c', 'P3', signals: const ['via_bloqueada'], sources: 2, size: 2),
    mk('d', 'P3', signals: const [], review: true, fromDispatch: 1),
    mk('e', 'P1', signals: const ['dificultad_respiratoria'], rec: 'propuesta', approval: 'pendiente'),
  ];

  group('sin filtro no se esconde nada', () {
    test('todo se ve, en el mismo orden, y no hay filtro activo', () {
      const f = IncidentFilter();
      final r = f.apply(rows);
      expect(f.isActive, isFalse);
      expect(ids(r.shown), ['a', 'b', 'c', 'd', 'e']);
      expect(r.hidden, isEmpty);
    });

    test('un texto en blanco tampoco cuenta como filtro', () {
      expect(const IncidentFilter(query: '   ').isActive, isFalse);
      expect(ids(const IncidentFilter(query: '   ').apply(rows).shown), hasLength(5));
    });
  });

  group('las marcas filtran por lo que de verdad significan', () {
    List<String> by(FilterFlag f) => ids(IncidentFilter(flags: {f}).apply(rows).shown);

    test('sin ubicación', () => expect(by(FilterFlag.noLocation), ['b']));
    test('fuente única', () => expect(by(FilterFlag.singleSource), ['a', 'b', 'd', 'e']));
    test('de segunda mano (informes de un despachador)', () => expect(by(FilterFlag.secondHand), ['d']));
    test('incertidumbre alta', () => expect(by(FilterFlag.highUncertainty), ['b']));
    test('a revisar', () => expect(by(FilterFlag.needsReview), ['d']));
    test('pendientes de decisión (la misma definición que el nodo)', () => expect(by(FilterFlag.pending), ['e']));

    test('pendientes: una propuesta ya aprobada o rechazada NO cuenta; una caducada sí', () {
      final r = [mk('x', 'P1', rec: 'propuesta', approval: 'aprobada'), mk('y', 'P1', rec: 'propuesta', approval: 'caduca'), mk('z', 'P2', rec: 'propuesta', approval: 'denegada')];
      expect(ids(const IncidentFilter(flags: {FilterFlag.pending}).apply(r).shown), ['y']);
    });

    test('varias marcas se SUMAN (cada una acota): sin ubicación Y con incertidumbre alta', () {
      expect(ids(const IncidentFilter(flags: {FilterFlag.noLocation, FilterFlag.highUncertainty}).apply(rows).shown), ['b']);
      expect(ids(const IncidentFilter(flags: {FilterFlag.noLocation, FilterFlag.needsReview}).apply(rows).shown), isEmpty);
    });
  });

  group('la búsqueda', () {
    List<String> q(String text) => ids(IncidentFilter(query: text).apply(rows).shown);

    test('encuentra por lo que dice la tarjeta, sin importar mayúsculas ni tildes', () {
      expect(q('ATRAPADO'), ['a']);
      expect(q('via'), ['c'], reason: '«Vía bloqueada» se encuentra con «via»');
      expect(q('vía'), ['c']);
      expect(q('respirar'), ['e'], reason: 'en la tarjeta se lee «Dificultad para respirar»');
      expect(q('dificultad_respiratoria'), isEmpty, reason: 'el código interno no es lo que la persona ve');
    });

    test('varias palabras: todas tienen que estar', () {
      expect(q('atrapado herido'), ['a']);
      expect(q('atrapado incendio'), isEmpty);
    });

    test('también por el identificador (lo que la persona copia de otra pantalla)', () {
      expect(q('b'), contains('b'));
    });

    test('lo que no existe no encuentra nada, y no rompe', () {
      expect(q('zzzz'), isEmpty);
    });

    test('se combina con las marcas', () {
      expect(ids(const IncidentFilter(query: 'atrapado', flags: {FilterFlag.singleSource}).apply(rows).shown), ['a']);
      expect(ids(const IncidentFilter(query: 'atrapado', flags: {FilterFlag.noLocation}).apply(rows).shown), isEmpty);
    });
  });

  group('un filtro nunca esconde nada sin decirlo', () {
    test('cuenta lo oculto y cuántos de eso son P1 y P2', () {
      final r = const IncidentFilter(flags: {FilterFlag.noLocation}).apply(rows);
      expect(ids(r.shown), ['b']);
      expect(ids(r.hidden), ['a', 'c', 'd', 'e']);
      expect(r.hiddenByUrgency, {'P1': 2, 'P2': 0, 'P3': 2, 'P4': 0});
    });

    test('el resumen en español dice cuántos se ocultan y cuántos son P1', () {
      final r = const IncidentFilter(flags: {FilterFlag.noLocation}).apply(rows);
      expect(r.hiddenSummary, '4 ocultos por el filtro (2 son P1)');
    });

    test('con un solo oculto y un solo P1 el texto va en singular', () {
      final r = const IncidentFilter(query: 'atrapado').apply([mk('a', 'P1'), mk('x', 'P3', signals: const ['incendio'])]);
      expect(r.hiddenSummary, '1 oculto por el filtro');
      final r2 = const IncidentFilter(query: 'incendio').apply([mk('a', 'P1'), mk('x', 'P3', signals: const ['incendio'])]);
      expect(r2.hiddenSummary, '1 oculto por el filtro (1 es P1)');
    });

    test('sin nada oculto no hay resumen', () {
      expect(const IncidentFilter(flags: {FilterFlag.singleSource}).apply([mk('a', 'P1')]).hiddenSummary, isNull);
    });
  });

  group('describe: el filtro activo siempre se puede leer', () {
    test('nombra el texto y las marcas', () {
      expect(const IncidentFilter(query: 'atrapado', flags: {FilterFlag.noLocation, FilterFlag.pending}).describe(), '«atrapado» · Sin ubicación · Pendientes de decisión');
    });

    test('sin filtro no dice nada', () {
      expect(const IncidentFilter().describe(), '');
    });

    test('cambiar una marca o el texto devuelve otro filtro, sin modificar el anterior', () {
      const f = IncidentFilter(query: 'a');
      final g = f.withFlag(FilterFlag.pending, true).withQuery('b');
      expect(f.flags, isEmpty);
      expect(f.query, 'a');
      expect(g.flags, {FilterFlag.pending});
      expect(g.query, 'b');
      expect(g.withFlag(FilterFlag.pending, false).flags, isEmpty);
      expect(g.cleared().isActive, isFalse);
    });
  });
}
