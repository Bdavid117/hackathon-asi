import 'dart:convert';
import 'dart:typed_data';

import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

ApprovalDecision d(
  String id, {
  String rec = 'a1b2c3d4e5f60718',
  String incident = 'aa-1',
  List<String> members = const ['aa-1'],
  bool granted = true,
  List<String> supersedes = const [],
  String who = 'coordinador',
  int at = 1000,
}) => ApprovalDecision(eventId: id, recommendationId: rec, incidentId: incident, members: members, granted: granted, note: '', who: who, atMs: at, supersedes: supersedes);

ApprovalState derive(List<ApprovalDecision> ds, {String? current = 'a1b2c3d4e5f60718', String incident = 'aa-1', Set<String> members = const {'aa-1'}}) =>
    deriveApproval(incidentId: incident, memberKeys: members, currentRecommendationId: current, approvals: ds);

void main() {
  group('deriveApproval: el estado se DERIVA al leer', () {
    test('sin decisiones: pendiente', () {
      final s = derive([]);
      expect(s.status, ApprovalStatus.pendiente);
      expect(s.discrepancy, isFalse);
      expect(s.current, isEmpty);
    });

    test('una aprobación de la versión vigente: aprobada', () {
      final s = derive([d('A:1')]);
      expect(s.status, ApprovalStatus.aprobada);
      expect(s.current.single.eventId, 'A:1');
    });

    test('un rechazo de la versión vigente: denegada', () {
      expect(derive([d('A:1', granted: false)]).status, ApprovalStatus.denegada);
    });

    test('aprobación y rechazo SIN sustituirse: manda el rechazo y se marca la discrepancia', () {
      final s = derive([d('A:1'), d('B:1', granted: false)]);
      expect(s.status, ApprovalStatus.denegada);
      expect(s.discrepancy, isTrue);
      expect(s.current.map((x) => x.eventId).toSet(), {'A:1', 'B:1'});
    });

    test('una decisión posterior que NOMBRA a la anterior la sustituye: sin discrepancia', () {
      final s = derive([d('A:1'), d('B:1', granted: false, supersedes: ['A:1'])]);
      expect(s.status, ApprovalStatus.denegada);
      expect(s.discrepancy, isFalse);
      expect(s.current.single.eventId, 'B:1');
      final s2 = derive([d('A:1', granted: false), d('B:1', supersedes: ['A:1'])]);
      expect(s2.status, ApprovalStatus.aprobada, reason: 'quien resuelve explícitamente puede aprobar tras un rechazo');
      expect(s2.discrepancy, isFalse);
    });

    test('el orden de los eventos NO sustituye por sí solo: sin nombrarlo, una decisión posterior no anula a la anterior', () {
      final s = derive([d('A:1', granted: false, at: 1000), d('B:1', at: 9999)]);
      expect(s.status, ApprovalStatus.denegada, reason: 'el reloj es una marca, no un orden entre nodos');
      expect(s.discrepancy, isTrue);
    });

    test('una aprobación de OTRA versión del incidente (otro id): caduca', () {
      final s = derive([d('A:1', rec: '0000000000000001')]);
      expect(s.status, ApprovalStatus.caduca);
      expect(s.stale.single.eventId, 'A:1');
      expect(s.current, isEmpty);
    });

    test('con una vigente y una caducada manda la vigente, y la caducada queda en el historial', () {
      final s = derive([d('A:1', rec: '0000000000000001'), d('B:1', granted: false)]);
      expect(s.status, ApprovalStatus.denegada);
      expect(s.stale.single.eventId, 'A:1');
    });

    test('una decisión de OTRO incidente (sin miembros en común) se ignora', () {
      final s = derive([d('A:1', incident: 'zz-9', members: ['zz-9'])]);
      expect(s.status, ApprovalStatus.pendiente);
      expect(s.stale, isEmpty);
    });

    test('si el incidente cambió de identificador por una fusión, los miembros enlazan la decisión vieja y caduca', () {
      final s = derive([d('A:1', incident: 'bb-5', members: ['bb-5', 'cc-1'], rec: '0000000000000002')], incident: 'aa-1', members: {'aa-1', 'bb-5'});
      expect(s.status, ApprovalStatus.caduca);
    });

    test('sin recomendación vigente (null) toda decisión previa es caducada', () {
      final s = derive([d('A:1')], current: null);
      expect(s.status, ApprovalStatus.caduca);
      expect(derive([], current: null).status, ApprovalStatus.pendiente);
    });

    test('«sustituye a» un evento que no es una decisión conocida se ignora, no rompe', () {
      expect(derive([d('A:1', supersedes: ['X:9'])]).status, ApprovalStatus.aprobada);
    });

    test('un ciclo de sustituciones no deja el estado en blanco: se usan todas las vigentes (y manda el rechazo)', () {
      final s = derive([d('A:1', supersedes: ['B:1']), d('B:1', granted: false, supersedes: ['A:1'])]);
      expect(s.status, ApprovalStatus.denegada);
    });

    test('el resultado no depende del orden de la lista', () {
      final ds = [d('A:1'), d('B:1', granted: false), d('C:1', rec: '0000000000000001'), d('D:1', supersedes: ['A:1'])];
      final a = derive(ds), b = derive(ds.reversed.toList());
      expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    });

    test('toJson: estado, discrepancia, vigentes y caducadas con su autor', () {
      final j = derive([d('A:1', who: 'Ana')]).toJson();
      expect(j['status'], 'aprobada');
      expect(j['discrepancy'], false);
      expect(((j['current']! as List).single as Map)['who'], 'Ana');
    });
  });

  group('readApprovals: lee los eventos del log con tolerancia', () {
    late EventLog log;
    setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
    tearDown(() => log.close());

    test('lee approval.granted y approval.denied, ignora otros tipos y cuerpos mal formados', () {
      log.append('approval.granted', {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'aa-1', 'members': ['aa-1'], 'note': 'ok', 'who': 'Ana'}, reportKey: 'aa-1');
      log.append('approval.denied', {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'aa-1', 'members': <String>[], 'note': '', 'who': 'Luis'}, reportKey: 'aa-1');
      log.append('approval.granted', {'basura': 1});
      log.append('approval.granted', {'recommendationId': 5, 'incidentId': 'aa-1', 'who': 'x'});
      log.append('report.received', {'x': 1});
      final ds = readApprovals(log.all());
      expect(ds, hasLength(2));
      expect(ds.first.granted, isTrue);
      expect(ds.first.who, 'Ana');
      expect(ds.last.granted, isFalse);
    });

    test('las sustituciones salen de los inputs del evento', () {
      final a = log.append('approval.granted', {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'aa-1', 'members': ['aa-1'], 'note': '', 'who': 'Ana'});
      log.append('approval.denied', {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'aa-1', 'members': ['aa-1'], 'note': '', 'who': 'Luis'}, inputs: [a.id]);
      expect(readApprovals(log.all()).last.supersedes, [a.id]);
    });
  });

  group('POST /api/approval: se registra SIEMPRE, sólo desde JSON, con validación estricta', () {
    late EventLog log;
    late Handler handler;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      handler = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
    });
    tearDown(() => log.close());

    Map<String, Object?> ok({String decision = 'granted'}) => {
      'recommendationId': 'a1b2c3d4e5f60718',
      'incidentId': 'aa-1',
      'members': ['aa-1', 'bb-1'],
      'decision': decision,
      'note': 'visto con el equipo',
      'who': 'Ana Gómez',
    };

    Future<Response> post(Object? body, {String? contentType = 'application/json', Map<String, String> headers = const {}}) => Future.sync(
      () => handler(Request('POST', Uri.parse('http://localhost/api/approval'), body: body is String || body is Uint8List ? body : jsonEncode(body), headers: {'content-type': ?contentType, ...headers})),
    );

    int approvals() => log.allOfType('approval.granted').length + log.allOfType('approval.denied').length;

    test('una decisión válida se guarda como evento con todo lo que la persona vio, y devuelve su id', () async {
      final r = await post(ok());
      expect(r.statusCode, 200);
      final id = (jsonDecode(await r.readAsString()) as Map)['id'] as String;
      final e = log.eventById(id)!;
      expect(e.type, 'approval.granted');
      expect(e.reportKey, 'aa-1');
      expect(e.body['recommendationId'], 'a1b2c3d4e5f60718');
      expect(e.body['who'], 'Ana Gómez');
      expect(e.body['note'], 'visto con el equipo');
      expect(e.body['members'], ['aa-1', 'bb-1']);
      expect(e.inputs, isEmpty);
    });

    test('«denied» se guarda como approval.denied', () async {
      final r = await post(ok(decision: 'denied'));
      expect(r.statusCode, 200);
      expect(log.allOfType('approval.denied'), hasLength(1));
      expect(log.allOfType('approval.granted'), isEmpty);
    });

    test('nunca hay 409: dos decisiones contradictorias de la misma versión se guardan ambas', () async {
      expect((await post(ok())).statusCode, 200);
      expect((await post(ok(decision: 'denied'))).statusCode, 200);
      expect(approvals(), 2);
    });

    test('una versión que el nodo ya no reconoce igual se guarda (se mostrará caducada)', () async {
      final j = ok()..['recommendationId'] = 'ffffffffffffffff';
      expect((await post(j)).statusCode, 200);
      expect(approvals(), 1);
    });

    test('«supersedes» nombra decisiones anteriores y viaja en los inputs del evento', () async {
      final first = jsonDecode(await (await post(ok())).readAsString())['id'] as String;
      final r = await post({...ok(decision: 'denied'), 'supersedes': [first]});
      expect(r.statusCode, 200);
      final id = (jsonDecode(await r.readAsString()) as Map)['id'] as String;
      expect(log.eventById(id)!.inputs, [first]);
    });

    test('«supersedes» con un evento desconocido, o que no es una decisión, se rechaza (400)', () async {
      final rec = log.append('report.received', {'x': 1});
      expect((await post({...ok(), 'supersedes': ['A:000999']})).statusCode, 400);
      expect((await post({...ok(), 'supersedes': [rec.id]})).statusCode, 400);
      expect((await post({...ok(), 'supersedes': List.generate(21, (i) => 'A:00000$i')})).statusCode, 400);
      expect(approvals(), 0);
    });

    test('sin «content-type: application/json» responde 415 y no escribe nada (protege de formularios de otra página)', () async {
      for (final ct in [null, 'text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', 'application/octet-stream']) {
        final r = await post(ok(), contentType: ct);
        expect(r.statusCode, 415, reason: '$ct');
      }
      expect(approvals(), 0);
    });

    test('acepta «application/json; charset=utf-8»', () async {
      expect((await post(ok(), contentType: 'application/json; charset=utf-8')).statusCode, 200);
    });

    test('cuerpos inválidos responden 400 y no escriben nada', () async {
      final bad = <String, Object?>{
        'no es JSON': 'esto no es json',
        'es un arreglo': '[]',
        'es null': 'null',
        'sin recommendationId': {...ok()}..remove('recommendationId'),
        'recommendationId mal formado': {...ok(), 'recommendationId': 'XYZ'},
        'recommendationId demasiado largo': {...ok(), 'recommendationId': 'a' * 64},
        'sin incidentId': {...ok()}..remove('incidentId'),
        'incidentId vacío': {...ok(), 'incidentId': ''},
        'decisión desconocida': {...ok(), 'decision': 'quizas'},
        'decisión en mayúsculas': {...ok(), 'decision': 'GRANTED'},
        'sin decisión': {...ok()}..remove('decision'),
        'quién vacío': {...ok(), 'who': '   '},
        'sin quién': {...ok()}..remove('who'),
        'quién demasiado largo': {...ok(), 'who': 'x' * 81},
        'quién con salto de línea': {...ok(), 'who': 'Ana\nLuis'},
        'nota demasiado larga': {...ok(), 'note': 'x' * 281},
        'nota que no es texto': {...ok(), 'note': 5},
        'campo desconocido': {...ok(), 'autoaprobar': true},
        'miembros que no son una lista': {...ok(), 'members': 'aa-1'},
        'demasiados miembros': {...ok(), 'members': List.generate(201, (i) => 'm$i-1')},
        'un miembro que no es texto': {...ok(), 'members': [1]},
      };
      for (final e in bad.entries) {
        final r = await post(e.value);
        expect(r.statusCode, 400, reason: e.key);
      }
      expect(approvals(), 0);
    });

    test('un cuerpo enorme responde 413 sin leerlo entero y no escribe nada', () async {
      final r = await post(Uint8List(64 * 1024));
      expect(r.statusCode, 413);
      expect(approvals(), 0);
    });

    test('un cuerpo SIN longitud declarada que se pasa del tope se corta también (no se confía en la cabecera)', () async {
      final stream = Stream<List<int>>.fromIterable(List.generate(40, (_) => Uint8List(1024))); // 40 KB en trozos
      final r = await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/api/approval'), body: stream, headers: {'content-type': 'application/json'})));
      expect(r.statusCode, 413);
      expect(approvals(), 0);
    });

    test('la nota admite saltos de línea; quién, no. Y se recortan los espacios de quién', () async {
      final r = await post({...ok(), 'note': 'línea 1\nlínea 2', 'who': '  Ana  '});
      expect(r.statusCode, 200);
      final e = log.allOfType('approval.granted').single;
      expect(e.body['note'], 'línea 1\nlínea 2');
      expect(e.body['who'], 'Ana');
    });

    test('una petición previa (OPTIONS) de otra página no recibe permiso, ni con --cors desactivado ni con el origen presente', () async {
      final r = await Future.sync(() => handler(Request('OPTIONS', Uri.parse('http://localhost/api/approval'), headers: {'origin': 'http://malo.example', 'access-control-request-method': 'POST', 'access-control-request-headers': 'content-type'})));
      expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(r.headers.containsKey('access-control-allow-headers'), isFalse);
    });

    test('la respuesta de un POST válido tampoco lleva CORS por omisión', () async {
      final r = await post(ok(), headers: {'origin': 'http://malo.example'});
      expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('GET a la ruta de aprobación no existe (sólo se escribe con POST)', () async {
      final r = await Future.sync(() => handler(Request('GET', Uri.parse('http://localhost/api/approval'))));
      expect(r.statusCode, anyOf(404, 405));
    });

    test('ningún camino de lectura ni de tramas escribe aprobaciones: 0 aprobaciones automáticas', () async {
      await Future.sync(() => handler(Request('POST', Uri.parse('http://localhost/frame'), body: vectorBytes('sos_min'))));
      for (final p in ['/api/queue', '/api/health', '/api/events?origin=A&after=0']) {
        await Future.sync(() => handler(Request('GET', Uri.parse('http://localhost$p'))));
      }
      expect(approvals(), 0);
    });
  });
}
