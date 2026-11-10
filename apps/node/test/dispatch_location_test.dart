import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'log_support.dart';

Map<String, Object?> ok([Map<String, Object?> over = const {}]) => {
  'id': 'a1b2c3d4e5f6',
  'text': 'edificio con gente atrapada en la carrera 23',
  'medium': 'radio',
  'who': 'Ana Gómez',
  ...over,
};

void main() {
  group('parseDispatchRequest: la ubicación es opcional y estricta', () {
    test('sin ubicación sigue siendo válido (como siempre)', () {
      final r = parseDispatchRequest(ok());
      expect(r.lat, isNull);
      expect(r.lon, isNull);
    });

    test('latitud y longitud juntas', () {
      final r = parseDispatchRequest(ok({'lat': 5.0689, 'lon': -75.5174}));
      expect((r.lat, r.lon), (5.0689, -75.5174));
    });

    test('un entero también es un número válido (los JSON de otros lenguajes escriben 5 y no 5.0)', () {
      final r = parseDispatchRequest(ok({'lat': 5, 'lon': -75}));
      expect((r.lat, r.lon), (5.0, -75.0));
    });

    test('una sola de las dos es un error: una ubicación a medias no se inventa ni se completa', () {
      expect(() => parseDispatchRequest(ok({'lat': 5.0})), throwsFormatException);
      expect(() => parseDispatchRequest(ok({'lon': -75.0})), throwsFormatException);
    });

    test('fuera de rango, o de otro tipo: error con el campo en el mensaje', () {
      for (final bad in [
        {'lat': 91.0, 'lon': 0.0},
        {'lat': -90.5, 'lon': 0.0},
        {'lat': 0.0, 'lon': 181.0},
        {'lat': 0.0, 'lon': -180.1},
        {'lat': '5.07', 'lon': -75.5},
        {'lat': 5.07, 'lon': true},
        {'lat': null, 'lon': -75.5},
        {'lat': double.nan, 'lon': 0.0},
        {'lat': double.infinity, 'lon': 0.0},
      ]) {
        expect(() => parseDispatchRequest(ok(bad)), throwsA(isA<FormatException>().having((e) => e.message, 'mensaje', anyOf(contains('lat'), contains('lon')))), reason: '$bad');
      }
    });

    test('los extremos válidos se aceptan', () {
      expect(parseDispatchRequest(ok({'lat': 90.0, 'lon': 180.0})).lat, 90.0);
      expect(parseDispatchRequest(ok({'lat': -90.0, 'lon': -180.0})).lon, -180.0);
    });
  });

  group('Dispatch.register: lo que se escribe', () {
    late EventLog log;
    late Dispatch dispatch;
    setUp(() {
      log = EventLog.open(':memory:', nodeId: 'A');
      dispatch = Dispatch(log, clock: () => DateTime.fromMillisecondsSinceEpoch(1786370000000));
    });
    tearDown(() => log.close());

    test('con ubicación: las coordenadas y la calidad «manual» (la escribió una persona, no un GPS)', () {
      final e = dispatch.register(parseDispatchRequest(ok({'lat': 5.0689, 'lon': -75.5174}))).event;
      expect(e.body['lat'], 5.0689);
      expect(e.body['lon'], -75.5174);
      expect(e.body['loc_quality'], LocQuality.manual.index);
    });

    test('sin ubicación: nulos y calidad 0, como antes', () {
      final e = dispatch.register(parseDispatchRequest(ok())).event;
      expect(e.body['lat'], isNull);
      expect(e.body['lon'], isNull);
      expect(e.body['loc_quality'], 0);
    });

    test('un reintento con la misma ubicación no escribe nada; con OTRA ubicación es un conflicto', () {
      final first = dispatch.register(parseDispatchRequest(ok({'lat': 5.07, 'lon': -75.51})));
      final again = dispatch.register(parseDispatchRequest(ok({'lat': 5.07, 'lon': -75.51})));
      expect(again.duplicate, isTrue);
      expect(again.event.id, first.event.id);
      expect(() => dispatch.register(parseDispatchRequest(ok({'lat': 5.08, 'lon': -75.51}))), throwsA(isA<DispatchConflict>()));
      expect(() => dispatch.register(parseDispatchRequest(ok({'lat': 5.07, 'lon': -75.52}))), throwsA(isA<DispatchConflict>()), reason: 'cambiar sólo la longitud también es otro contenido');
      expect(() => dispatch.register(parseDispatchRequest(ok())), throwsA(isA<DispatchConflict>()), reason: 'quitar la ubicación también cambia el contenido');
    });
  });

  group('con ubicación, un informe de segunda mano ya puede recibir recomendación, sin dejar de ser de segunda mano', () {
    late EventLog log;
    setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
    tearDown(() => log.close());

    IncidentData only() => buildIncidents(buildQueue(log), approvals: const [], resources: testResources()).single;

    test('SIN ubicación: no hay recomendación, y dice que falta saber el dónde (como antes)', () {
      Dispatch(log).register(parseDispatchRequest(ok({'flags': ['atrapado']})));
      final rec = (only().summary['recommendation']! as Map).cast<String, Object?>();
      expect(rec['state'], 'informacion_requerida');
      expect(rec['missing'], contains('ubicacion'));
    });

    test('CON ubicación: sí hay propuesta, y sigue pidiendo una segunda fuente, confirmar la ubicación y aprobación humana', () {
      Dispatch(log).register(parseDispatchRequest(ok({'flags': ['atrapado'], 'lat': 5.0689, 'lon': -75.5174})));
      final i = only();
      final rec = (i.summary['recommendation']! as Map).cast<String, Object?>();
      expect(rec['state'], 'propuesta');
      expect(rec['pending'], containsAll(['confirmar_segunda_fuente', 'confirmar_ubicacion']));
      expect((i.detail['recommendation']! as Map)['requires_approval'], isTrue);
      expect((i.summary['approval']! as Map)['status'], 'pendiente', reason: 'nada se aprueba solo');
    });

    test('el incidente sigue siendo de segunda mano, con una sola fuente y confianza baja', () {
      Dispatch(log).register(parseDispatchRequest(ok({'flags': ['atrapado'], 'lat': 5.0689, 'lon': -75.5174})));
      final s = only().summary;
      expect(s['fromDispatch'], 1);
      expect(s['sources'], 1);
      expect(s['confidence'] as num, lessThan(0.5));
    });

    test('la ubicación del incidente es la escrita a mano, y así lo dice', () {
      Dispatch(log).register(parseDispatchRequest(ok({'lat': 5.0689, 'lon': -75.5174})));
      final s = only().summary;
      expect(s['lat'], closeTo(5.0689, 1e-9));
      expect(s['locQuality'], 'manual');
      expect((s['uncertainty']! as List), contains('ubicacion_imprecisa'));
    });

    test('NO cambia el triaje: la urgencia sale de lo que dice el informe, con o sin ubicación', () {
      final other = EventLog.open(':memory:', nodeId: 'B');
      Dispatch(log).register(parseDispatchRequest(ok({'flags': ['atrapado'], 'lat': 5.0689, 'lon': -75.5174})));
      Dispatch(other).register(parseDispatchRequest(ok({'flags': ['atrapado']})));
      final withLoc = only();
      final without = buildIncidents(buildQueue(other), approvals: const [], resources: testResources()).single;
      other.close();
      expect(withLoc.urgency, without.urgency);
    });
  });

  group('el protocolo no cambia: «manual» sigue sin llevar coordenadas en la trama', () {
    test('LocQuality.manual.hasCoordinates es falso', () {
      expect(LocQuality.manual.hasCoordinates, isFalse);
    });

    test('pero para el nodo, un «manual» CON coordenadas es una ubicación utilizable (y una sin ellas, no)', () {
      expect(hasUsableCoordinates(LocQuality.manual), isTrue);
      expect(hasUsableCoordinates(LocQuality.within50m), isTrue);
      expect(hasUsableCoordinates(LocQuality.none), isFalse);
    });
  });
}
