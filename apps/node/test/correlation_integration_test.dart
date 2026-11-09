import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

const String t = 'puente colapsado calle veinte carros abajo';

/// Parecido pero no copia (5 de 7 palabras): se agrupa con [t] sin ser una copia suya.
const String t2 = 'puente colapsado calle veinte carros gente';

/// Un `report.received` con el cuerpo que produce `Ingest`.
Event rec(
  EventLog log,
  String key,
  int rev, {
  String? device,
  int flags = 0,
  double? lat = 5.07,
  double? lon = -75.51,
  int locQuality = 2,
  String? text = t,
  int capturedAt = 1786370851,
  int type = 1,
}) => log.append(
  'report.received',
  {
    'device_id': device ?? key.split('-').first,
    'frame_seq': rev + 1,
    'flags': flags,
    'incident_type': type,
    'loc_quality': lat == null ? 0 : locQuality,
    'lat': lat,
    'lon': lon,
    'text': text,
    'captured_at': capturedAt,
    'received_at': 5000,
  },
  reportKey: key,
  rev: rev,
);

QueueItem item(List<QueueItem> q, String key) => q.firstWhere((i) => i.reportKey == key);

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('el grupo se calcula al leer, sobre los reportes fusionados', () {
    test('dos dispositivos, mismo lugar, hora y texto: un solo grupo con 2 fuentes independientes', () {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701, text: t2);
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, item(q, 'bb-1').group);
      expect(item(q, 'aa-1').groupSize, 2);
      expect(item(q, 'aa-1').sources, 2);
      expect(item(q, 'aa-1').confidence, closeTo(1 - 0.4 * 0.4, 1e-9));
    });

    test('textos IDÉNTICOS de dos dispositivos son una copia: un solo grupo pero una sola fuente independiente', () {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      final it = item(buildQueue(log), 'aa-1');
      expect(it.groupSize, 2);
      expect(it.sources, 1);
      expect(it.uncertainty, contains('fuente_no_independiente'));
    });

    test('uno lejano queda en su propio grupo, con una sola fuente', () {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.2);
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, isNot(item(q, 'bb-1').group));
      expect(item(q, 'bb-1').groupSize, 1);
      expect(item(q, 'bb-1').sources, 1);
      expect(item(q, 'bb-1').uncertainty, contains('fuente_unica'));
    });

    test('la urgencia del grupo es la más grave de sus miembros; la del reporte, la suya', () {
      rec(log, 'aa-1', 0, flags: SituationFlags.atrapado | SituationFlags.herido);
      rec(log, 'bb-1', 0, flags: 0);
      final q = buildQueue(log);
      expect(item(q, 'bb-1').urgency, Urgency.p3, reason: 'su propio triaje no cambia');
      expect(item(q, 'bb-1').groupUrgency, Urgency.p1, reason: 'pero su grupo se muestra P1');
      expect(item(q, 'aa-1').groupUrgency, Urgency.p1);
    });

    test('ningún reporte desaparece de la cola ni de los grupos', () {
      final r = Random(4);
      for (var i = 0; i < 40; i++) {
        rec(log, 'd$i-1', 0, lat: 5.07 + (i % 4) * 0.2, text: i.isEven ? t : 'otro texto $i', capturedAt: 1786370851 + r.nextInt(600));
      }
      final q = buildQueue(log);
      expect(q.length, 40);
      expect(q.map((i) => i.reportKey).toSet().length, 40);
      expect(q.every((i) => i.groupSize >= 1), isTrue);
    });

    test('un reporte sin texto ni ubicación recibe la incertidumbre de lo que le falta', () {
      rec(log, 'aa-1', 0, lat: null, text: null);
      final it = buildQueue(log).single;
      expect(it.escalate, isTrue);
      expect(it.uncertainty, containsAll(['sin_detalle', 'ubicacion_ausente']));
      expect(it.urgency, Urgency.p3);
    });
  });

  group('replicación y revisiones', () {
    test('dos nodos aislados con un reporte cada uno: tras replicar, AMBAS colas muestran un solo grupo, el mismo', () {
      final a = EventLog.open(':memory:', nodeId: 'A');
      final b = EventLog.open(':memory:', nodeId: 'B');
      addTearDown(() {
        a.close();
        b.close();
      });
      rec(a, 'aa-1', 0);
      rec(b, 'bb-1', 0, lat: 5.0701);
      // aislados: cada uno ve sólo lo suyo
      expect(buildQueue(a).single.groupSize, 1);
      expect(buildQueue(b).single.groupSize, 1);
      for (final e in a.all()) {
        b.appendReplicated(e);
      }
      for (final e in b.all()) {
        a.appendReplicated(e);
      }
      final qa = buildQueue(a), qb = buildQueue(b);
      expect(qa.length, 2);
      expect(item(qa, 'aa-1').group, item(qa, 'bb-1').group);
      expect(item(qb, 'aa-1').group, item(qa, 'aa-1').group, reason: 'el mismo identificador de grupo en los dos nodos');
      expect(item(qa, 'aa-1').groupSize, 2);
      expect(item(qb, 'aa-1').groupSize, 2);
    });

    test('un reporte sin ubicación cuya revisión con GPS llega después se une a su grupo', () {
      rec(log, 'aa-1', 0, lat: null, text: null);
      rec(log, 'bb-1', 0);
      var q = buildQueue(log);
      expect(item(q, 'aa-1').group, isNot(item(q, 'bb-1').group));
      rec(log, 'aa-1', 1, lat: 5.0701, text: t); // llega la revisión con ubicación y texto
      q = buildQueue(log);
      expect(item(q, 'aa-1').group, item(q, 'bb-1').group);
      expect(q.length, 2);
    });

    test('el orden en que llegan las revisiones no cambia el grupo', () {
      rec(log, 'bb-1', 0);
      rec(log, 'aa-1', 1, lat: 5.0701, text: t);
      rec(log, 'aa-1', 0, lat: null, text: null);
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, item(q, 'bb-1').group);
    });

    test('los incident.linked del log son auditoría: ni agrupan ni desagrupan', () {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.3); // lejos: no deberían agruparse
      log.append(
        'incident.linked',
        {'links': [{'other': 'bb-1', 'state': 'same', 'score': 0.99}]},
        reportKey: 'aa-1',
        rev: 0,
      );
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, isNot(item(q, 'bb-1').group), reason: 'un vínculo anotado a mano no fuerza un grupo');
    });
  });

  group('sugerencias: lo `possible` no agrupa pero se muestra', () {
    test('mismo lugar y hora sin texto: grupos distintos, y cada uno sugiere al otro', () {
      rec(log, 'aa-1', 0, text: null);
      rec(log, 'bb-1', 0, text: null, lat: 5.0701);
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, isNot(item(q, 'bb-1').group));
      expect(item(q, 'aa-1').similar, ['bb-1']);
      expect(item(q, 'bb-1').similar, ['aa-1']);
    });

    test('lo ya agrupado no se repite como sugerencia', () {
      rec(log, 'aa-1', 0);
      rec(log, 'bb-1', 0, lat: 5.0701);
      expect(item(buildQueue(log), 'aa-1').similar, isEmpty);
    });
  });

  group('un reporte de poca evidencia no une dos sucesos lejanos, pero los sugiere', () {
    test('un reporte sin ubicación con el texto de dos sucesos lejanos: ellos no se fusionan y él los sugiere', () {
      rec(log, 'aa-1', 0, lat: 5.07, locQuality: 1);
      rec(log, 'bb-1', 0, lat: 5.27, locQuality: 1); // ~22 km al norte
      rec(log, 'uu-1', 0, lat: null);
      final q = buildQueue(log);
      expect(item(q, 'aa-1').group, isNot(item(q, 'bb-1').group), reason: 'sin puentes');
      final u = item(q, 'uu-1');
      expect(u.group, anyOf(item(q, 'aa-1').group, item(q, 'bb-1').group), reason: 'se sumó a uno');
      final other = u.group == item(q, 'aa-1').group ? 'bb-1' : 'aa-1';
      expect(u.similar, contains(other), reason: 'el vínculo frenado se muestra como sugerencia');
    });
  });

  test('toJson expone grupo, fuentes, confianza, incertidumbre, escalado y sugerencias', () {
    rec(log, 'aa-1', 0, flags: SituationFlags.atrapado);
    final j = buildQueue(log).single.toJson();
    for (final k in ['group', 'groupSize', 'groupUrgency', 'sources', 'confidence', 'uncertainty', 'escalate', 'similar']) {
      expect(j.containsKey(k), isTrue, reason: k);
    }
    expect(j['groupUrgency'], 'P2');
  });
}
