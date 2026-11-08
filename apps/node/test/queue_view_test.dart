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
}) =>
    log.append(
      'report.received',
      {
        'device_id': reportKey.split('-').first,
        'frame_seq': rev + 1,
        'flags': flags,
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
      received(log, 'd$i-1', 0, flags: flagsByUrgency[i % 4], capturedAt: i);
    }
    final q = buildQueue(log);
    expect(q.length, 100);
    expect(q.map((i) => i.reportKey).toSet().length, 100);
    expect(q.first.urgency, Urgency.p1);
    expect(q.last.urgency, Urgency.p4);
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
}
