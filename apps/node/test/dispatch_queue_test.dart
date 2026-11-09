import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Cómo ve el coordinador (y el agente 3) un informe de despachador: fuente de segunda mano, sin ubicación, con su
/// origen y quién lo registró, y SIN ser un reporte de la app.
void main() {
  late EventLog log;
  late Dispatch dispatch;
  var n = 0;
  setUp(() {
    log = EventLog.open(':memory:', nodeId: 'A');
    dispatch = Dispatch(log, clock: () => DateTime.fromMillisecondsSinceEpoch(1786370851000));
    n = 0;
  });
  tearDown(() => log.close());

  Event informe(String text, {String? origin, String who = 'Ana Gómez', List<String> flags = const [], int people = 0, String medium = 'radio'}) =>
      dispatch
          .register(parseDispatchRequest({
            'id': 'informe-${n++}-abcdef',
            'text': text,
            'medium': medium,
            'who': who,
            if (origin != null) 'origin': origin,
            'flags': flags,
            'people': people,
          }))
          .event;

  List<QueueItem> cola() => buildQueue(log);

  group('lo que se lee del evento', () {
    test('un informe se funde como fuente «radio», con medio, origen y quién lo registró; sin ubicación', () {
      informe('edificio con gente atrapada', origin: 'Estación 3', medium: 'telefono', people: 2);
      final m = mergeReports(log.allOfType('report.received')).single;
      expect(m.sourceClass, 'radio');
      expect(m.medium, 'telefono');
      expect(m.origin, 'Estación 3');
      expect(m.registeredBy, 'Ana Gómez');
      expect(m.hasLocation, isFalse);
      expect(m.people, PeopleBucket.twoToFive.code);
      expect(m.toObservation().sourceClass, 'radio', reason: 'es lo que lee el agente 3 para la credibilidad base');
      expect(m.toObservation().deviceId, 'radio:estación-3');
    });

    test('una trama de la app sigue siendo «app» y no trae medio, origen ni registrador (nada cambia para ella)', () {
      Ingest(log: log, key: testKey).handleFrame(vectorBytes('sos_min'));
      final m = mergeReports(log.allOfType('report.received')).single;
      expect(m.sourceClass, 'app');
      expect(m.medium, isNull);
      expect(m.origin, isNull);
      expect(m.registeredBy, isNull);
      expect(m.toObservation().sourceClass, 'app');
    });

    test('un source_class de tipo equivocado o vacío se lee como «app» (no rompe la cola)', () {
      log.append('report.received', {'device_id': 'abc', 'text': 'x y z', 'source_class': 7, 'flags': 0}, reportKey: 'k-1', rev: 0);
      log.append('report.received', {'device_id': 'def', 'text': 'x y z', 'source_class': '', 'flags': 0}, reportKey: 'k-2', rev: 0);
      expect(mergeReports(log.allOfType('report.received')).map((m) => m.sourceClass), everyElement('app'));
    });
  });

  group('en la cola', () {
    test('un informe aparece como un elemento de la cola con su fuente, y NO se pierde ni se esconde', () {
      informe('hay gente atrapada en el segundo piso', origin: 'Estación 3');
      final q = cola();
      expect(q.length, 1);
      final it = q.single;
      expect(it.source, 'radio');
      expect(it.medium, 'radio');
      expect(it.origin, 'Estación 3');
      expect(it.registeredBy, 'Ana Gómez');
      expect(it.text, 'hay gente atrapada en el segundo piso');
      expect(it.lat, isNull);
    });

    test('un solo informe de radio: una fuente, confianza BAJA (0,2), «fuente única» y «ubicación ausente» a la vista', () {
      informe('hay gente atrapada en el segundo piso', origin: 'Estación 3');
      final it = cola().single;
      expect(it.sources, 1);
      expect(it.confidence, closeTo(0.2, 1e-9));
      expect(it.uncertainty, containsAll(['fuente_unica', 'ubicacion_ausente']));
    });

    test('la credibilidad baja NO rebaja la urgencia: «atrapado» por radio sigue siendo urgente y se marca para revisar', () {
      informe('hay gente atrapada en el segundo piso', origin: 'Estación 3');
      final it = cola().single;
      expect(it.urgency.index, lessThanOrEqualTo(Urgency.p2.index));
      expect(it.escalate || it.urgency == Urgency.p1 || it.urgency == Urgency.p2, isTrue);
    });

    test('las banderas marcadas por quien registra pesan como las de la app: con «atrapado» y «herido» es P1 aunque el texto no diga nada', () {
      informe('mensaje cortado: calle 12 con', origin: 'Estación 3', flags: ['atrapado', 'herido']);
      final it = cola().single;
      expect(it.urgency, Urgency.p1);
      expect(it.evidence.map((e) => e['field']), containsAll(['flags.atrapado', 'flags.herido']));
    });

    test('INDEPENDENCIA: el mismo texto de orígenes distintos son COPIAS: una sola fuente independiente y confianza 0,2', () {
      for (final o in ['Estación 3', 'Estación 4', 'Radioaficionado Pérez']) {
        informe('hay un edificio caído con gente atrapada en el barrio centro', origin: o);
      }
      final q = cola();
      expect(q.length, 3, reason: 'los tres informes se conservan (no se borra evidencia)');
      expect(q.map((i) => i.group).toSet().length, 1, reason: 'son el mismo suceso');
      for (final it in q) {
        expect(it.groupSize, 3);
        expect(it.sources, 1, reason: 'un rumor repetido no es corroboración');
        expect(it.confidence, closeTo(0.2, 1e-9));
        expect(it.uncertainty, contains('fuente_no_independiente'));
      }
    });

    test('INDEPENDENCIA: el mismo origen repetido es UNA fuente (aunque lo registren personas distintas)', () {
      informe('hay un edificio caído con gente atrapada en el barrio centro', origin: 'Estación 3', who: 'Ana');
      informe('hay un edificio caído con gente atrapada en el barrio centro', origin: 'estación  3', who: 'Luis');
      final q = cola();
      expect(q.map((i) => i.sources).toSet(), {1});
      expect(q.first.confidence, closeTo(0.2, 1e-9));
    });

    test('un informe de radio y una trama de la app son elementos distintos de la cola, cada uno con SU fuente', () {
      Ingest(log: log, key: testKey).handleFrame(vectorBytes('sos_min'));
      informe('hay un incendio en una bodega', origin: 'Estación 3');
      final q = cola();
      expect(q.map((i) => i.source).toSet(), {'app', 'radio'});
      expect(q.firstWhere((i) => i.source == 'app').medium, isNull);
    });
  });

  group('el JSON que lee el tablero', () {
    test('lleva source, medium, origin y registeredBy (los de la app, con nulos), y sigue llevando todo lo anterior', () {
      informe('hay gente atrapada', origin: 'Estación 3');
      Ingest(log: log, key: testKey).handleFrame(vectorBytes('sos_min'));
      final byKey = {for (final i in cola()) i.reportKey: i.toJson()};
      final radio = byKey['desp-informe-0-abcdef']!;
      expect(radio['source'], 'radio');
      expect(radio['medium'], 'radio');
      expect(radio['origin'], 'Estación 3');
      expect(radio['registeredBy'], 'Ana Gómez');
      final app = byKey['9a3c51e07b2d44f1-17']!;
      expect(app['source'], 'app');
      expect(app['medium'], isNull);
      expect(app['origin'], isNull);
      expect(app['registeredBy'], isNull);
      for (final k in ['reportKey', 'urgency', 'text', 'people', 'peopleLabel', 'evidence', 'capturedAt', 'receivedAt', 'signals', 'group', 'sources', 'confidence', 'uncertainty']) {
        expect(radio.containsKey(k), isTrue, reason: k);
      }
    });
  });
}
