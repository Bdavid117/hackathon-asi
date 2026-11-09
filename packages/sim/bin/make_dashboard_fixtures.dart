// Genera las respuestas REALES del nodo que usa el tablero en sus pruebas de contrato:
//   dart run packages/sim/bin/make_dashboard_fixtures.dart [--out apps/dashboard/test/fixtures] [--port 8098]
// Arranca un nodo, le envía un escenario fijo (un P1 con texto, un grupo de dos reportes, SOS sin
// detalle, un reporte sin ubicación, uno que no se entiende y una aprobación) y guarda lo que sirven
// /api/incidents (corta y completa), /api/incidents/<id> (varios) y /api/nodes.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    o[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final out = Directory(o['out'] ?? 'apps/dashboard/test/fixtures')..createSync(recursive: true);
  final port = int.parse(o['port'] ?? '8098');
  final dir = Directory.systemTemp.createTempSync('sard-fixtures-');
  final repo = File.fromUri(Platform.script).parent.parent.parent.parent.path;
  final node = await NodeProcess.start(id: 'A', port: port, dataDir: dir.path, extraArgs: ['--resources', '$repo/config/recursos.json']);
  final client = http.Client();
  await postScenario(node.url, client);
  try {
    String fetch(String path) => path;
    Future<http.Response> get(String path) => client.get(node.url.resolve(fetch(path)));
    await Future<void>.delayed(const Duration(seconds: 1));

    final all = jsonDecode((await get('/api/incidents?view=all&limit=1000')).body) as Map;
    final items = (all['items'] as List).cast<Map<String, Object?>>();
    final p1 = items.firstWhere((i) => i['urgency'] == 'P1');
    final pair = items.firstWhere((i) => (i['size'] as int) == 2, orElse: () => items.first);
    final fire = items.firstWhere((i) => (i['signals'] as List).contains('incendio'));

    // una persona aprueba la recomendación del P1
    final detail1 = jsonDecode((await get('/api/incidents/${Uri.encodeComponent(p1['id']! as String)}')).body) as Map;
    final approval = await client.post(
      node.url.resolve('/api/approval'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'recommendationId': (detail1['recommendation'] as Map)['id'],
        'incidentId': p1['id'],
        'members': (detail1['members'] as List).cast<String>(),
        'decision': 'granted',
        'note': 'Visto con el equipo; sale el rescate.',
        'who': 'Ana Gómez',
      }),
    );
    if (approval.statusCode != 200) throw StateError('no se pudo registrar la aprobación: ${approval.statusCode}');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    void save(String name, String body) {
      File('${out.path}/$name').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(jsonDecode(body)));
      stdout.writeln('· $name');
    }

    save('incidents_short.json', (await get('/api/incidents')).body);
    save('incidents_all.json', (await get('/api/incidents?view=all&limit=1000')).body);
    save('incidents_bare.json', (await get('/api/incidents?view=all&bare=true')).body);
    save('detail_p1_approved.json', (await get('/api/incidents/${Uri.encodeComponent(p1['id']! as String)}')).body);
    save('detail_pair.json', (await get('/api/incidents/${Uri.encodeComponent(pair['id']! as String)}')).body);
    save('detail_fire_no_location.json', (await get('/api/incidents/${Uri.encodeComponent(fire['id']! as String)}')).body);
    final bare = items.firstWhere((i) => i['bareSos'] == true);
    save('detail_bare.json', (await get('/api/incidents/${Uri.encodeComponent(bare['id']! as String)}')).body);
    save('nodes.json', (await get('/api/nodes')).body);
    stdout.writeln('${items.length} incidentes; P1=${p1['id']}');
  } finally {
    await node.stop();
    client.close();
    dir.deleteSync(recursive: true);
  }
}
