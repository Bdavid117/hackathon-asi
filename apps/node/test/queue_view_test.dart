import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

/// Escribe un `report.received` con el mismo cuerpo que produce `Ingest`.
Event received(
  EventLog log,
  String reportKey,
  int rev, {
  int flags = 0,
  int locQuality = 2,
  double? lat = 5.07,
  double? lon = -75.51,
  String? text,
  int capturedAt = 1000,
  int receivedAt = 5000,
  int people = 0,
}) =>
    log.append(
      'report.received',
      {
        'device_id': reportKey.split('-').first,
        'frame_seq': rev + 1,
        'flags': flags,
        'people_bucket': people,
        'incident_type': 1,
        'loc_quality': locQuality,
        'lat': lat,
        'lon': lon,
        'text': text,
        'captured_at': capturedAt,
        'received_at': receivedAt,
      },
      reportKey: reportKey,
      rev: rev,
    );

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  test('P1 va antes que P3 aunque haya llegado después', () {
    received(log, 'aa-1', 0, flags: SituationFlags.viaBloqueada);
    received(log, 'bb-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido);
    final q = buildQueue(log);
    expect(q.map((i) => i.reportKey), ['bb-1', 'aa-1']);
    expect(q.first.urgency, Urgency.p1);
    expect(q.first.signals, ['atrapado', 'herido']);
  });

  test('a igual urgencia, el reporte capturado antes va primero', () {
    received(log, 'aa-1', 0, flags: SituationFlags.atrapado, capturedAt: 2000);
    received(log, 'bb-1', 0, flags: SituationFlags.atrapado, capturedAt: 1000);
    expect(buildQueue(log).map((i) => i.reportKey), ['bb-1', 'aa-1']);
  });

  test('la revisión 1 conserva la ubicación de la 0 y añade el texto', () {
    received(log, 'aa-1', 0, flags: SituationFlags.atrapado);
    received(log, 'aa-1', 1, flags: SituationFlags.atrapado, locQuality: 0, lat: null, lon: null, text: 'bajo la losa');
    final item = buildQueue(log).single;
    expect(item.rev, 1);
    expect(item.lat, 5.07);
    expect(item.lon, -75.51);
    expect(item.text, 'bajo la losa');
  });

  test('una revisión que entra al log antes que la 0 da el mismo resultado', () {
    received(log, 'aa-1', 1, flags: SituationFlags.atrapado, locQuality: 0, lat: null, lon: null, text: 'bajo la losa');
    received(log, 'aa-1', 0, flags: SituationFlags.atrapado);
    final item = buildQueue(log).single;
    expect(item.rev, 1);
    expect(item.lat, 5.07);
    expect(item.text, 'bajo la losa');
  });

  test('la revisión más alta manda en las banderas', () {
    received(log, 'aa-1', 0, flags: SituationFlags.viaBloqueada);
    received(log, 'aa-1', 1, flags: SituationFlags.atrapado | SituationFlags.incendio);
    expect(buildQueue(log).single.urgency, Urgency.p1);
  });

  test('nunca descarta un reporte: 100 reportes de todas las urgencias dan 100 elementos', () {
    const flagsByUrgency = [SituationFlags.dificultadRespiratoria, SituationFlags.atrapado, SituationFlags.viaBloqueada, 0];
    for (var i = 0; i < 100; i++) {
      // La cuarta clase es un texto que niega el peligro («sin heridos»): lo único que da P4.
      received(log, 'd$i-1', 0, flags: flagsByUrgency[i % 4], capturedAt: i, text: i % 4 == 3 ? 'sin heridos' : null);
    }
    final q = buildQueue(log);
    expect(q.length, 100);
    expect(q.map((i) => i.reportKey).toSet().length, 100);
    expect(q.first.urgency, Urgency.p1);
    expect(q.last.urgency, Urgency.p4);
  });

  test('un SOS sin banderas ni texto va en P3, no al final de la cola (sin datos no baja la urgencia)', () {
    received(log, 'aa-1', 0, flags: 0);
    received(log, 'bb-1', 0, flags: SituationFlags.viaBloqueada);
    final q = buildQueue(log);
    expect(q.map((i) => i.urgency), [Urgency.p3, Urgency.p3]);
  });

  test('toJson expone lo necesario para el tablero', () {
    received(log, 'aa-1', 0, flags: SituationFlags.atrapado, text: 'hola');
    final j = buildQueue(log).single.toJson();
    expect(j['reportKey'], 'aa-1');
    expect(j['urgency'], 'P2');
    expect(j['signals'], ['atrapado']);
    expect(j['text'], 'hola');
    expect(j.containsKey('receivedAt'), isTrue);
  });

  group('personas: se funden por revisión (la última que indica algo) y viajan en la cola', () {
    test('un reporte sin dato de personas queda «No indicado»', () {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado);
      final i = buildQueue(log).single;
      expect(i.people, 0);
      expect(i.peopleLabel, 'No indicado');
      expect(i.toJson()['people'], 0);
      expect(i.toJson()['peopleLabel'], 'No indicado');
    });

    test('las personas marcadas antes del SOS (rev 0) se muestran', () {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado, people: PeopleBucket.twoToFive.code);
      expect(buildQueue(log).single.peopleLabel, '2–5');
    });

    test('una revisión posterior que las indica reemplaza a la anterior (también si es una cifra MENOR: manda la última)', () {
      received(log, 'aa-1', 0, people: 3);
      received(log, 'aa-1', 1, people: 2);
      expect(buildQueue(log).single.people, 2);
    });

    test('una revisión que no indica personas (0) NO borra lo ya dicho', () {
      received(log, 'aa-1', 0, people: 4);
      received(log, 'aa-1', 1, flags: SituationFlags.herido);
      expect(buildQueue(log).single.peopleLabel, '21–100');
    });

    test('manda el orden de revisión, no el orden de llegada al log', () {
      received(log, 'aa-1', 2, people: 5);
      received(log, 'aa-1', 0, people: 1);
      received(log, 'aa-1', 1, people: 3);
      expect(buildQueue(log).single.people, 5);
    });

    test('un código reservado en una revisión posterior NO pisa un cajón válido anterior', () {
      received(log, 'aa-1', 0, people: 2);
      received(log, 'aa-1', 1, people: 6);
      expect(buildQueue(log).single.people, 2);
    });

    test('un código reservado (6, 7) o ausente se lee como «No indicado» y no rompe la cola', () {
      received(log, 'aa-1', 0, people: 7);
      expect(buildQueue(log).single.people, 0, reason: 'el código se descarta, no sólo su etiqueta');
      expect(buildQueue(log).single.peopleLabel, 'No indicado');
      log.append(
        'report.received',
        {'device_id': 'bb', 'flags': 0, 'incident_type': 1, 'loc_quality': 0, 'captured_at': 1000, 'received_at': 5000},
        reportKey: 'bb-1',
        rev: 0,
      );
      expect(buildQueue(log).firstWhere((i) => i.reportKey == 'bb-1').people, 0);
    });
  });

  group('evidence: por qué el sistema cree lo que cree (señal + campo o cita exacta del texto)', () {
    test('las banderas dan evidencia de campo estructurado', () {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido);
      final ev = buildQueue(log).single.evidence;
      expect(ev, containsAll([{'code': 'atrapado', 'field': 'flags.atrapado'}, {'code': 'herido', 'field': 'flags.herido'}]));
    });

    test('el texto da evidencia con la CITA exacta, que es subcadena del texto del reporte', () {
      const text = 'hay una persona atrapada bajo la losa';
      received(log, 'aa-1', 0, text: text);
      final i = buildQueue(log).single;
      final quotes = [for (final e in i.evidence) if (e["quote"] != null) e["quote"]!];
      expect(quotes, isNotEmpty, reason: 'el texto menciona a alguien atrapado');
      for (final q in quotes) {
        expect(text, contains(q));
      }
    });

    test('lo que el modelo aporta entra con su cita, sin repetir lo que las reglas ya dieron', () {
      const text = 'mi mamá no puede salir del segundo piso';
      final r = received(log, 'aa-1', 0, text: text);
      log.append(
        'triage.assessed',
        {
          'urgency': 'P2',
          'signals': ['atrapado'],
          'mode': 'rules+llm',
          'evidence': [
            {'code': 'atrapado', 'quote': 'no puede salir'},
          ],
          'confidence': 0.7,
          'uncertainty': <String>[],
          'escalate_to_human': false,
          'analyzed_text': text,
        },
        reportKey: 'aa-1',
        rev: 0,
        inputs: [r.id],
      );
      final ev = buildQueue(log).single.evidence;
      expect(ev.where((e) => e['code'] == 'atrapado' && e['quote'] == 'no puede salir'), hasLength(1));
      expect(ev.map(jsonEncode).toSet().length, ev.length, reason: 'sin duplicados');
    });

    test('si el modelo repite una cita que las reglas ya dieron, aparece UNA vez', () {
      const text = 'hay heridos en el edificio de la esquina';
      final r = received(log, 'aa-1', 0, text: text);
      final rulesOnly = buildQueue(log).single.evidence.where((e) => e['quote'] != null).toList();
      expect(rulesOnly, isNotEmpty, reason: 'las reglas leen «heridos»');
      for (var k = 0; k < 2; k++) {
        log.append(
          'triage.assessed',
          {
            'urgency': 'P2',
            'signals': ['herido'],
            'mode': 'rules+llm',
            'evidence': [
              {'code': rulesOnly.first['code'], 'quote': rulesOnly.first['quote']},
            ],
            'confidence': 0.7,
            'uncertainty': <String>[],
            'escalate_to_human': false,
            'analyzed_text': text,
          },
          reportKey: 'aa-1',
          rev: 0,
          inputs: [r.id],
        );
      }
      final ev = buildQueue(log).single.evidence;
      expect(ev.where((e) => e['quote'] == rulesOnly.first['quote'] && e['code'] == rulesOnly.first['code']), hasLength(1));
    });

    test('la evidencia que aporta el modelo se coloca en el orden canónico, no al final', () {
      const text = 'mi mamá no puede salir del segundo piso';
      final r = received(log, 'aa-1', 0, flags: SituationFlags.herido, text: text);
      log.append(
        'triage.assessed',
        {
          'urgency': 'P1',
          'signals': ['atrapado'],
          'mode': 'rules+llm',
          'evidence': [
            {'code': 'atrapado', 'quote': 'no puede salir'},
          ],
          'confidence': 0.7,
          'uncertainty': <String>[],
          'escalate_to_human': false,
          'analyzed_text': text,
        },
        reportKey: 'aa-1',
        rev: 0,
        inputs: [r.id],
      );
      final codes = buildQueue(log).single.evidence.map((e) => e['code']).toList();
      expect(codes.indexOf('atrapado'), lessThan(codes.indexOf('herido')), reason: 'atrapado va antes que herido en el orden canónico');
    });

    test('una cita del modelo que NO es subcadena del texto vigente se descarta (no se muestra una cita inventada)', () {
      const text = 'hay humo en la esquina';
      final r = received(log, 'aa-1', 0, text: text);
      log.append(
        'triage.assessed',
        {
          'urgency': 'P1',
          'signals': ['atrapado'],
          'mode': 'rules+llm',
          'evidence': [
            {'code': 'atrapado', 'quote': 'estamos atrapados'},
          ],
          'confidence': 0.9,
          'uncertainty': <String>[],
          'escalate_to_human': false,
          'analyzed_text': text,
        },
        reportKey: 'aa-1',
        rev: 0,
        inputs: [r.id],
      );
      final ev = buildQueue(log).single.evidence;
      expect(ev.where((e) => e['quote'] == 'estamos atrapados'), isEmpty);
    });

    test('el orden es canónico: el mismo contenido da la misma lista aunque cambie el orden de llegada', () {
      final other = EventLog.open(':memory:', nodeId: 'B');
      addTearDown(other.close);
      received(log, 'aa-1', 0, flags: SituationFlags.herido | SituationFlags.atrapado, text: 'atrapados y heridos');
      received(other, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido, text: 'atrapados y heridos');
      expect(buildQueue(log).single.evidence, buildQueue(other).single.evidence);
    });

    test('aparece en el JSON de la cola', () {
      received(log, 'aa-1', 0, flags: SituationFlags.atrapado);
      expect(buildQueue(log).single.toJson()['evidence'], isA<List<Object?>>());
    });
  });
}
