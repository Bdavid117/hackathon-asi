import 'dart:convert';
import 'dart:io';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

/// El informe de un despachador (radio, teléfono o en persona): validación ESTRICTA de lo que llega y el evento
/// `report.received` que se escribe. Nada de esto es identidad: `who` lo declara quien teclea.
Map<String, Object?> ok([Map<String, Object?> over = const {}]) => {
  'id': 'a1b2c3d4e5f6',
  'text': 'edificio con gente atrapada en la carrera 23',
  'medium': 'radio',
  'who': 'Ana Gómez',
  ...over,
};

void main() {
  group('parseDispatchRequest', () {
    test('un informe mínimo es válido y los opcionales tienen valores neutros', () {
      final r = parseDispatchRequest(ok());
      expect(r.id, 'a1b2c3d4e5f6');
      expect(r.text, 'edificio con gente atrapada en la carrera 23');
      expect(r.medium, DispatchMedium.radio);
      expect(r.who, 'Ana Gómez');
      expect(r.origin, isNull);
      expect(r.flags, 0);
      expect(r.people, 0);
    });

    test('flags por NOMBRE (los mismos códigos que el triaje) y personas por código de PeopleBucket', () {
      final r = parseDispatchRequest(ok({'flags': ['atrapado', 'herido', 'atrapado'], 'people': 2}));
      expect(r.flags, SituationFlags.atrapado | SituationFlags.herido);
      expect(r.people, PeopleBucket.twoToFive.code);
      final all = parseDispatchRequest(ok({
        'flags': ['atrapado', 'herido', 'incendio', 'dificultad_respiratoria', 'via_bloqueada', 'estructura_inestable', 'menores_mayores', 'medicacion'],
      }));
      expect(all.flags, 0xFF);
    });

    test('quita espacios de los extremos de who, origin y text; un origen en blanco es «sin origen»', () {
      final r = parseDispatchRequest(ok({'who': '  Ana  ', 'origin': '   ', 'text': '  hay humo  '}));
      expect(r.who, 'Ana');
      expect(r.origin, isNull);
      expect(r.text, 'hay humo');
      expect(parseDispatchRequest(ok({'origin': ' Estación 3 '})).origin, 'Estación 3');
    });

    test('saltos de línea y tabuladores del texto se vuelven un espacio (un informe es una sola línea)', () {
      expect(parseDispatchRequest(ok({'text': 'uno\ndos\r\ntres\tcuatro'})).text, 'uno dos  tres cuatro');
    });

    test('mediums válidos: radio, telefono y presencial', () {
      for (final m in ['radio', 'telefono', 'presencial']) {
        expect(parseDispatchRequest(ok({'medium': m})).medium.name, m);
      }
    });

    test('el texto admite 500 caracteres exactos y rechaza 501; cuenta caracteres, no bytes (una «ñ» o un emoji cuentan 1)', () {
      expect(parseDispatchRequest(ok({'text': 'a' * 500})).text.length, 500);
      expect(() => parseDispatchRequest(ok({'text': 'a' * 501})), throwsFormatException);
      expect(parseDispatchRequest(ok({'text': 'ñ' * 500})).text.runes.length, 500);
      expect(parseDispatchRequest(ok({'text': '🔥' * 500})).text.runes.length, 500);
      expect(() => parseDispatchRequest(ok({'text': '🔥' * 501})), throwsFormatException);
    });

    final malos = <String, Object?>{
      'no es un objeto (lista)': [1, 2],
      'no es un objeto (texto)': 'hola',
      'null': null,
      'campo desconocido': {...ok(), 'lat': 5.0},
      'sin id': {...ok()}..remove('id'),
      'id corto (7)': ok({'id': 'abcdefg'}),
      'id largo (65)': ok({'id': 'a' * 65}),
      'id con espacios': ok({'id': 'abcd efgh'}),
      'id con barra': ok({'id': 'abcd/efgh'}),
      'id con acento': ok({'id': 'abcdéfgh'}),
      'id no es texto': ok({'id': 12345678}),
      'sin text': {...ok()}..remove('text'),
      'text vacío': ok({'text': ''}),
      'text sólo espacios': ok({'text': '   \n\t  '}),
      'text no es texto': ok({'text': 5}),
      'text con NUL': ok({'text': 'a\u0000b'}),
      'text con escape': ok({'text': 'a\u001bb'}),
      'text con DEL': ok({'text': 'a\u007fb'}),
      'sin medium': {...ok()}..remove('medium'),
      'medium desconocido': ok({'medium': 'paloma'}),
      'medium con mayúsculas': ok({'medium': 'Radio'}),
      'sin who': {...ok()}..remove('who'),
      'who vacío': ok({'who': '  '}),
      'who de 81': ok({'who': 'a' * 81}),
      'who con salto de línea': ok({'who': 'Ana\nGómez'}),
      'who no es texto': ok({'who': 7}),
      'origin no es texto': ok({'origin': 7}),
      'origin de 81': ok({'origin': 'a' * 81}),
      'origin con salto de línea': ok({'origin': 'Est\nación'}),
      'flags no es lista': ok({'flags': 'atrapado'}),
      'flags con nombre desconocido': ok({'flags': ['volando']}),
      'flags con un número': ok({'flags': [128]}),
      'flags con mayúsculas': ok({'flags': ['Atrapado']}),
      'people como texto': ok({'people': '2'}),
      'people fraccionario': ok({'people': 2.5}),
      'people fuera de rango (6)': ok({'people': 6}),
      'people negativo': ok({'people': -1}),
    };
    malos.forEach((nombre, cuerpo) {
      test('rechaza: $nombre', () => expect(() => parseDispatchRequest(cuerpo), throwsFormatException));
    });

    test('CONTRATO con el tablero: el literal que envía el tablero (test/fixtures/dispatch_request.json, el mismo que lee su prueba) se acepta tal cual', () {
      final literal = jsonDecode(File('test/fixtures/dispatch_request.json').readAsStringSync());
      final r = parseDispatchRequest(literal);
      expect(r.id, 'a1b2c3d4e5f6a7b8');
      expect(r.medium, DispatchMedium.telefono);
      expect(r.origin, 'Estación Bomberos 3');
      expect(r.who, 'Ana Gómez');
      expect(r.flags, SituationFlags.atrapado | SituationFlags.herido);
      expect(r.people, PeopleBucket.twoToFive.code);
      // Y sólo trae campos que el nodo conoce: si el tablero añade uno, esto y el nodo deben cambiar juntos.
      expect((literal as Map).keys.toSet(), {'id', 'text', 'medium', 'origin', 'who', 'flags', 'people'});
    });

    test('el mensaje de un rechazo dice qué campo está mal (no «error»)', () {
      expect(() => parseDispatchRequest(ok({'medium': 'paloma'})), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('medium'))));
      expect(() => parseDispatchRequest(ok({'text': ''})), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('text'))));
      expect(() => parseDispatchRequest({...ok(), 'lat': 1}), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('lat'))));
    });
  });

  group('Dispatch.register', () {
    late EventLog log;
    late Dispatch dispatch;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      dispatch = Dispatch(log, clock: () => DateTime.fromMillisecondsSinceEpoch(1786370851000));
    });
    tearDown(() => log.close());

    test('escribe UN report.received, con clave estable «desp-<id>» y revisión 0', () {
      final r = dispatch.register(parseDispatchRequest(ok()));
      expect(r.duplicate, isFalse);
      expect(log.allOfType('report.received').length, 1);
      final e = r.event;
      expect(e.type, 'report.received');
      expect(e.reportKey, 'desp-a1b2c3d4e5f6');
      expect(e.rev, 0);
    });

    test('el cuerpo dice de dónde viene y qué NO se sabe: segunda mano («radio»), sin ubicación, quién lo registró', () {
      final b = dispatch.register(parseDispatchRequest(ok({'origin': 'Estación Bomberos 3', 'medium': 'telefono', 'flags': ['atrapado'], 'people': 3}))).event.body;
      expect(b['channel'], 'dispatcher');
      expect(b['source_class'], 'radio');
      expect(b['medium'], 'telefono');
      expect(b['origin'], 'Estación Bomberos 3');
      expect(b['registered_by'], 'Ana Gómez');
      expect(b['text'], 'edificio con gente atrapada en la carrera 23');
      expect(b['flags'], SituationFlags.atrapado);
      expect(b['people_bucket'], 3);
      expect(b['incident_type'], 1, reason: 'SOS genérico, igual que la app: no separa por tipo');
      expect(b['lat'], isNull, reason: 'el agente 1 no inventa la ubicación');
      expect(b['lon'], isNull);
      expect(b['loc_quality'], 0);
      expect(b['captured_at'], 1786370851, reason: 'hora del NODO al registrar, no la de cuando se oyó');
      expect(b['received_at'], 1786370851000);
    });

    test('el cuerpo trae TODAS las claves de un report.received de trama (con nulos en las propias de la trama): ningún lector tropieza', () {
      final fromFrame = EventLog.open(':memory:', nodeId: 'F');
      Ingest(log: fromFrame, key: testKey).handleFrame(vectorBytes('sos_min'));
      final frameKeys = fromFrame.allOfType('report.received').single.body.keys.toSet();
      fromFrame.close();
      final body = dispatch.register(parseDispatchRequest(ok())).event.body;
      expect(body.keys.toSet().containsAll(frameKeys), isTrue, reason: 'faltan: ${frameKeys.difference(body.keys.toSet())}');
      // Y lo propio de la trama no puede pasar por un dispositivo ni por un número de trama.
      expect(body['frame_seq'], isNull);
      expect(body['ref_seq'], isNull);
      expect(body['battery_q'], isNull);
      // Sobrevive al viaje por JSON (replicación) sin cambiar de forma.
      expect(jsonDecode(jsonEncode(body)), body);
    });

    test('la independencia la da el ORIGEN declarado, no quien teclea: mismo origen (aun con otra caja o espacios) = misma fuente', () {
      String dev(String? origin, {String who = 'Ana'}) => dispatch
          .register(parseDispatchRequest(ok({'id': 'id-${origin.hashCode}-$who-xx', 'origin': origin, 'who': who})))
          .event
          .body['device_id']! as String;
      expect(dev('Estación Bomberos 3'), 'radio:estación-bomberos-3');
      expect(dev('  estación   bomberos 3 ', who: 'Luis'), 'radio:estación-bomberos-3');
      expect(dev('Estación Bomberos 4'), 'radio:estación-bomberos-4');
      expect(dev(null), 'radio:sin-origen');
    });

    test('el origen no puede colarse en el identificador con signos raros (todo lo que no es letra, cifra o guion se descarta)', () {
      final id = dispatch.register(parseDispatchRequest(ok({'origin': 'Radio: 9a3c/../x;DROP \'--'}))).event.body['device_id']! as String;
      expect(id, matches(RegExp(r'^radio:[\p{L}\p{N}-]+$', unicode: true)));
    });

    test('el mismo id con el MISMO contenido es un reintento: no duplica y devuelve el mismo evento', () {
      final a = dispatch.register(parseDispatchRequest(ok()));
      final b = dispatch.register(parseDispatchRequest(ok()));
      expect(b.duplicate, isTrue);
      expect(b.event.id, a.event.id);
      expect(log.allOfType('report.received').length, 1);
    });

    test('el mismo id con OTRO contenido NO se pierde en silencio: es un conflicto y el log queda igual', () {
      dispatch.register(parseDispatchRequest(ok()));
      for (final cambio in <Map<String, Object?>>[
        {'text': 'otra cosa distinta'},
        {'medium': 'telefono'},
        {'origin': 'Estación 9'},
        {'who': 'Luis Pérez'},
        {'flags': ['herido']},
        {'people': 2},
      ]) {
        expect(() => dispatch.register(parseDispatchRequest(ok(cambio))), throwsA(isA<DispatchConflict>()), reason: '$cambio');
      }
      expect(log.allOfType('report.received').length, 1);
    });

    test('ids distintos son informes distintos aunque el texto sea igual (no se decide por el texto)', () {
      dispatch.register(parseDispatchRequest(ok()));
      dispatch.register(parseDispatchRequest(ok({'id': 'zzzzzzzz1111'})));
      expect(log.allOfType('report.received').length, 2);
    });
  });
}
