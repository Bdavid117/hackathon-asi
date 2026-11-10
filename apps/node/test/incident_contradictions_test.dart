import 'dart:convert';

import 'package:sard_node/sard_node.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

import 'log_support.dart';

const String t = 'puente colapsado calle veinte carros abajo';
const String t2 = 'puente colapsado calle veinte carros gente';
const String tNeg = 'puente colapsado calle veinte carros abajo sin heridos';

List<IncidentData> incidentsOf(EventLog log) {
  final items = buildQueue(log);
  return buildIncidents(items, approvals: const [], resources: testResources());
}

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('un incidente dice sus contradicciones (sin tocar nada más)', () {
    test('«sin heridos» en un reporte y «herido» marcado en otro del MISMO incidente: 1 contradicción, con el detalle', () {
      received(log, 'aa-1', 0, text: tNeg);
      received(log, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      final all = incidentsOf(log);
      expect(all, hasLength(1), reason: 'el montaje: los dos reportes forman un incidente');
      expect(all.single.summary['contradictions'], 1);
      final list = (all.single.detail['contradictions']! as List).cast<Map>();
      expect(list.single, {'kind': 'negacion', 'code': 'herido', 'a': 'aa-1', 'b': 'bb-1'});
    });

    test('sin contradicciones: 0 y una lista vacía (no «no evaluadas»: ahora sí se evalúan)', () {
      received(log, 'aa-1', 0, text: t, flags: SituationFlags.atrapado);
      received(log, 'bb-1', 0, text: t2, lat: 5.0704, flags: SituationFlags.atrapado);
      final i = incidentsOf(log).single;
      expect(i.summary['contradictions'], 0);
      expect(i.detail['contradictions'], isEmpty);
    });

    test('cantidades de personas incompatibles en el mismo incidente', () {
      received(log, 'aa-1', 0, text: t, people: PeopleBucket.one.code);
      received(log, 'bb-1', 0, text: t2, lat: 5.0704, people: PeopleBucket.sixToTwenty.code);
      final i = incidentsOf(log).single;
      expect(i.summary['contradictions'], 1);
      expect((i.detail['contradictions']! as List).cast<Map>().single['kind'], 'personas');
    });

    test('un incidente de un solo reporte no tiene contradicciones (no hay con quién)', () {
      received(log, 'aa-1', 0, text: 'sin heridos', flags: SituationFlags.herido);
      expect(incidentsOf(log).single.summary['contradictions'], 0);
    });

    test('NO cambia la urgencia, ni «a revisar», ni la incertidumbre alta: sólo se señala', () {
      received(log, 'aa-1', 0, text: tNeg);
      received(log, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      final withContradiction = incidentsOf(log).single;
      final plain = EventLog.open(':memory:', nodeId: 'B');
      received(plain, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      final alone = incidentsOf(plain).single;
      plain.close();
      expect(withContradiction.urgency, alone.urgency, reason: 'el que niega no baja la urgencia del que afirma');
      expect(withContradiction.summary['needsReview'], alone.summary['needsReview']);
      expect(withContradiction.summary['highUncertainty'], alone.summary['highUncertainty']);
    });

    test('dos nodos con los mismos reportes en otro orden dicen lo mismo (proyección pura)', () {
      final other = EventLog.open(':memory:', nodeId: 'B');
      received(log, 'aa-1', 0, text: tNeg);
      received(log, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      received(other, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      received(other, 'aa-1', 0, text: tNeg);
      expect(jsonEncode(incidentsOf(log).single.detail['contradictions']), jsonEncode(incidentsOf(other).single.detail['contradictions']));
      other.close();
    });
  });

  group('contadores: sobre el total', () {
    test('cuántos incidentes tienen alguna contradicción', () {
      received(log, 'aa-1', 0, text: tNeg);
      received(log, 'bb-1', 0, text: t, lat: 5.0704, flags: SituationFlags.herido);
      received(log, 'cc-1', 0, text: 'otro suceso lejos de aquí totalmente distinto', lat: 5.2, lon: -75.3);
      final ix = IncidentIndex.build(incidentsOf(log));
      final c = (jsonDecode(ix.page())['counters']! as Map).cast<String, Object?>();
      expect(c['withContradictions'], 1);
      expect(c['incidents'], 2);
    });
  });
}
