import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

void main() {
  group('IncidentsPage (contrato con el nodo real)', () {
    final page = IncidentsPage.fromJson(fixture('incidents_short.json'));

    test('el sobre: vista, total y contadores', () {
      expect(page.view, 'short');
      expect(page.total, 5);
      final c = page.counters;
      expect(c.incidents, 8);
      expect(c.reports, 9);
      expect(c.byUrgency, {'P1': 1, 'P2': 1, 'P3': 6, 'P4': 0});
      expect(c.bareSos, 3);
      expect(c.highUncertainty, 1);
      expect(c.needsReview, 1);
      expect(c.inShortView, 5);
      expect(c.followUp, 0);
    });

    test('la fila agregada de SOS sin detalle', () {
      final b = page.bare!;
      expect(b.count, 3);
      expect(b.sampleIds, hasLength(3));
      expect(b.newestAt, greaterThan(b.oldestAt));
    });

    test('las filas: orden, urgencia, señales, personas, ubicación y recomendación', () {
      expect(page.items.map((i) => i.urgency), ['P1', 'P2', 'P3', 'P3', 'P3']);
      final p1 = page.items.first;
      expect(p1.signals, ['atrapado', 'herido']);
      expect(p1.peopleLabel, '2–5');
      expect(p1.hasLocation, isTrue);
      expect(p1.sources, 1);
      expect(p1.recommendation.state, 'propuesta');
      expect(p1.recommendation.actions, ['rescate', 'atencion_medica']);
      expect(p1.recommendation.resourceIds, ['RES-01', 'AMB-01']);
      expect(p1.approval.status, 'aprobada');
      expect(p1.approval.decisions, 1, reason: 'cuenta las decisiones vigentes');
    });

    test('un incendio sin ubicación: lo dice y la incertidumbre es alta', () {
      final fire = page.items.firstWhere((i) => i.signals.contains('incendio'));
      expect(fire.hasLocation, isFalse);
      expect(fire.highUncertainty, isTrue);
      expect(fire.urgency, 'P2');
    });

    test('un texto que las reglas no entienden pide revisión', () {
      expect(page.items.where((i) => i.needsReview), hasLength(1));
    });

    test('la vista completa y los SOS sin detalle parsean igual', () {
      final all = IncidentsPage.fromJson(fixture('incidents_all.json'));
      expect(all.view, 'all');
      expect(all.items, hasLength(8));
      expect(all.bare, isNull);
      final bare = IncidentsPage.fromJson(fixture('incidents_bare.json'));
      expect(bare.items.every((i) => i.bareSos), isTrue);
      expect(bare.items, hasLength(3));
    });

    test('la frescura se anota aparte de lo que sirvió el nodo', () {
      final p = IncidentsPage.fromJson(fixture('incidents_short.json'), stale: true, ageMs: 4200);
      expect(p.stale, isTrue);
      expect(p.ageMs, 4200);
    });
  });

  group('IncidentDetail', () {
    final d = IncidentDetail.fromJson(fixture('detail_p1_approved.json'));

    test('encabezado: el mismo resumen que la fila', () {
      expect(d.row.id, '00000000000000a1-1');
      expect(d.row.urgency, 'P1');
    });

    test('observaciones originales con texto, personas e indicadores', () {
      final m = d.members.single;
      expect(m.reportKey, '00000000000000a1-1');
      expect(m.text, contains('no puede salir'));
      expect(m.peopleLabel, '2–5');
      expect(m.hasLocation, isTrue);
    });

    test('evidencia: campo estructurado o cita exacta, con el reporte', () {
      expect(d.evidence, isNotEmpty);
      final e = d.evidence.firstWhere((x) => x.code == 'atrapado');
      expect(e.field, 'flags.atrapado');
      expect(e.reportKey, '00000000000000a1-1');
    });

    test('recomendación: acciones, recursos con etiqueta y distancia, justificación, requisitos y aprobación humana', () {
      final r = d.recommendation;
      expect(r.state, 'propuesta');
      expect(r.requiresApproval, isTrue);
      expect(r.resources.map((x) => x.id), ['RES-01', 'AMB-01']);
      expect(r.resources.first.label, 'Rescate estructural 1');
      expect(r.resources.first.distanceMeters, 442);
      expect(r.justification.any((c) => c.signal == 'ubicacion'), isTrue);
      expect(r.pending, ['confirmar_segunda_fuente']);
      expect(r.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('aprobación: estado, quién decidió y su nota', () {
      final a = d.approval;
      expect(a.status, 'aprobada');
      expect(a.discrepancy, isFalse);
      expect(a.current.single.who, 'Ana Gómez');
      expect(a.current.single.granted, isTrue);
      expect(a.current.single.note, contains('rescate'));
      expect(a.stale, isEmpty);
    });

    test('un incendio sin ubicación: información requerida, sin recursos ni botones de decisión', () {
      final f = IncidentDetail.fromJson(fixture('detail_fire_no_location.json'));
      expect(f.recommendation.state, 'informacion_requerida');
      expect(f.recommendation.missing, ['ubicacion']);
      expect(f.recommendation.canDecide, isFalse);
    });

    test('un SOS sin detalle: información requerida de la situación', () {
      final b = IncidentDetail.fromJson(fixture('detail_bare.json'));
      expect(b.recommendation.missing, ['situacion']);
      expect(b.row.bareSos, isTrue);
    });

    test('canDecide sólo con una propuesta', () {
      expect(d.recommendation.canDecide, isTrue);
    });
  });

  group('NodesStatus', () {
    test('un nodo solo: sin pares y sin vista parcial', () {
      final n = NodesStatus.fromJson(fixture('nodes.json'));
      expect(n.selfId, 'A');
      expect(n.peers, isEmpty);
      expect(n.partialView, isFalse);
    });

    test('con pares: estado, hace cuánto y los motivos de la vista parcial', () {
      final n = NodesStatus.fromJson({
        'self': {'id': 'A', 'events': 10, 'versionVector': {'A': 10}, 'uptimeMs': 5},
        'peers': [
          {'url': 'http://b', 'state': 'sincronizado', 'lastSeenAgoMs': 2000, 'lastSyncAgoMs': 2000, 'missingEvents': 0, 'lastError': null},
          {'url': 'http://c', 'state': 'sin_respuesta', 'lastSeenAgoMs': 40000, 'lastSyncAgoMs': null, 'missingEvents': 5, 'lastError': 'tiempo agotado'},
        ],
        'periodMs': 3000,
        'partialView': true,
        'reasons': ['par_sin_respuesta'],
      });
      expect(n.peers.map((p) => p.state), ['sincronizado', 'sin_respuesta']);
      expect(n.peers.last.lastError, 'tiempo agotado');
      expect(n.peers.last.lastSyncAgoMs, isNull);
      expect(n.partialView, isTrue);
      expect(n.reasons, ['par_sin_respuesta']);
    });
  });

  group('lo que el nodo no debería mandar no se traga en silencio', () {
    test('un sobre sin «items» o con tipos equivocados lanza FormatException', () {
      expect(() => IncidentsPage.fromJson({'view': 'short'}), throwsFormatException);
      expect(() => IncidentsPage.fromJson({...fixture('incidents_short.json'), 'items': 'no'}), throwsFormatException);
      expect(() => IncidentsPage.fromJson({...fixture('incidents_short.json'), 'counters': null}), throwsFormatException);
    });

    test('una urgencia desconocida NO se esconde como P4: lanza', () {
      final j = fixture('incidents_short.json');
      final bad = {...j, 'items': [{...(j['items']! as List).first as Map<String, Object?>, 'urgency': 'P9'}]};
      expect(() => IncidentsPage.fromJson(bad), throwsFormatException);
    });

    test('una fila sin identificador lanza', () {
      final j = fixture('incidents_short.json');
      final bad = {...j, 'items': [{...(j['items']! as List).first as Map<String, Object?>}..remove('id')]};
      expect(() => IncidentsPage.fromJson(bad), throwsFormatException);
    });

    test('una propuesta que NO exige aprobación humana se rechaza: el tablero nunca la muestra como decidible', () {
      final j = fixture('detail_p1_approved.json');
      final rec = {...(j['recommendation']! as Map<String, Object?>), 'requires_approval': false};
      expect(() => IncidentDetail.fromJson({...j, 'recommendation': rec}), throwsFormatException);
      final missing = {...(j['recommendation']! as Map<String, Object?>)}..remove('requires_approval');
      expect(() => IncidentDetail.fromJson({...j, 'recommendation': missing}), throwsFormatException);
    });

    test('un estado de recomendación o de aprobación desconocido lanza (no se inventa un valor por omisión)', () {
      final j = fixture('detail_p1_approved.json');
      expect(() => IncidentDetail.fromJson({...j, 'recommendation': {...(j['recommendation']! as Map<String, Object?>), 'state': 'aprobada_sola'}}), throwsFormatException);
      expect(() => IncidentDetail.fromJson({...j, 'approval': {...(j['approval']! as Map<String, Object?>), 'status': 'quizas'}}), throwsFormatException);
    });

    test('un detalle sin recomendación lanza', () {
      expect(() => IncidentDetail.fromJson({...fixture('detail_pair.json')}..remove('recommendation')), throwsFormatException);
    });
  });

  group('etiquetas en español (nunca rompen con un código nuevo)', () {
    test('«mensaje_cortado» se dice como lo que es: una duda, no una afirmación', () {
      expect(uncertaintyLabel('mensaje_cortado'), 'Posible mensaje cortado');
    });

    test('señales', () {
      expect(signalLabel('atrapado'), 'Atrapado');
      expect(signalLabel('dificultad_respiratoria'), 'Dificultad para respirar');
      expect(signalLabel('via_bloqueada'), 'Vía bloqueada');
      expect(signalLabel('codigo_futuro_raro'), 'Codigo futuro raro');
    });

    test('incertidumbre', () {
      expect(uncertaintyLabel('ubicacion_ausente'), 'Sin ubicación');
      expect(uncertaintyLabel('fuente_unica'), 'Fuente única');
      expect(uncertaintyLabel('texto_no_interpretado'), 'Texto no interpretado');
      expect(uncertaintyLabel('otra_cosa'), 'Otra cosa');
    });

    test('acciones, requisitos pendientes e información requerida', () {
      expect(actionLabel('rescate'), 'Enviar rescate');
      expect(actionLabel('despejar_via'), 'Despejar la vía');
      expect(pendingLabel('confirmar_segunda_fuente'), 'Confirmar con una segunda fuente');
      expect(pendingLabel('sin_recurso_disponible:ambulancia'), 'No hay ambulancia disponible');
      expect(missingLabel('ubicacion'), 'la ubicación');
      expect(missingLabel('situacion'), 'qué está pasando (indicadores o un texto)');
    });

    test('estado de la aprobación y de los nodos', () {
      expect(approvalLabel('pendiente'), 'Pendiente de decisión');
      expect(approvalLabel('aprobada'), 'Aprobada');
      expect(approvalLabel('denegada'), 'Rechazada');
      expect(approvalLabel('caduca'), 'Caducada: el incidente cambió');
      expect(peerStateLabel('sincronizado'), 'Sincronizado');
      expect(peerStateLabel('desconocido'), 'Sin contacto todavía');
      expect(peerStateLabel('sin_respuesta'), 'Sin respuesta');
      expect(peerStateLabel('atrasado'), 'Atrasado');
    });

    test('motivos de la vista parcial', () {
      expect(partialReasonLabel('par_desconocido'), contains('todavía no se ha hablado'));
      expect(partialReasonLabel('par_sin_respuesta'), contains('no responde'));
      expect(partialReasonLabel('faltan_eventos'), contains('faltan eventos'));
    });
  });

  group('tiempo', () {
    test('clockLabel muestra la hora local de unos segundos de época', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1786370851 * 1000).toLocal();
      expect(clockLabel(1786370851), '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
    });

    test('ageLabel: segundos, minutos, horas; un reloj adelantado no da negativos', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1786370851 * 1000 + 90000);
      expect(ageLabel(1786370851, now), 'hace 1 min');
      expect(ageLabel(1786370851 + 85, now), 'hace 5 s');
      expect(ageLabel(1786370851 - 7200, now), 'hace 2 h');
      expect(ageLabel(1786370851 + 99999, now), 'ahora mismo');
      // pasado un día se cuenta en días (no «hace 2174 h»)
      expect(ageLabel(1786370851 - 23 * 3600, now), 'hace 23 h');
      expect(ageLabel(1786370851 - 24 * 3600, now), 'hace 1 d');
      expect(ageLabel(1786370851 - 3 * 86400 - 5, now), 'hace 3 d');
    });
  });
}
