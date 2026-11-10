import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

/// El escenario ampliado de `seed_scenario --extended` enseña lo último del tablero: si el nodo cambia y deja de producirlo, el
/// guion de la demostración se queda sin sus casos y nadie se entera hasta ensayar. Se prueba contra un nodo REAL.
void main() {
  // Arrancar un nodo real (`dart run`, JIT) tarda de 3 a 10 s y, con toda la batería de sim en paralelo, más: cada prueba arranca SÓLO
  // los nodos que necesita y tiene un plazo holgado (el de 30 s por omisión venció una vez con dos nodos y la máquina cargada).
  const patient = Timeout(Duration(minutes: 3));
  late Directory dir;
  late NodeProcess node;
  late http.Client client;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-extended-');
    client = http.Client();
  });
  tearDown(() {
    client.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> startNode() async {
    final recursos = File('${dir.path}/recursos.json')..writeAsStringSync(jsonEncode({'resources': _resources}));
    node = await NodeProcess.start(id: 'A', port: await freePort(), dataDir: '${dir.path}/A', extraArgs: ['--resources', recursos.path]);
    addTearDown(node.kill9);
  }

  Future<Map<String, Object?>> incidents() async => (jsonDecode(utf8.decode((await client.get(node.url.resolve('/api/incidents?view=all'))).bodyBytes)) as Map).cast<String, Object?>();
  Future<List<Map<String, Object?>>> units() async => ((jsonDecode((await client.get(node.url.resolve('/api/resources'))).body) as Map)['resources']! as List).cast<Map<String, Object?>>();
  List<Map<String, Object?>> items(Map<String, Object?> page) => (page['items']! as List).cast<Map<String, Object?>>();
  List<Object?> pending(Map<String, Object?> i) => ((i['recommendation'] as Map?)?['pending'] as List?) ?? const [];

  test('el escenario fijo SOLO no trae ninguno de los tres casos (para que la prueba mida lo que añade --extended)', timeout: patient, () async {
    await startNode();
    await postScenario(node.url, client);
    final page = await incidents();
    expect((page['counters']! as Map)['withContradictions'], 0);
    expect([for (final i in items(page)) if (pending(i).contains('confirmar_ruta')) i], isEmpty);
    expect([for (final u in await units()) if (u['id'] == 'AMB-02') u['available']].single, isTrue);
  });

  test('con --extended hay UNA contradicción, la propuesta del P1 pide confirmar la ruta y la ambulancia 2 no está disponible', timeout: patient, () async {
    await startNode();
    await postScenario(node.url, client);
    await postExtendedScenario(node.url, client);
    final page = await incidents();
    expect((page['counters']! as Map)['withContradictions'], 1);
    final p1 = items(page).firstWhere((i) => i['urgency'] == 'P1');
    expect(pending(p1), contains('confirmar_ruta'));
    expect([for (final u in await units()) if (u['id'] == 'AMB-02') u['available']].single, isFalse);
  });

  test('un nodo que exige código: sin él la declaración del recurso se rechaza (el escenario lo dice, no lo traga), y con él pasa', timeout: patient, () async {
    final guarded = await NodeProcess.start(
      id: 'B',
      port: await freePort(),
      dataDir: '${dir.path}/B',
      environment: {'SARD_COORDINATOR_TOKEN': 'coord-2026', ...Platform.environment},
    );
    addTearDown(guarded.kill9);
    await postScenario(guarded.url, client);
    await expectLater(postExtendedScenario(guarded.url, client), throwsA(isA<StateError>()));
    await postExtendedScenario(guarded.url, client, code: 'coord-2026');
  });
}

const _resources = [
  {'id': 'AMB-01', 'kind': 'ambulancia', 'label': 'Ambulancia 1 · Base Centro', 'lat': 5.0689, 'lon': -75.5174, 'available': true},
  {'id': 'AMB-02', 'kind': 'ambulancia', 'label': 'Ambulancia 2 · Base Chipre', 'lat': 5.0603, 'lon': -75.5071, 'available': true},
];
