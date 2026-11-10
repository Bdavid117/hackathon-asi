import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'log_support.dart';

/// Un incidente de [n] miembros (cada uno con su recepción, normalización y triaje) y el detalle que lo describe, tal como lo serviría el nodo.
({EventLog log, QueueService service, QueueRead read, String id, List<String> keys}) incidentOf(int n) {
  final log = EventLog.open(':memory:', nodeId: 'A');
  final keys = <String>[];
  for (var i = 0; i < n; i++) {
    final k = 'd${i.toRadixString(16).padLeft(6, '0')}-1';
    keys.add(k);
    received(log, k, 0, text: 'TEXTO', receivedAt: 5000 + i);
    log.append('report.normalized', {'missing': <String>[], 'text': 'TEXTO'}, reportKey: k, rev: 0);
    log.append('triage.assessed', {'urgency': 'P2', 'mode': 'rules', 'agent_version': 'rules-1', 'analyzed_text': 'TEXTO'}, reportKey: k, rev: 0);
  }
  final detail = {
    'id': keys.first,
    'members': keys,
    'membersTotal': n,
    'sources': 1,
    'contradictions': <Object>[],
    'recommendation': {'state': 'propuesta', 'id': 'rec-1', 'actions': ['enviar_rescate'], 'pending': <String>[], 'resourceIds': ['AMB-01']},
  };
  final read = QueueRead('[]', details: {keys.first: jsonEncode(detail)}, stale: false, ageMs: 0);
  return (log: log, service: QueueService(log, resources: testResources()), read: read, id: keys.first, keys: keys);
}

Map<String, Object?> historyOf(({EventLog log, QueueService service, QueueRead read, String id, List<String> keys}) i) =>
    ((jsonDecode(i.service.detailWithHistory(i.read, i.id)!) as Map)['history'] as Map).cast<String, Object?>();

void main() {
  group('el coste de la historia de un incidente tiene tope (medido: 64 ms con 2 000 miembros y 316 ms con 10 000, cada vez que se pide el detalle)', () {
    test('hasta el tope se leen TODOS los miembros y la historia lo dice', () {
      final i = incidentOf(25);
      addTearDown(i.log.close);
      final h = historyOf(i);
      expect((h['membersRead'], h['membersTotal']), (25, 25));
    });

    test('justo en el tope se leen todos; con uno más, se lee el tope y se dice cuántos hay', () {
      final exact = incidentOf(kHistoryMemberCap);
      addTearDown(exact.log.close);
      expect((historyOf(exact)['membersRead'], historyOf(exact)['membersTotal']), (kHistoryMemberCap, kHistoryMemberCap));
      final over = incidentOf(kHistoryMemberCap + 1);
      addTearDown(over.log.close);
      expect((historyOf(over)['membersRead'], historyOf(over)['membersTotal']), (kHistoryMemberCap, kHistoryMemberCap + 1));
    });

    test('no se consultan los eventos de los miembros más allá del tope: lo que sólo ellos aportan no está en la historia', () {
      final i = incidentOf(kHistoryMemberCap + 20);
      addTearDown(i.log.close);
      // Un evento propio de un miembro DESPUÉS del tope (uno que sí cuenta como paso): si se leyera, la historia tendría un paso más.
      final base = historyOf(i)['stepsTotal'] as int;
      final beyond = i.keys[kHistoryMemberCap + 5];
      i.log.append('incident.linked', {'links': <Object>[]}, reportKey: beyond, rev: 0);
      expect(historyOf(i)['stepsTotal'], base, reason: 'un miembro fuera del tope no aporta pasos');
      // y el mismo evento en un miembro DENTRO del tope sí cuenta
      i.log.append('incident.linked', {'links': <Object>[]}, reportKey: i.keys[3], rev: 0);
      expect(historyOf(i)['stepsTotal'], greaterThan(base), reason: 'uno dentro del tope sí aporta');
    });

    test('el tope no cambia lo demás: el detalle sigue trayendo todos sus miembros y su total', () {
      final i = incidentOf(kHistoryMemberCap + 10);
      addTearDown(i.log.close);
      final detail = (jsonDecode(i.service.detailWithHistory(i.read, i.id)!) as Map).cast<String, Object?>();
      expect((detail['members'] as List), hasLength(kHistoryMemberCap + 10));
      expect(detail['membersTotal'], kHistoryMemberCap + 10);
    });
  });
}
