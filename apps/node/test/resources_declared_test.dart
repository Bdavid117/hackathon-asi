import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'log_support.dart';
import 'support.dart';

Map<String, Object?> decl([Map<String, Object?> over = const {}]) => {
  'id': 'AMB-01',
  'kind': 'ambulancia',
  'label': 'Ambulancia 1',
  'lat': 5.0710,
  'lon': -75.5140,
  'available': false,
  'who': 'Ana Gómez',
  ...over,
};

void main() {
  group('parseResourceDeclaration: validación ESTRICTA', () {
    test('una declaración mínima es válida', () {
      final d = parseResourceDeclaration(decl());
      expect(d.resource.id, 'AMB-01');
      expect(d.resource.available, isFalse);
      expect(d.who, 'Ana Gómez');
      expect(d.supersedes, isEmpty);
    });

    test('puede nombrar las declaraciones que reemplaza', () {
      expect(parseResourceDeclaration(decl({'supersedes': ['a:1', 'b:2']})).supersedes, ['a:1', 'b:2']);
    });

    test('un campo desconocido, o que no es un objeto, se rechaza', () {
      expect(() => parseResourceDeclaration(decl({'extra': 1})), throwsFormatException);
      expect(() => parseResourceDeclaration('x'), throwsFormatException);
      expect(() => parseResourceDeclaration(null), throwsFormatException);
    });

    test('los mismos rigores que el archivo de recursos: id, tipo, etiqueta, rango y booleano', () {
      for (final bad in [
        {'id': 'con espacio'},
        {'id': ''},
        {'kind': 'dron_de_ataque'},
        {'label': ''},
        {'label': 'x' * 81},
        {'lat': 91},
        {'lon': -181},
        {'lat': '5.0'},
        {'available': 'sí'},
        {'available': null},
      ]) {
        expect(() => parseResourceDeclaration(decl(bad)), throwsFormatException, reason: '$bad');
      }
    });

    test('quién declara es obligatorio, acotado y sin saltos de línea', () {
      for (final bad in [null, '', '   ', 'x' * 81, 'Ana\nGómez']) {
        expect(() => parseResourceDeclaration(decl({'who': bad})), throwsFormatException, reason: '$bad');
      }
    });

    test('supersedes: una lista de a lo sumo 8 textos cortos', () {
      for (final bad in ['a:1', [1], [''], List.filled(9, 'a:1'), ['x' * 200]]) {
        expect(() => parseResourceDeclaration(decl({'supersedes': bad})), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('GET/POST /api/resources', () {
    late EventLog log;
    late QueueService queue;
    late Handler handler;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      queue = QueueService(log, resources: testResources());
      handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, queue: queue);
    });
    tearDown(() => log.close());

    Future<Response> get() => Future.sync(() => handler(Request('GET', Uri.parse('http://localhost/api/resources'))));
    Future<Response> post(Object? body, {String? contentType = 'application/json'}) => Future.sync(
      () => handler(Request('POST', Uri.parse('http://localhost/api/resources'), body: body is String || body is Uint8List ? body : jsonEncode(body), headers: {'content-type': ?contentType})),
    );
    Future<List<Map<String, Object?>>> list() async => ((jsonDecode(await (await get()).readAsString()) as Map)['resources']! as List).cast<Map<String, Object?>>();
    Map<String, Object?> unit(List<Map<String, Object?>> l, String id) => l.firstWhere((u) => u['id'] == id);

    test('sin declaraciones lista los recursos de arranque, sin conflicto', () async {
      final l = await list();
      expect(l.map((u) => u['id']), ['AMB-01', 'BOM-01', 'RES-01', 'TRA-01']);
      expect(l.every((u) => u['conflict'] == false && (u['declarationIds']! as List).isEmpty), isTrue);
    });

    test('una declaración válida se guarda como evento y cambia lo que se lista, con quién la hizo', () async {
      final r = await post(decl());
      expect(r.statusCode, 200);
      final id = (jsonDecode(await r.readAsString()) as Map)['id'] as String;
      expect(log.eventById(id)!.type, 'resource.declared');
      final amb = unit(await list(), 'AMB-01');
      expect(amb['available'], isFalse);
      expect(amb['declaredBy'], 'Ana Gómez');
      expect(amb['declarationIds'], [id]);
    });

    test('una unidad nueva aparece', () async {
      await post(decl({'id': 'AMB-09', 'label': 'Nueva'}));
      expect(unit(await list(), 'AMB-09')['label'], 'Nueva');
    });

    test('sólo JSON: otro tipo de contenido es 415, y no se escribe nada', () async {
      expect((await post(jsonEncode(decl()), contentType: 'text/plain')).statusCode, 415);
      expect((await post(jsonEncode(decl()), contentType: null)).statusCode, 415);
      expect(log.allOfType('resource.declared'), isEmpty);
    });

    test('un cuerpo enorme es 413 y no se escribe nada', () async {
      expect((await post('{"x":"${'a' * 20000}"}')).statusCode, 413);
      expect(log.allOfType('resource.declared'), isEmpty);
    });

    test('el tope vale también cuando el cuerpo llega por partes y SIN longitud declarada', () async {
      final chunks = Stream<List<int>>.fromIterable([for (var i = 0; i < 6; i++) utf8.encode('{"x":"${'a' * 1000}"}'.substring(0, 1000))]);
      final r = await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/api/resources'), body: chunks, headers: {'content-type': 'application/json'})));
      expect(r.statusCode, 413);
      expect(log.allOfType('resource.declared'), isEmpty);
    });

    test('un campo mal es 400 con el motivo, y no se escribe nada', () async {
      final r = await post(decl({'lat': 200}));
      expect(r.statusCode, 400);
      expect(await r.readAsString(), contains('lat'));
      expect((await post('no es json')).statusCode, 400);
      expect(log.allOfType('resource.declared'), isEmpty);
    });

    test('reemplazar una declaración que no existe, de OTRA unidad o que no es una declaración: 400', () async {
      final first = jsonDecode(await (await post(decl({'id': 'AMB-01'}))).readAsString()) as Map;
      // una aprobación cuyo cuerpo lleva el MISMO id de unidad: sólo el TIPO la delata
      final approvalId = log.append('approval.granted', {'who': 'x', 'resource': {'id': 'AMB-01'}}, reportKey: 'k').id;
      expect((await post(decl({'supersedes': ['no-existe:1']}))).statusCode, 400);
      expect((await post(decl({'id': 'BOM-01', 'kind': 'bomberos', 'supersedes': [first['id']]}))).statusCode, 400, reason: 'es de AMB-01, no de BOM-01');
      expect((await post(decl({'supersedes': [approvalId]}))).statusCode, 400, reason: 'es una aprobación');
      expect((await post(decl({'supersedes': [first['id']]}))).statusCode, 200);
    });

    test('reemplazar de verdad RESUELVE: queda sólo la nueva, sin conflicto, aunque dijera otra cosa', () async {
      final first = (jsonDecode(await (await post(decl({'available': false}))).readAsString()) as Map)['id'] as String;
      final second = (jsonDecode(await (await post(decl({'available': true, 'label': 'Vuelve', 'supersedes': [first]}))).readAsString()) as Map)['id'] as String;
      final amb = unit(await list(), 'AMB-01');
      expect(amb['declarationIds'], [second]);
      expect(amb['conflict'], isFalse);
      expect(amb['available'], isTrue);
      expect(amb['label'], 'Vuelve');
    });

    test('la proyección se recalcula al declarar (la caché sabe de este tipo de evento)', () async {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada');
      final before = await queue.read();
      await post(decl());
      final after = await queue.read();
      expect(after.version, greaterThan(before.version));
    });
  });

  group('lo que declarar cambia en las recomendaciones', () {
    late EventLog log;
    late QueueService queue;
    late Handler handler;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      queue = QueueService(log, resources: testResources());
      handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, queue: queue);
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido, text: 'hay gente atrapada');
    });
    tearDown(() => log.close());

    Future<Response> post(String path, Object body) => Future.sync(() => handler(Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body), headers: {'content-type': 'application/json'})));
    Future<Map<String, Object?>> incident() async {
      final r = await queue.read();
      return (jsonDecode(r.incidentsPage(view: 'all'))['items']! as List).cast<Map>().single.cast<String, Object?>();
    }

    test('antes de declarar, la ambulancia disponible forma parte de la propuesta', () async {
      final rec = ((await incident())['recommendation']! as Map).cast<String, Object?>();
      expect(rec['state'], 'propuesta');
      expect(rec['resourceIds'], contains('AMB-01'));
    });

    test('al declararla NO disponible, la propuesta deja de nombrarla (y no sale ninguna otra ambulancia inventada)', () async {
      await post('/api/resources', decl());
      final i = await incident();
      expect(((i['recommendation']! as Map)['resourceIds']! as List), isNot(contains('AMB-01')));
      expect(((i['recommendation']! as Map)['resourceIds']! as List).where((id) => (id as String).startsWith('AMB')), isEmpty);
    });

    test('SIN recursos disponibles el P1 sigue siendo P1 y la recomendación sigue ahí: nada desaparece ni lanza', () async {
      final before = await incident();
      for (final u in testResources()) {
        await post('/api/resources', decl({'id': u.id, 'kind': u.kind.name, 'label': u.label, 'lat': u.lat, 'lon': u.lon}));
      }
      final after = await incident();
      expect(after['urgency'], before['urgency']);
      expect((after['recommendation']! as Map)['state'], isIn(['propuesta', 'informacion_requerida']));
      expect(((after['recommendation']! as Map)['resourceIds']! as List), isEmpty);
    });

    test('una aprobación vigente CADUCA si cambia la unidad propuesta (la persona aprobó con ESA ambulancia)', () async {
      final rec = ((await incident())['recommendation']! as Map).cast<String, Object?>();
      final id = (await incident())['id']! as String;
      final members = ((await incident())['members']! as List).cast<String>();
      final ok = await post('/api/approval', {'recommendationId': rec['id'], 'incidentId': id, 'members': members, 'decision': 'granted', 'note': '', 'who': 'Ana Gómez'});
      expect(ok.statusCode, 200);
      expect(((await incident())['approval']! as Map)['status'], 'aprobada');
      await post('/api/resources', decl());
      final after = await incident();
      expect(((after['approval']! as Map)['status']), 'caduca', reason: 'ya no es la misma recomendación');
      expect(IncidentIndex.isPending(after), isTrue, reason: 'y vuelve a esperar a una persona');
    });
  });

  group('réplica entre nodos: sin reloj y en cualquier orden', () {
    EventLog node(String id) => EventLog.open(':memory:', nodeId: id);

    List<Map<String, Object?>> merged(EventLog log) => [for (final e in mergeResources(testResources(), readResourceDeclarations(log.allOfType('resource.declared')))) e.toJson()];

    test('dos nodos aislados declaran cosas distintas sobre la misma unidad: al juntarse hay CONFLICTO, la unidad queda no disponible y ambos nodos coinciden', () {
      final a = node('A'), b = node('B');
      final ea = a.append('resource.declared', {'resource': decl({'available': true, 'label': 'Desde A'}), 'declared_by': 'Ana'}, reportKey: 'res-AMB-01');
      final eb = b.append('resource.declared', {'resource': decl({'available': false, 'label': 'Desde B'}), 'declared_by': 'Luis'}, reportKey: 'res-AMB-01');
      a.appendReplicated(eb);
      b.appendReplicated(ea);
      expect(jsonEncode(merged(a)), jsonEncode(merged(b)), reason: 'misma proyección en los dos');
      final amb = merged(a).firstWhere((u) => u['id'] == 'AMB-01');
      expect(amb['conflict'], isTrue);
      expect(amb['available'], isFalse);
      a.close();
      b.close();
    });

    test('el orden en que se replican los eventos no cambia el resultado', () {
      final src = node('S');
      final evs = [
        src.append('resource.declared', {'resource': decl({'available': false}), 'declared_by': 'Ana'}, reportKey: 'res-AMB-01'),
        src.append('resource.declared', {'resource': decl({'id': 'BOM-01', 'kind': 'bomberos', 'label': 'Bomberos 1', 'available': false}), 'declared_by': 'Ana'}, reportKey: 'res-BOM-01'),
        src.append('resource.declared', {'resource': decl({'id': 'NUE-01', 'kind': 'rescate', 'label': 'Nueva'}), 'declared_by': 'Luis'}, reportKey: 'res-NUE-01'),
      ];
      final x = node('X'), y = node('Y');
      for (final e in evs) {
        x.appendReplicated(e);
      }
      for (final e in evs.reversed) {
        y.appendReplicated(e);
      }
      expect(jsonEncode(merged(x)), jsonEncode(merged(y)));
      for (final l in [src, x, y]) {
        l.close();
      }
    });

    test('sólo se leen los eventos del tipo «resource.declared», aunque otro lleve un cuerpo parecido', () {
      final l = node('A');
      final other = l.append('approval.granted', {'resource': decl({'available': false}), 'declared_by': 'x'}, reportKey: 'k');
      expect(readResourceDeclarations([other]), isEmpty);
      l.close();
    });

    test('un evento replicado MALFORMADO se ignora: no tumba al nodo ni a las demás unidades', () {
      final l = node('A');
      l.append('resource.declared', {'resource': {'id': 'AMB-01', 'kind': 'dron'}, 'declared_by': 'x'}, reportKey: 'res-AMB-01');
      l.append('resource.declared', {'resource': 'basura'}, reportKey: 'res-X');
      l.append('resource.declared', {}, reportKey: 'res-Y');
      l.append('resource.declared', {'resource': decl({'id': 'BOM-01', 'kind': 'bomberos', 'available': false}), 'declared_by': 'Ana'}, reportKey: 'res-BOM-01');
      final m = merged(l);
      expect(m.firstWhere((u) => u['id'] == 'AMB-01')['available'], isTrue, reason: 'la mal formada no cuenta: sigue la de arranque');
      expect(m.firstWhere((u) => u['id'] == 'BOM-01')['available'], isFalse);
      l.close();
    });
  });
}
