import 'package:sard_node/sard_node.dart';
import 'package:test/test.dart';

import 'log_support.dart';

const String t = 'puente colapsado calle veinte carros abajo';
const String t2 = 'puente colapsado calle veinte carros gente';

// Los índices de LocQuality en la red: 1 = ±10 m, 2 = ±50 m, 3 = ±200 m, 4 = ±1 km, 5 = más de 1 km.

IncidentData only(EventLog log) {
  final items = buildQueue(log);
  final all = buildIncidents(items, approvals: readApprovals([...log.allOfType('approval.granted'), ...log.allOfType('approval.denied')]), resources: testResources());
  return all.single;
}

void main() {
  late EventLog log;
  setUp(() => log = EventLog.open(':memory:', nodeId: 'A'));
  tearDown(() => log.close());

  group('la fila de un incidente dice qué tan precisa es su ubicación (para que el mapa no finja exactitud)', () {
    test('un reporte con ±10 m: «within10m»', () {
      received(log, 'aa-1', 0, text: t, locQuality: 1);
      expect(only(log).summary['locQuality'], 'within10m');
    });

    test('cada calidad con coordenadas tiene su nombre', () {
      final names = {1: 'within10m', 2: 'within50m', 3: 'within200m', 4: 'within1km', 5: 'over1km'};
      for (final e in names.entries) {
        final l = EventLog.open(':memory:', nodeId: 'N${e.key}');
        received(l, 'aa-1', 0, text: t, locQuality: e.key);
        expect(only(l).summary['locQuality'], e.value, reason: 'calidad ${e.key}');
        l.close();
      }
    });

    test('con dos reportes el incidente muestra la PEOR precisión, no la mejor ni la del último', () {
      received(log, 'aa-1', 0, text: t, locQuality: 1);
      received(log, 'bb-1', 0, text: t2, lat: 5.0704, locQuality: 4);
      final s = only(log).summary;
      expect(s['size'], 2, reason: 'el escenario es un solo incidente');
      expect(s['locQuality'], 'within1km');
    });

    test('el orden en que llegan no cambia el resultado', () {
      received(log, 'aa-1', 0, text: t, locQuality: 4);
      received(log, 'bb-1', 0, text: t2, lat: 5.0704, locQuality: 1);
      expect(only(log).summary['locQuality'], 'within1km');
    });

    test('«más de 1 km» es peor que «±1 km»', () {
      received(log, 'aa-1', 0, text: t, locQuality: 5);
      received(log, 'bb-1', 0, text: t2, lat: 5.0704, locQuality: 4);
      expect(only(log).summary['locQuality'], 'over1km');
    });

    test('sin ubicación no hay calidad que mostrar', () {
      received(log, 'aa-1', 0, text: t, lat: null, lon: null, locQuality: 0);
      final s = only(log).summary;
      expect(s['lat'], isNull);
      expect(s['locQuality'], isNull);
    });

    test('una calidad «none» con coordenadas no se presenta como una calidad', () {
      received(log, 'aa-1', 0, text: t, locQuality: 0);
      expect(only(log).summary['locQuality'], isNull);
    });

    test('la cola del nodo (/api/queue) también la dice, y sólo si hay ubicación', () {
      received(log, 'aa-1', 0, text: t, locQuality: 3);
      received(log, 'bb-1', 0, text: 'otro sitio distinto muy lejos de aquí', lat: null, lon: null, locQuality: 0);
      final q = {for (final i in buildQueue(log)) i.reportKey: i.toJson()};
      expect(q['aa-1']!['locQuality'], 'within200m');
      expect(q['bb-1']!['locQuality'], isNull);
    });

    test('un reporte sin ubicación forma su propio incidente y no le pone calidad al localizado', () {
      received(log, 'aa-1', 0, text: t, locQuality: 2);
      received(log, 'bb-1', 0, text: t2, lat: null, lon: null, locQuality: 0);
      final items = buildQueue(log);
      final all = buildIncidents(items, approvals: const [], resources: testResources());
      final byId = {for (final i in all) i.summary['id']! as String: i.summary};
      expect(byId.keys, {'aa-1', 'bb-1'}, reason: 'sin ubicación no se funde con el localizado');
      expect(byId['aa-1']!['locQuality'], 'within50m');
      expect(byId['bb-1']!['locQuality'], isNull);
    });
  });
}
