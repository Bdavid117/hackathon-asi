import 'dart:convert';
import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:test/test.dart';

Resource res(String id, {bool available = true, String label = 'Unidad', double lat = 5.07, double lon = -75.51, ResourceKind kind = ResourceKind.ambulancia}) =>
    Resource(id: id, kind: kind, label: label, lat: lat, lon: lon, available: available);

ResourceDeclaration decl(String eventId, Resource r, {List<String> supersedes = const [], String? by}) => ResourceDeclaration(eventId: eventId, resource: r, supersedes: supersedes, declaredBy: by);

String sig(List<EffectiveResource> l) => jsonEncode([for (final e in l) e.toJson()]);

void main() {
  final base = [res('AMB-01'), res('AMB-02', label: 'Dos'), res('BOM-01', kind: ResourceKind.bomberos)];

  group('sin declaraciones, lo de siempre', () {
    test('los recursos de arranque salen tal cual, sin conflicto y sin declaraciones', () {
      final m = mergeResources(base, const []);
      expect([for (final e in m) e.resource.id], ['AMB-01', 'AMB-02', 'BOM-01']);
      expect(m.every((e) => !e.conflict && e.declarationIds.isEmpty), isTrue);
    });
  });

  group('una declaración manda sobre el arranque', () {
    test('marcar una unidad como no disponible', () {
      final m = mergeResources(base, [decl('A:1', res('AMB-01', available: false), by: 'Ana')]);
      final e = m.firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.resource.available, isFalse);
      expect(e.declarationIds, ['A:1']);
      expect(e.declaredBy, 'Ana');
      expect(m.firstWhere((e) => e.resource.id == 'AMB-02').resource.available, isTrue, reason: 'las demás no se tocan');
    });

    test('una unidad nueva, que no estaba en el arranque, aparece', () {
      final m = mergeResources(base, [decl('A:1', res('RES-09', kind: ResourceKind.rescate, label: 'Rescate nuevo'))]);
      expect([for (final e in m) e.resource.id], ['AMB-01', 'AMB-02', 'BOM-01', 'RES-09']);
    });

    test('puede cambiar de sitio y de nombre', () {
      final m = mergeResources(base, [decl('A:1', res('AMB-01', lat: 5.5, lon: -75.0, label: 'Movida'))]);
      final e = m.firstWhere((e) => e.resource.id == 'AMB-01').resource;
      expect((e.lat, e.lon, e.label), (5.5, -75.0, 'Movida'));
    });
  });

  group('SIN RELOJ: cada declaración nombra la que reemplaza', () {
    test('la que reemplaza a otra gana, entre en el orden que entre', () {
      final d1 = decl('A:1', res('AMB-01', available: false));
      final d2 = decl('A:2', res('AMB-01', available: true), supersedes: ['A:1']);
      for (final order in [[d1, d2], [d2, d1]]) {
        final e = mergeResources(base, order).firstWhere((e) => e.resource.id == 'AMB-01');
        expect(e.resource.available, isTrue);
        expect(e.conflict, isFalse);
        expect(e.declarationIds, ['A:2']);
      }
    });

    test('dos declaraciones hechas A LA VEZ (ninguna reemplaza a la otra) que DISCREPAN: conflicto, y por seguridad no disponible', () {
      final a = decl('A:1', res('AMB-01', available: true, label: 'Desde A'));
      final b = decl('B:1', res('AMB-01', available: false, label: 'Desde B'));
      final e = mergeResources(base, [a, b]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isTrue);
      expect(e.resource.available, isFalse);
      expect(e.declarationIds, ['A:1', 'B:1']);
    });

    test('aunque las dos digan «disponible», si discrepan en otra cosa (el sitio) es un conflicto y queda no disponible', () {
      final e = mergeResources(base, [decl('A:1', res('AMB-01', lat: 5.0)), decl('B:1', res('AMB-01', lat: 5.9))]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isTrue);
      expect(e.resource.available, isFalse);
    });

    test('discrepar SÓLO en el nombre también es un conflicto (cualquier desacuerdo cuenta)', () {
      final e = mergeResources(base, [decl('A:1', res('AMB-01', label: 'Uno')), decl('B:1', res('AMB-01', label: 'Otro'))]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isTrue);
      expect(e.resource.available, isFalse);
    });

    test('dos declaraciones idénticas y simultáneas (un reintento, o dos personas que dicen lo mismo): NO es conflicto', () {
      final e = mergeResources(base, [decl('A:1', res('AMB-01', available: false)), decl('B:1', res('AMB-01', available: false))]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isFalse);
      expect(e.resource.available, isFalse);
    });

    test('una declaración que se nombra a sí misma no se borra: el conflicto con otra sigue', () {
      final a = decl('A:1', res('AMB-01', label: 'A'), supersedes: ['A:1']);
      final b = decl('B:1', res('AMB-01', label: 'B'));
      final e = mergeResources(base, [a, b]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isTrue);
      expect(e.declarationIds, ['A:1', 'B:1']);
    });

    test('una tercera declaración que reemplaza a las dos en conflicto lo resuelve', () {
      final a = decl('A:1', res('AMB-01', label: 'A')), b = decl('B:1', res('AMB-01', available: false, label: 'B'));
      final fix = decl('A:2', res('AMB-01', label: 'Resuelta'), supersedes: ['A:1', 'B:1']);
      final e = mergeResources(base, [a, b, fix]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isFalse);
      expect(e.resource.label, 'Resuelta');
      expect(e.declarationIds, ['A:2']);
    });

    test('si sólo reemplaza a UNA de las dos, el conflicto sigue entre la que quedó y la nueva', () {
      final a = decl('A:1', res('AMB-01', label: 'A')), b = decl('B:1', res('AMB-01', available: false, label: 'B'));
      final fix = decl('A:2', res('AMB-01', label: 'Nueva'), supersedes: ['A:1']);
      final e = mergeResources(base, [a, b, fix]).firstWhere((e) => e.resource.id == 'AMB-01');
      expect(e.conflict, isTrue);
      expect(e.declarationIds, ['A:2', 'B:1']);
    });

    test('reemplazar algo que no existe, o de OTRA unidad, no afecta a nadie', () {
      final other = decl('A:1', res('AMB-02', available: false));
      final stray = decl('A:2', res('AMB-01', available: false), supersedes: ['A:1', 'no-existe']);
      final m = mergeResources(base, [other, stray]);
      expect(m.firstWhere((e) => e.resource.id == 'AMB-02').resource.available, isFalse, reason: 'AMB-02 sigue como la declaró su dueña');
      expect(m.firstWhere((e) => e.resource.id == 'AMB-01').resource.available, isFalse);
    });
  });

  group('propiedades', () {
    final all = [
      decl('A:1', res('AMB-01', available: false)),
      decl('A:2', res('AMB-01', available: true, label: 'Vuelve'), supersedes: ['A:1']),
      decl('B:1', res('AMB-01', available: false, label: 'Otra'), by: 'Luis'),
      decl('A:3', res('AMB-02', available: false)),
      decl('B:2', res('BOM-01', lat: 5.2), supersedes: []),
      decl('C:1', res('NUE-01', kind: ResourceKind.transito)),
    ];

    test('el resultado NO depende del orden en que llegan los eventos (réplica entre nodos)', () {
      final expected = sig(mergeResources(base, all));
      final rnd = Random(9);
      for (var i = 0; i < 40; i++) {
        expect(sig(mergeResources([...base]..shuffle(rnd), [...all]..shuffle(rnd))), expected);
      }
    });

    test('siempre sale ordenado por identificador', () {
      final ids = [for (final e in mergeResources(base, all)) e.resource.id];
      expect(ids, [...ids]..sort());
    });

    test('es pura: no modifica lo que recibe', () {
      final b = [...base], a = [...all];
      mergeResources(b, a);
      expect([for (final r in b) r.id], [for (final r in base) r.id]);
      expect(a.length, all.length);
    });

    test('un conflicto NUNCA deja una unidad disponible', () {
      final rnd = Random(5);
      for (var i = 0; i < 50; i++) {
        final a = decl('A:1', res('AMB-01', available: rnd.nextBool(), lat: 5.0 + rnd.nextInt(2)));
        final b = decl('B:1', res('AMB-01', available: rnd.nextBool(), lat: 5.0 + rnd.nextInt(2)));
        final e = mergeResources(base, [a, b]).firstWhere((e) => e.resource.id == 'AMB-01');
        if (e.conflict) expect(e.resource.available, isFalse);
      }
    });

    test('toJson: forma estable', () {
      final e = mergeResources(base, [decl('A:1', res('AMB-01', available: false), by: 'Ana')]).first;
      expect(e.toJson(), {'id': 'AMB-01', 'kind': 'ambulancia', 'label': 'Unidad', 'lat': 5.07, 'lon': -75.51, 'available': false, 'conflict': false, 'declarationIds': ['A:1'], 'declaredBy': 'Ana'});
    });
  });
}
