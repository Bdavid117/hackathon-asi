import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/models.dart';
import 'package:sard_dashboard/situation_panel.dart';
import 'package:sard_dashboard/theme.dart';

import 'fake_api.dart';

NodesStatus nodes({List<Map<String, Object?>> peers = const [], bool partial = false, List<String> reasons = const [], String self = 'A', int events = 43}) => NodesStatus.fromJson({
  'self': {'id': self, 'events': events, 'versionVector': {self: events}, 'uptimeMs': 1000},
  'peers': peers,
  'periodMs': 3000,
  'partialView': partial,
  'reasons': reasons,
});

Map<String, Object?> peer(String url, String state, {int? seen = 1200, int? sync = 1500, int? missing, String? error}) =>
    {'url': url, 'state': state, 'lastSeenAgoMs': seen, 'lastSyncAgoMs': sync, 'missingEvents': missing, 'lastError': error};

ResourceUnit unit(String id, {bool available = true, bool conflict = false}) => ResourceUnit(id: id, kind: 'ambulancia', label: id, lat: 5.07, lon: -75.51, available: available, conflict: conflict);

Future<void> pump(WidgetTester t, {NodesStatus? n, bool unknown = false, List<ResourceUnit> resources = const [], Size size = const Size(700, 900)}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: dashTheme(), home: Scaffold(body: SituationPanel(nodes: n, nodesUnknown: unknown, resources: resources))));
  await t.pump();
}

String textOf(WidgetTester t, String key) {
  final f = find.byKey(Key(key));
  final w = t.widget(f);
  String plain(Text e) => e.data ?? e.textSpan?.toPlainText() ?? '';
  if (w is Text) return plain(w);
  return t.widgetList<Text>(find.descendant(of: f, matching: find.byType(Text))).map(plain).join('\n');
}

void main() {
  group('peerName (cómo se nombra un par: con puerto, que dos nodos en la misma máquina no se confundan)', () {
    test('host y puerto; sin puerto, sólo el host; lo que no se entiende, tal cual', () {
      expect(peerName('http://localhost:8082'), 'localhost:8082');
      expect(peerName('http://nodo-b'), 'nodo-b');
      expect(peerName('http://192.168.1.20:8081/'), '192.168.1.20:8081');
      expect(peerName('no es una url'), 'no es una url');
      expect(peerName(''), '');
    });
  });

  group('el panel «Situación» (lo que se ve a la derecha mientras no hay un incidente elegido)', () {
    testWidgets('conserva la instrucción de elegir un incidente', (t) async {
      await pump(t, n: nodes());
      expect(textOf(t, 'situation_hint'), contains('Elige un incidente'));
    });

    testWidgets('dice qué nodo es éste y cuántos eventos tiene', (t) async {
      await pump(t, n: nodes(self: 'B', events: 128));
      expect(textOf(t, 'situation_self'), 'Nodo B (este) · 128 eventos');
    });

    testWidgets('sin pares lo dice SIN adornos: trabaja solo y si cae nadie más tiene sus reportes', (t) async {
      await pump(t, n: nodes());
      expect(textOf(t, 'situation_alone'), allOf(contains('Sin pares'), contains('trabaja solo'), contains('nadie más')));
      expect(find.byKey(const Key('situation_peer_0')), findsNothing);
    });

    testWidgets('cada par con su estado en palabras, su color y cuánto hace que se le vio', (t) async {
      await pump(t, n: nodes(peers: [peer('http://localhost:8082', 'sincronizado', seen: 2300), peer('http://localhost:8083', 'sin_respuesta', seen: 31600)]));
      expect(textOf(t, 'situation_peer_0'), 'localhost:8082: Sincronizado · hace 2 s');
      expect(textOf(t, 'situation_peer_1'), 'localhost:8083: Sin respuesta · hace 32 s');
      expect(find.byKey(const Key('situation_alone')), findsNothing, reason: 'con pares no se dice que trabaje solo');
      Color dot(int i) => t.widget<Icon>(find.byKey(Key('situation_peer_dot_$i'))).color!;
      expect(dot(0), DashColors.ok);
      expect(dot(1), DashColors.danger);
    });

    testWidgets('un par atrasado: amarillo, y dice cuántos eventos le faltan por traer', (t) async {
      await pump(t, n: nodes(peers: [peer('http://localhost:8082', 'atrasado', missing: 17)]));
      expect(textOf(t, 'situation_peer_0'), contains('Atrasado'));
      expect(textOf(t, 'situation_peer_0'), contains('faltan 17 eventos'));
      expect(t.widget<Icon>(find.byKey(const Key('situation_peer_dot_0'))).color, DashColors.warn);
    });

    testWidgets('el error del par se resume en palabras (sin el puerto efímero ni la pila), y el texto COMPLETO queda en el tooltip', (t) async {
      const raw = 'ClientException with SocketException: Connection refused (OS Error: Connection refused, errno = 61), address = localhost, port = 54857, uri=http://localhost:8081/api/events';
      await pump(t, n: nodes(peers: [peer('http://localhost:8081', 'sin_respuesta', error: raw)]));
      expect(textOf(t, 'situation_peer_0'), contains('conexión rechazada'));
      expect(textOf(t, 'situation_peer_0'), isNot(contains('54857')), reason: 'el puerto efímero de origen no le dice nada a nadie');
      expect(t.widget<Tooltip>(find.byKey(const Key('situation_peer_error_0'))).message, raw, reason: 'nada se esconde: el texto original sigue disponible');
    });

    test('peerErrorSummary: causas conocidas en palabras; lo desconocido, recortado y con puntos suspensivos; lo vacío, nada', () {
      expect(peerErrorSummary('SocketException: Connection refused'), 'conexión rechazada');
      expect(peerErrorSummary('TimeoutException after 0:00:02.000000'), 'sin respuesta a tiempo');
      expect(peerErrorSummary('Operation timed out'), 'sin respuesta a tiempo');
      expect(peerErrorSummary('SocketException: No route to host'), 'sin ruta hasta el nodo');
      expect(peerErrorSummary('SocketException: Network is unreachable'), 'sin ruta hasta el nodo');
      expect(peerErrorSummary('   algo raro   '), 'algo raro', reason: 'sin espacios sobrantes');
      expect(peerErrorSummary('Connection reset by peer'), 'conexión cortada');
      expect(peerErrorSummary('algo raro'), 'algo raro');
      final long = 'x' * 200;
      expect(peerErrorSummary(long), '${'x' * 60}…');
      expect(peerErrorSummary(''), '');
    });

    testWidgets('un par sin contacto todavía no trae hora: no se inventa un «hace 0 s»', (t) async {
      await pump(t, n: nodes(peers: [peer('http://localhost:8082', 'desconocido', seen: null, sync: null)]));
      expect(textOf(t, 'situation_peer_0'), 'localhost:8082: Sin contacto todavía');
    });

    testWidgets('vista parcial: sus razones en palabras', (t) async {
      await pump(t, n: nodes(peers: [peer('http://localhost:8082', 'sin_respuesta')], partial: true, reasons: ['par_sin_respuesta']));
      expect(textOf(t, 'situation_partial'), allOf(contains('Vista parcial'), contains('no responde')));
    });

    testWidgets('sin poder leer los nodos NO afirma nada sobre la red', (t) async {
      await pump(t, n: null, unknown: true);
      expect(find.byKey(const Key('situation_nodes_unknown')), findsOneWidget);
      expect(find.byKey(const Key('situation_alone')), findsNothing);
      expect(find.byKey(const Key('situation_self')), findsNothing);
    });

    testWidgets('mientras aún no se leyó nada (ni error) no se pinta una red vacía', (t) async {
      await pump(t, n: null);
      expect(find.byKey(const Key('situation_nodes_unknown')), findsNothing);
      expect(find.byKey(const Key('situation_alone')), findsNothing);
    });

    testWidgets('recursos: cuántas unidades, disponibles, no disponibles y en conflicto', (t) async {
      await pump(t, n: nodes(), resources: [unit('A1'), unit('A2'), unit('A3', available: false), unit('A4', available: false, conflict: true)]);
      expect(textOf(t, 'situation_resources'), '4 unidades · 2 disponibles · 1 no disponible · 1 en conflicto');
    });

    testWidgets('una unidad en conflicto NO cuenta como disponible (el nodo no la ofrece)', (t) async {
      await pump(t, n: nodes(), resources: [unit('A1', conflict: true)]);
      expect(textOf(t, 'situation_resources'), '1 unidad · 0 disponibles · 0 no disponibles · 1 en conflicto');
    });

    testWidgets('concordancia: una disponible y dos no disponibles', (t) async {
      await pump(t, n: nodes(), resources: [unit('A1'), unit('A2', available: false), unit('A3', available: false)]);
      expect(textOf(t, 'situation_resources'), '3 unidades · 1 disponible · 2 no disponibles · 0 en conflicto');
    });

    testWidgets('el conflicto se marca en rojo; sin conflicto, el texto normal', (t) async {
      await pump(t, n: nodes(), resources: [unit('A1', conflict: true)]);
      expect(t.widget<Text>(find.byKey(const Key('situation_resources'))).style!.color, DashColors.danger);
      await pump(t, n: nodes(), resources: [unit('A1')]);
      expect(t.widget<Text>(find.byKey(const Key('situation_resources'))).style!.color, DashColors.text);
    });

    testWidgets('sin unidades declaradas no hay tarjeta de recursos (no se afirma «ninguna»: puede ser un nodo anterior)', (t) async {
      await pump(t, n: nodes());
      expect(find.byKey(const Key('situation_resources')), findsNothing);
    });

    testWidgets('los tres principios con los que se lee el tablero', (t) async {
      await pump(t, n: nodes());
      final text = textOf(t, 'situation_principles');
      expect(text, contains('Nada se ejecuta solo'));
      expect(text, contains('no esconde nada'));
      expect(text, contains('El silencio no es seguridad'));
    });

    testWidgets('con poca altura se desplaza y no desborda', (t) async {
      await pump(t, n: nodes(peers: [peer('http://localhost:8082', 'atrasado', missing: 3, error: 'timeout')]), resources: [unit('A1')], size: const Size(420, 360));
      expect(t.takeException(), isNull);
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  group('en el tablero', () {
    Future<FakeApi> boot(WidgetTester t, {NodesStatus? n, Size size = const Size(1280, 900)}) async {
      final api = FakeApi();
      if (n != null) api.nodesStatus = n;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: DashboardScreen(api: api, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('en pantalla ancha, sin incidente elegido, a la derecha se ve la situación con los datos del nodo', (t) async {
      await boot(t, n: nodes(peers: [peer('http://localhost:8082', 'sincronizado')]));
      expect(find.byKey(const Key('detail_empty')), findsOneWidget);
      expect(find.byType(SituationPanel), findsOneWidget);
      expect(textOf(t, 'situation_peer_0'), startsWith('localhost:8082: Sincronizado'));
    });

    testWidgets('al elegir un incidente la situación se va y entra el detalle', (t) async {
      await boot(t);
      await t.tap(find.byKey(const Key('incident_00000000000000a1-1')));
      await t.pumpAndSettle();
      expect(find.byType(SituationPanel), findsNothing);
      expect(find.byKey(const Key('detail_panel')), findsOneWidget);
    });

    testWidgets('en pantalla estrecha no hay panel derecho: la situación no se pinta', (t) async {
      await boot(t, size: const Size(420, 900));
      expect(find.byType(SituationPanel), findsNothing);
    });
  });
}
