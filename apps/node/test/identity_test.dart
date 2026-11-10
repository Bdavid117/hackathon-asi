import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Identidad del aprobador (`--coordinator-codes "Ana=código,Luis=código"`): el código dice QUIÉN es.
///
/// Lo que se garantiza: quien presenta el código de Luis NO puede firmar como Ana en este nodo. Lo que NO: no hay TLS ni límite de
/// intentos (el código viaja en claro por la red local), y los nodos pares replican el evento SIN volver a comprobar el nombre
/// (un par con el código de réplica puede escribir cualquier «who»). Por eso se dice «identificado por código», no «autenticado».
/// Y el tiempo constante de la comparación no se puede demostrar con pruebas ni con mutaciones: se revisa leyendo el código.
const ana = 'Ana Gómez';
const luis = 'Luis Torres';
const anaCode = 'ana-codigo-26';
const luisCode = 'luis-codigo-26';
const peerCode = 'pares-2026';

void main() {
  group('parseCoordinatorCodes', () {
    test('una lista válida: nombre → código, con espacios alrededor del nombre recortados y tildes respetadas', () {
      expect(parseCoordinatorCodes(' Ana Gómez =$anaCode,$luis=$luisCode'), {ana: anaCode, luis: luisCode});
    });

    test('un solo coordinador es válido', () {
      expect(parseCoordinatorCodes('$ana=$anaCode'), {ana: anaCode});
    });

    final bad = <String, String>{
      'vacío': '',
      'sólo espacios': '   ',
      'sin «=»': 'Ana',
      'código vacío': 'Ana=',
      'nombre vacío': '=$anaCode',
      'código corto (menos de 8)': 'Ana=corto',
      'entrada vacía al final': '$ana=$anaCode,',
      'sólo una coma': ',',
      'dos «=» (no se puede expresar sin ambigüedad)': 'Ana=cod=igo-1234',
      'nombre repetido': 'Ana=$anaCode,Ana=$luisCode',
      'nombre repetido salvo mayúsculas': 'Ana=$anaCode,ANA=$luisCode',
      'nombre repetido salvo espacios': 'Ana=$anaCode, Ana =$luisCode',
      'código repetido': 'Ana=$anaCode,Luis=$anaCode',
      'nombre de más de 80 caracteres': '${'x' * 81}=$anaCode',
      'nombre con salto de línea': 'Ana\nGómez=$anaCode',
      'código con espacio': 'Ana=codigo con espacio',
      'código con salto de línea': 'Ana=codigo-1234\n',
    };
    for (final e in bad.entries) {
      test('rechaza: ${e.key}', () {
        expect(() => parseCoordinatorCodes(e.value), throwsA(isA<FormatException>()));
      });
    }

    test('un código igual al de la réplica se rechaza (quien copia el log no debe poder aprobar)', () {
      expect(() => parseCoordinatorCodes('$ana=$peerCode', peerToken: peerCode), throwsA(isA<FormatException>()));
      expect(parseCoordinatorCodes('$ana=$anaCode', peerToken: peerCode), {ana: anaCode});
    });

    test('un mensaje de error NUNCA repite un código', () {
      for (final raw in ['Ana=corto', 'Ana=$anaCode,Luis=$anaCode', '$ana=$peerCode', 'Ana=$anaCode,Ana=$luisCode', 'Ana=cod=igo-1234']) {
        try {
          parseCoordinatorCodes(raw, peerToken: peerCode);
        } on FormatException catch (e) {
          for (final secret in [anaCode, luisCode, peerCode, 'corto', 'cod=igo-1234', 'igo-1234']) {
            expect(e.message, isNot(contains(secret)), reason: 'el error de «$raw» filtra un código');
          }
        }
      }
    });
  });

  group('identifyBearer', () {
    final codes = {ana: anaCode, luis: luisCode};

    test('el código exacto identifica a su dueño', () {
      expect(identifyBearer('Bearer $anaCode', codes), ana);
      expect(identifyBearer('Bearer $luisCode', codes), luis);
    });

    test('el esquema no distingue mayúsculas, el código sí', () {
      expect(identifyBearer('bearer $anaCode', codes), ana);
      expect(identifyBearer('BEARER $anaCode', codes), ana);
      expect(identifyBearer('Bearer ${anaCode.toUpperCase()}', codes), isNull);
    });

    test('nada que se le parezca sirve: sin cabecera, vacío, otro esquema, un espacio de más, un prefijo o un sufijo', () {
      for (final h in [null, '', 'Bearer', 'Bearer ', 'Basic $anaCode', 'Bearer  $anaCode', 'Bearer $anaCode ', 'Bearer ${anaCode.substring(0, 8)}', 'Bearer ${anaCode}x', 'Bearer otro-codigo']) {
        expect(identifyBearer(h, codes), isNull, reason: '$h');
      }
    });

    test('un código que es prefijo de otro no autentica al largo, ni al revés', () {
      final c = {'Corto': 'abcdefgh', 'Largo': 'abcdefghi'};
      expect(identifyBearer('Bearer abcdefgh', c), 'Corto');
      expect(identifyBearer('Bearer abcdefghi', c), 'Largo');
      expect(identifyBearer('Bearer abcdefghij', c), isNull);
    });

    test('sin ningún código configurado no identifica a nadie', () {
      expect(identifyBearer('Bearer $anaCode', const {}), isNull);
    });
  });

  group('con --coordinator-codes (sólo códigos, sin --coordinator-token)', () {
    late EventLog log;
    late Handler h;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      h = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorCodes: {ana: anaCode, luis: luisCode}, peerToken: peerCode);
    });
    tearDown(() => log.close());

    Future<Response> get(Handler handler, String path, {String? auth}) => Future.sync(() => handler(Request('GET', Uri.parse('http://localhost$path'), headers: {'authorization': ?auth})));
    Future<Response> post(String path, Object body, {String? auth, Handler? handler}) => Future.sync(
      () => (handler ?? h)(Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body), headers: {'content-type': 'application/json', 'authorization': ?auth})),
    );

    const coordinatorPaths = ['/api/queue', '/api/incidents', '/api/incidents/aa-1', '/api/nodes', '/api/resources', '/api/whoami'];

    test('LA TRAMPA: con sólo códigos (ni coordinador ni réplica) la API NO queda abierta', () async {
      final onlyCodes = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorCodes: {ana: anaCode});
      for (final path in coordinatorPaths) {
        expect((await get(onlyCodes, path)).statusCode, 401, reason: 'GET $path sin cabecera');
        expect((await get(onlyCodes, path, auth: 'Bearer otro-codigo')).statusCode, 401, reason: 'GET $path con un código desconocido');
      }
      for (final path in ['/api/approval', '/api/dispatch', '/api/resources']) {
        expect((await post(path, {}, handler: onlyCodes)).statusCode, 401, reason: 'POST $path sin cabecera');
      }
      expect((await get(onlyCodes, '/api/queue', auth: 'Bearer $anaCode')).statusCode, 200);
    });

    for (final path in coordinatorPaths) {
      test('GET $path: 401 sin código y con uno desconocido; pasa con el de cualquiera de los dos', () async {
        expect((await get(h, path)).statusCode, 401);
        expect((await get(h, path, auth: 'Bearer nope-nope')).statusCode, 401);
        expect((await get(h, path, auth: 'Bearer $anaCode')).statusCode, isNot(401));
        expect((await get(h, path, auth: 'Bearer $luisCode')).statusCode, isNot(401));
      });
    }

    test('el código de la réplica NO abre lo del coordinador y los de coordinador NO abren la réplica', () async {
      expect((await get(h, '/api/queue', auth: 'Bearer $peerCode')).statusCode, 401);
      expect((await get(h, '/api/events?origin=A', auth: 'Bearer $anaCode')).statusCode, 401);
      expect((await get(h, '/api/events?origin=A', auth: 'Bearer $peerCode')).statusCode, 200);
    });

    test('sin código de réplica, /api/events sigue abierto como hoy (y el nodo lo avisa al arrancar)', () async {
      final noPeer = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorCodes: {ana: anaCode});
      expect((await get(noPeer, '/api/events?origin=A')).statusCode, 200);
    });

    test('/api/health y /frame siguen abiertos', () async {
      expect((await get(h, '/api/health')).statusCode, 200);
    });

    test('combinar --coordinator-token con los códigos es un error (quien tuviera el token firmaría con cualquier nombre)', () {
      expect(() => buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: 'coord-2026', coordinatorCodes: {ana: anaCode}), throwsArgumentError);
    });

    test('un código igual al de la réplica también es un error al construir el manejador', () {
      expect(() => buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorCodes: {ana: peerCode}, peerToken: peerCode), throwsArgumentError);
    });

    group('GET /api/whoami', () {
      test('dice quién es el dueño del código, sin caché', () async {
        final r = await get(h, '/api/whoami', auth: 'Bearer $luisCode');
        expect(r.statusCode, 200);
        expect(jsonDecode(await r.readAsString()), {'who': luis});
        expect(r.headers['cache-control'], 'no-store');
        expect(r.headers['etag'], isNull, reason: 'una identidad no se cachea ni se valida por etiqueta');
        expect(r.headers['content-type'], startsWith('application/json'));
      });

      test('sin códigos configurados no hay identidad: {who: null}', () async {
        final open = buildHandler(ingest: Ingest(log: log, key: testKey), log: log);
        expect(jsonDecode(await (await get(open, "/api/whoami")).readAsString()), {'who': null});
        final tokenOnly = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: 'coord-2026');
        expect(jsonDecode(await (await get(tokenOnly, '/api/whoami', auth: 'Bearer coord-2026')).readAsString()), {'who': null});
      });
    });

    group('la aprobación la firma quien presenta el código', () {
      Map<String, Object?> approval({Object? who = 'omitido'}) => {
        'recommendationId': 'a1b2c3d4e5f60718',
        'incidentId': 'aa-1',
        'members': ['aa-1'],
        'decision': 'granted',
        'note': '',
        if (who != 'omitido') 'who': who,
      };
      int count() => log.allOfType('approval.granted').length + log.allOfType('approval.denied').length;
      String signedBy() => log.allOfType('approval.granted').single.body['who']! as String;

      test('sin «who» en el cuerpo se registra con el nombre del código', () async {
        final r = await post('/api/approval', approval(), auth: 'Bearer $anaCode');
        expect(r.statusCode, 200);
        expect(signedBy(), ana);
      });

      test('con «who» igual al del código (aun con espacios) se registra con ese nombre', () async {
        expect((await post('/api/approval', approval(who: '  $luis '), auth: 'Bearer $luisCode')).statusCode, 200);
        expect(signedBy(), luis);
      });

      test('el código de Luis NO firma como Ana: 403 y NO se añade ningún evento', () async {
        final before = log.count();
        final r = await post('/api/approval', approval(who: ana), auth: 'Bearer $luisCode');
        expect(r.statusCode, 403);
        expect(await r.readAsString(), contains('no coincide'));
        expect(count(), 0);
        expect(log.count(), before, reason: 'ni un evento por una firma que no corresponde');
      });

      test('un «who» que no es texto, vacío o con otras mayúsculas tampoco se acepta con otro código', () async {
        for (final who in [123, '', '   ', ana.toUpperCase(), ['Ana'], {'a': 1}]) {
          expect((await post('/api/approval', approval(who: who), auth: 'Bearer $luisCode')).statusCode, 403, reason: '$who');
        }
        expect(count(), 0);
      });

      test('«who»: null cuenta como ausente (se rellena)', () async {
        expect((await post('/api/approval', approval(who: null), auth: 'Bearer $anaCode')).statusCode, 200);
        expect(signedBy(), ana);
      });

      test('el cuerpo mal formado sigue siendo 400 (la identidad no tapa la validación)', () async {
        expect((await post('/api/approval', {'decision': 'granted'}, auth: 'Bearer $anaCode')).statusCode, 400);
        expect(count(), 0);
      });
    });

    group('el informe del despachador lo registra quien presenta el código', () {
      Map<String, Object?> report({Object? who = 'omitido'}) => {
        'id': 'a1b2c3d4e5f6a7b8',
        'text': 'edificio con gente atrapada',
        'medium': 'telefono',
        if (who != 'omitido') 'who': who,
      };
      String registeredBy() => log.allOfType('report.received').single.body['registered_by']! as String;

      test('sin «who» se registra con el nombre del código', () async {
        final r = await post('/api/dispatch', report(), auth: 'Bearer $luisCode');
        expect(r.statusCode, 200);
        expect(registeredBy(), luis);
      });

      test('el código de Luis NO registra como Ana: 403 y el log queda igual', () async {
        final before = log.count();
        expect((await post('/api/dispatch', report(who: ana), auth: 'Bearer $luisCode')).statusCode, 403);
        expect(log.count(), before);
      });
    });

    group('la declaración de un recurso la firma quien presenta el código', () {
      Map<String, Object?> unit({Object? who = 'omitido'}) => {
        'id': 'AMB-01',
        'kind': 'ambulancia',
        'label': 'Ambulancia 1',
        'lat': 5.07,
        'lon': -75.51,
        'available': false,
        if (who != 'omitido') 'who': who,
      };
      String declaredBy() => log.allOfType('resource.declared').single.body['declared_by']! as String;

      test('sin «who» se registra con el nombre del código', () async {
        expect((await post('/api/resources', unit(), auth: 'Bearer $anaCode')).statusCode, 200);
        expect(declaredBy(), ana);
      });

      test('el código de Luis NO declara como Ana: 403 y el log queda igual', () async {
        final before = log.count();
        expect((await post('/api/resources', unit(who: ana), auth: 'Bearer $luisCode')).statusCode, 403);
        expect(log.count(), before);
      });
    });

    test('con un solo --coordinator-token (sin identidad) «who» sigue siendo obligatorio y libre, como hoy', () async {
      final tokenOnly = buildHandler(ingest: Ingest(log: log, key: testKey), log: log, coordinatorToken: 'coord-2026');
      Map<String, Object?> approval([String? who]) => {'recommendationId': 'a1b2c3d4e5f60718', 'incidentId': 'aa-1', 'members': ['aa-1'], 'decision': 'granted', 'note': '', 'who': ?who};
      expect((await post('/api/approval', approval(), auth: 'Bearer coord-2026', handler: tokenOnly)).statusCode, 400, reason: 'sin identidad y sin who: no hay quién firme');
      expect((await post('/api/approval', approval('Cualquiera'), auth: 'Bearer coord-2026', handler: tokenOnly)).statusCode, 200);
    });
  });
}
