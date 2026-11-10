import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/dashboard_screen.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

/// El canal del despachador en el tablero: el formulario «Registrar informe», lo que envía al nodo y cómo se ve un
/// informe de segunda mano entre las observaciones. Lo que se envía se comprueba contra el MISMO literal que lee la
/// prueba del nodo (`apps/node/test/fixtures/dispatch_request.json`): un `FakeApi` no demuestra que el JSON coincida.
final Uri base = Uri.parse('http://nodo:8081');

Map<String, Object?> radioMember({String key = 'desp-a1b2c3d4e5f6', String medium = 'telefono', String? origin = 'Estación 3', int people = 0}) => {
  'reportKey': key,
  'urgency': 'P2',
  'rev': 0,
  'flags': 0,
  'lat': null,
  'lon': null,
  'text': 'hay gente atrapada en el segundo piso',
  'people': people,
  'peopleLabel': people == 0 ? 'No indicado' : '2–5',
  'evidence': <Object?>[],
  'capturedAt': 1786370851,
  'receivedAt': 1786370851000,
  'signals': ['atrapado'],
  'group': key,
  'groupSize': 1,
  'groupUrgency': 'P2',
  'sources': 1,
  'confidence': 0.2,
  'uncertainty': ['fuente_unica', 'ubicacion_ausente'],
  'escalate': false,
  'similar': <Object?>[],
  'source': 'radio',
  'medium': medium,
  'origin': origin,
  'registeredBy': 'Ana Gómez',
};

void main() {
  group('Observation: lee la fuente (y un nodo que no la manda es «app»)', () {
    test('un miembro sin source (un nodo anterior) se lee como de la app, sin medio, origen ni registrador', () {
      final m = (fixture('detail_p1_approved.json')['observations']! as List).first as Map<String, Object?>;
      expect(m.containsKey('source'), isFalse);
      final o = Observation.fromJson(m);
      expect(o.source, 'app');
      expect(o.isDispatch, isFalse);
      expect(o.medium, isNull);
      expect(o.origin, isNull);
      expect(o.registeredBy, isNull);
    });

    test('un informe de despachador trae medio, origen y quién lo registró', () {
      final o = Observation.fromJson(radioMember());
      expect(o.source, 'radio');
      expect(o.isDispatch, isTrue);
      expect(o.medium, 'telefono');
      expect(o.origin, 'Estación 3');
      expect(o.registeredBy, 'Ana Gómez');
    });

    test('«fuentes no independientes» tiene etiqueta propia en español', () {
      expect(uncertaintyLabel('fuente_no_independiente'), 'Fuentes no independientes');
    });
  });

  group('la fila de la lista dice de dónde viene el incidente', () {
    Map<String, Object?> filaJson({int? fromDispatch, int size = 1}) {
      final j = fixture('incidents_short.json');
      final item = Map<String, Object?>.from((j['items']! as List).first as Map);
      return {...item, 'size': size, 'fromDispatch': ?fromDispatch};
    }

    test('un nodo que no manda fromDispatch (uno anterior) se lee como 0: ninguna marca', () {
      expect(IncidentRow.fromJson(filaJson()).fromDispatch, 0);
      expect(IncidentRow.fromJson(filaJson()).isSecondHand, isFalse);
      expect(IncidentRow.fromJson(filaJson()).hasDispatch, isFalse);
    });

    test('todo el grupo de despachador = de segunda mano; sólo una parte = «incluye» un informe', () {
      final todo = IncidentRow.fromJson(filaJson(fromDispatch: 2, size: 2));
      expect(todo.isSecondHand, isTrue);
      expect(todo.hasDispatch, isTrue);
      final parte = IncidentRow.fromJson(filaJson(fromDispatch: 1, size: 3));
      expect(parte.isSecondHand, isFalse);
      expect(parte.hasDispatch, isTrue);
    });

    test('un valor de otro tipo se lee como 0 (no rompe la lista)', () {
      expect(IncidentRow.fromJson({...filaJson(), 'fromDispatch': 'dos'}).fromDispatch, 0);
      expect(IncidentRow.fromJson({...filaJson(), 'fromDispatch': -3}).fromDispatch, 0);
    });

    Future<void> mostrar(WidgetTester tester, Map<String, Object?> fila) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final j = fixture('incidents_short.json');
      final page = IncidentsPage.fromJson({...j, 'items': [fila]});
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: FakeApi(short: page), every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
    }

    testWidgets('la tarjeta de un incidente SÓLO de informes dice «De segunda mano»', (tester) async {
      await mostrar(tester, filaJson(fromDispatch: 1, size: 1));
      expect(find.text('De segunda mano'), findsOneWidget);
      expect(find.text('Incluye informe de despachador'), findsNothing);
    });

    testWidgets('la de un grupo MIXTO dice «Incluye informe de despachador» (la app no se tapa)', (tester) async {
      await mostrar(tester, filaJson(fromDispatch: 1, size: 2));
      expect(find.text('Incluye informe de despachador'), findsOneWidget);
      expect(find.text('De segunda mano'), findsNothing);
    });

    testWidgets('un incidente de la app no lleva ninguna de las dos marcas', (tester) async {
      await mostrar(tester, filaJson(fromDispatch: 0));
      expect(find.text('De segunda mano'), findsNothing);
      expect(find.text('Incluye informe de despachador'), findsNothing);
    });
  });

  group('HttpDashboardApi.dispatch (contrato con el nodo)', () {
    final literal = jsonDecode(File('../node/test/fixtures/dispatch_request.json').readAsStringSync()) as Map<String, Object?>;

    Future<http.Request> enviar({String? code, int status = 200, String body = '{"id":"x"}', String? origin = 'Estación Bomberos 3'}) async {
      late http.Request seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r;
        return http.Response.bytes(utf8.encode(body), status); // como el nodo: UTF-8
      }), base);
      api.accessCode = code;
      await api.dispatch(
        id: 'a1b2c3d4e5f6a7b8',
        text: 'edificio con gente atrapada en la carrera 23, mensaje cortado',
        medium: 'telefono',
        who: 'Ana Gómez',
        origin: origin,
        flags: ['atrapado', 'herido'],
        people: 2,
        lat: literal['lat']! as double,
        lon: literal['lon']! as double,
      );
      return seen;
    }

    test('envía POST /api/dispatch con content-type JSON y EXACTAMENTE el cuerpo que el nodo espera', () async {
      final r = await enviar();
      expect(r.method, 'POST');
      expect(r.url.path, '/api/dispatch');
      expect(r.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(r.body), literal);
    });

    test('con código de acceso lo manda como Bearer; sin él, no manda cabecera', () async {
      expect((await enviar(code: 'coord-2026')).headers['authorization'], 'Bearer coord-2026');
      expect((await enviar()).headers.containsKey('authorization'), isFalse);
    });

    test('un cuerpo de error que NO es UTF-8 (un proxy) sigue siendo un rechazo con su estado, no otra excepción', () async {
      final api = HttpDashboardApi(MockClient((r) async => http.Response.bytes([0xff, 0xfe, 0x41], 502)), base);
      await expectLater(
        api.dispatch(id: 'a1b2c3d4e5f6a7b8', text: 'x', medium: 'radio', who: 'Ana'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 502)),
      );
    });

    test('un origen vacío o ausente NO viaja (el nodo lo toma como «sin origen»)', () async {
      expect((jsonDecode((await enviar(origin: null)).body) as Map).containsKey('origin'), isFalse);
      expect((jsonDecode((await enviar(origin: '  ')).body) as Map).containsKey('origin'), isFalse);
    });

    test('401 es «falta el código»; cualquier otro estado es un fallo del nodo con su motivo (y NO se da por registrado)', () async {
      await expectLater(enviar(status: 401), throwsA(isA<AccessDenied>()));
      await expectLater(enviar(status: 400, body: 'text no puede estar vacío'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 400).having((e) => e.message, 'message', contains('text'))));
      await expectLater(enviar(status: 409, body: 'el id ya se usó'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 409)));
      await expectLater(enviar(status: 500, body: 'x'), throwsA(isA<ApiException>()));
    });
  });

  group('el formulario «Registrar informe»', () {
    Future<FakeApi> boot(WidgetTester tester, {FakeApi? api, Size size = const Size(1280, 900)}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final a = api ?? FakeApi();
      await tester.pumpWidget(MaterialApp(home: DashboardScreen(api: a, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000))));
      await tester.pumpAndSettle();
      return a;
    }

    Future<void> abrir(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('dispatch_open')));
      await tester.pumpAndSettle();
    }

    Future<void> escribir(WidgetTester tester, String key, String text) async {
      await tester.enterText(find.byKey(Key(key)), text);
      await tester.pump();
    }

    Future<void> tocar(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }

    Future<void> enviar(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('send_dispatch')));
      await tester.pumpAndSettle();
    }

    testWidgets('el botón de la barra abre el formulario, con «Radio» ya marcado (lo más común) y los campos a la vista', (tester) async {
      await boot(tester);
      await abrir(tester);
      expect(find.byKey(const Key('dispatch_dialog')), findsOneWidget);
      for (final k in ['dispatch_text', 'dispatch_origin', 'dispatch_who', 'medium_radio', 'medium_telefono', 'medium_presencial', 'send_dispatch', 'cancel_dispatch', 'flag_atrapado', 'people_2']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('medium_radio'))).selected, isTrue);
      expect(find.textContaining('segunda mano'), findsWidgets, reason: 'se dice qué es: información de segunda mano');
    });

    testWidgets('la introducción NO dice que el informe queda «sin ubicación»: la ubicación es opcional y se escribe a mano (hay campos para ella)', (tester) async {
      await boot(tester);
      await abrir(tester);
      expect(find.byKey(const Key('dispatch_lat')), findsOneWidget, reason: 'el montaje: el formulario admite coordenadas');
      expect(find.textContaining('queda registrada sin ubicación'), findsNothing);
      final intro = find.byKey(const Key('dispatch_intro'));
      expect(intro, findsOneWidget);
      final text = tester.widget<Text>(intro).data!;
      expect(text, contains('ubicación es opcional'));
      expect(text, contains('escrita a mano'));
    });

    testWidgets('sin texto no se envía: dice qué falta y NO llama al nodo; sin nombre, tampoco', (tester) async {
      final api = await boot(tester);
      await abrir(tester);
      await enviar(tester);
      expect(find.byKey(const Key('dispatch_text_error')), findsOneWidget);
      expect(api.of('dispatch'), isEmpty);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await enviar(tester);
      expect(find.byKey(const Key('dispatch_who_error')), findsOneWidget);
      expect(api.of('dispatch'), isEmpty);
      expect(find.byKey(const Key('dispatch_dialog')), findsOneWidget);
    });

    testWidgets('un informe válido llama al nodo con lo escrito, cierra, avisa que quedó registrado y recarga la lista', (tester) async {
      final api = await boot(tester);
      final antes = api.of('incidents').length;
      await abrir(tester);
      await escribir(tester, 'dispatch_text', '  hay gente atrapada en el segundo piso  ');
      await escribir(tester, 'dispatch_who', 'Ana Gómez');
      await enviar(tester);
      final c = api.of('dispatch').single.args;
      expect(c['text'], 'hay gente atrapada en el segundo piso');
      expect(c['who'], 'Ana Gómez');
      expect(c['medium'], 'radio');
      expect(c['origin'], isNull);
      expect(c['flags'], isEmpty);
      expect(c['people'], 0);
      expect(c['id'] as String, matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')), reason: 'el id que el nodo acepta');
      expect(find.byKey(const Key('dispatch_dialog')), findsNothing);
      expect(find.textContaining('Informe registrado'), findsOneWidget);
      expect(api.of('incidents').length, greaterThan(antes), reason: 'recarga la lista para que el informe aparezca');
    });

    testWidgets('medio, origen, banderas y personas marcados viajan tal cual; marcar dos veces una bandera la quita; un rango de personas se deselecciona', (tester) async {
      final api = await boot(tester);
      await abrir(tester);
      await tocar(tester, 'medium_telefono');
      await tocar(tester, 'flag_atrapado');
      await tocar(tester, 'flag_herido');
      await tocar(tester, 'flag_incendio');
      await tocar(tester, 'flag_incendio'); // la quita
      await tocar(tester, 'people_3');
      await tocar(tester, 'people_3'); // la deselecciona
      await tocar(tester, 'people_2');
      await escribir(tester, 'dispatch_text', 'edificio caído');
      await escribir(tester, 'dispatch_origin', '  Estación 3 ');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      final c = api.of('dispatch').single.args;
      expect(c['medium'], 'telefono');
      expect((c['flags']! as List).toSet(), {'atrapado', 'herido'});
      expect(c['people'], 2);
      expect(c['origin'], 'Estación 3');
    });

    testWidgets('el nombre se recuerda para el siguiente informe (y el de las aprobaciones es el mismo)', (tester) async {
      await boot(tester);
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'uno');
      await escribir(tester, 'dispatch_who', 'Ana Gómez');
      await enviar(tester);
      await abrir(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('dispatch_who'))).controller!.text, 'Ana Gómez');
    });

    testWidgets('el texto admite 500 caracteres y el nombre 80: lo que sobra no se puede escribir', (tester) async {
      await boot(tester);
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'a' * 600);
      await escribir(tester, 'dispatch_who', 'b' * 100);
      expect(tester.widget<TextField>(find.byKey(const Key('dispatch_text'))).controller!.text.length, 500);
      expect(tester.widget<TextField>(find.byKey(const Key('dispatch_who'))).controller!.text.length, 80);
    });

    testWidgets('un rechazo del nodo muestra su motivo, NO cierra y NO avisa de registro', (tester) async {
      final api = await boot(tester, api: FakeApi()..failDispatch = const ApiException(400, 'text no puede estar vacío'));
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      expect(find.byKey(const Key('dispatch_dialog')), findsOneWidget);
      expect(find.byKey(const Key('dispatch_error')), findsOneWidget);
      expect(find.textContaining('text no puede estar vacío'), findsOneWidget);
      expect(find.textContaining('NO quedó registrado'), findsOneWidget);
      expect(find.textContaining('Informe registrado'), findsNothing);
      expect(api.of('dispatch'), hasLength(1));
    });

    testWidgets('sin red: lo dice, el informe NO quedó registrado y se puede reintentar', (tester) async {
      final api = await boot(tester, api: FakeApi()..failDispatch = http.ClientException('sin red'));
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      expect(find.textContaining('No se pudo contactar al nodo'), findsOneWidget);
      expect(find.textContaining('NO quedó registrado'), findsOneWidget);
      api.failDispatch = null;
      await enviar(tester);
      expect(find.byKey(const Key('dispatch_dialog')), findsNothing);
      expect(api.of('dispatch'), hasLength(2));
    });

    testWidgets('si el nodo no acepta el código de acceso, lo dice y no da el informe por registrado', (tester) async {
      await boot(tester, api: FakeApi()..failDispatch = const AccessDenied());
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      expect(find.textContaining('código de acceso'), findsOneWidget);
      expect(find.textContaining('NO quedó registrado'), findsOneWidget);
    });

    testWidgets('REINTENTO con lo mismo reusa el id (el nodo no duplica); si se EDITA algo, el id es otro (no choca con un 409)', (tester) async {
      final api = await boot(tester, api: FakeApi()..failDispatch = http.ClientException('sin red'));
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      await enviar(tester); // mismo contenido
      await escribir(tester, 'dispatch_text', 'hay humo en la calle 5'); // otro contenido
      await enviar(tester);
      final ids = [for (final c in api.of('dispatch')) c.args['id'] as String];
      expect(ids, hasLength(3));
      expect(ids[1], ids[0], reason: 'mismo contenido = mismo id');
      expect(ids[2], isNot(ids[0]), reason: 'contenido distinto = id nuevo');
    });

    testWidgets('tras un 409 (el id ya se usó con otro contenido) el siguiente intento, aun con lo mismo, lleva un id NUEVO', (tester) async {
      final api = await boot(tester, api: FakeApi()..failDispatch = const ApiException(409, 'el id ya se usó con otro contenido'));
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await enviar(tester);
      expect(find.textContaining('409'), findsOneWidget);
      api.failDispatch = null;
      await enviar(tester);
      final ids = [for (final c in api.of('dispatch')) c.args['id'] as String];
      expect(ids, hasLength(2));
      expect(ids[1], isNot(ids[0]));
      expect(find.byKey(const Key('dispatch_dialog')), findsNothing);
    });

    testWidgets('un informe NUEVO tras uno registrado lleva un id nuevo', (tester) async {
      final api = await boot(tester);
      for (final t in ['uno', 'uno']) {
        await abrir(tester);
        await escribir(tester, 'dispatch_text', t);
        await escribir(tester, 'dispatch_who', 'Ana');
        await enviar(tester);
      }
      final ids = {for (final c in api.of('dispatch')) c.args['id'] as String};
      expect(ids, hasLength(2), reason: 'dos informes iguales registrados a propósito son dos informes');
    });

    testWidgets('mientras se envía, un segundo toque NO manda otro informe', (tester) async {
      final gate = Completer<void>();
      final api = await boot(tester, api: FakeApi()..holdDispatch = gate);
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await escribir(tester, 'dispatch_who', 'Ana');
      await tester.tap(find.byKey(const Key('send_dispatch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send_dispatch')), warnIfMissed: false);
      await tester.pump();
      expect(api.of('dispatch'), hasLength(1));
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.of('dispatch'), hasLength(1));
      expect(find.byKey(const Key('dispatch_dialog')), findsNothing);
    });

    testWidgets('Cancelar cierra sin llamar al nodo', (tester) async {
      final api = await boot(tester);
      await abrir(tester);
      await escribir(tester, 'dispatch_text', 'hay humo');
      await tester.tap(find.byKey(const Key('cancel_dispatch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dispatch_dialog')), findsNothing);
      expect(api.of('dispatch'), isEmpty);
    });

    for (final w in [320.0, 360.0, 420.0, 700.0, 1280.0]) {
      testWidgets('a $w px de ancho la barra con el botón y el formulario abierto no desbordan', (tester) async {
        await boot(tester, size: Size(w, 800));
        expect(find.byKey(const Key('dispatch_open')), findsOneWidget);
        // Ancho: el botón dice lo que hace; estrecho: sólo el ícono (con su explicación), para no quitarle sitio al título.
        if (w >= 700) {
          expect(find.widgetWithText(TextButton, 'Registrar informe'), findsOneWidget);
        } else {
          expect(find.widgetWithText(TextButton, 'Registrar informe'), findsNothing);
          expect(tester.widget<IconButton>(find.byKey(const Key('dispatch_open'))).tooltip, 'Registrar informe');
        }
        expect(tester.takeException(), isNull);
        await abrir(tester);
        expect(find.byKey(const Key('dispatch_dialog')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('con el nodo pidiendo código no hay botón de registrar (sólo la pantalla de acceso)', (tester) async {
      await boot(tester, api: FakeApi()..requireCode = 'coord-2026');
      expect(find.byKey(const Key('access_prompt')), findsOneWidget);
      expect(find.byKey(const Key('dispatch_open')), findsNothing);
    });
  });

  group('un informe entre las observaciones originales', () {
    IncidentDetail conInforme({String medium = 'telefono', String? origin = 'Estación 3', int people = 0}) {
      final j = fixture('detail_p1_approved.json');
      return IncidentDetail.fromJson({
        ...j,
        'observations': [radioMember(medium: medium, origin: origin, people: people)],
        'membersTotal': 1,
      });
    }

    Future<void> mostrar(WidgetTester tester, IncidentDetail d) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      const p1 = '00000000000000a1-1';
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: FakeApi(details: {p1: d}), id: p1, every: null, who: ValueNotifier('')))));
      await tester.pumpAndSettle();
    }

    testWidgets('dice que es un informe de segunda mano: por qué medio, la hora de REGISTRO, quién lo registró, el origen y que no tiene ubicación', (tester) async {
      await mostrar(tester, conInforme());
      final h = tester.widget<Text>(find.byKey(const Key('obs_header_desp-a1b2c3d4e5f6'))).data!;
      expect(h, contains('Informe por teléfono'));
      expect(h, contains('registrado ${clockLabel(1786370851)}'));
      expect(h, contains('por Ana Gómez'));
      expect(h, contains('origen: Estación 3'));
      expect(h, contains('sin ubicación'));
      expect(h, isNot(contains('Reporte desp-')), reason: 'no se muestra la clave interna como si fuera un reporte de la app');
    });

    testWidgets('el medio cambia la etiqueta; sin origen no se inventa uno; con personas marcadas se dicen', (tester) async {
      await mostrar(tester, conInforme(medium: 'presencial', origin: null, people: 2));
      final h = tester.widget<Text>(find.byKey(const Key('obs_header_desp-a1b2c3d4e5f6'))).data!;
      expect(h, contains('Informe en persona'));
      expect(h, isNot(contains('origen')));
      expect(h, contains('2–5 personas'));
    });

    testWidgets('el texto del informe se ve igual que el de cualquier observación', (tester) async {
      await mostrar(tester, conInforme());
      expect(find.textContaining('«hay gente atrapada en el segundo piso»'), findsOneWidget);
    });

    IncidentDetail conEvidencia({required String key}) {
      final j = fixture('detail_p1_approved.json');
      final rec = Map<String, Object?>.from(j['recommendation']! as Map);
      return IncidentDetail.fromJson({
        ...j,
        'observations': [radioMember(key: key)],
        'membersTotal': 1,
        'evidence': [
          {'reportKey': key, 'code': 'atrapado', 'field': 'flags.atrapado'},
          {'reportKey': key, 'code': 'herido', 'quote': 'gritos en el segundo piso'},
        ],
        'recommendation': {
          ...rec,
          'justification': [
            {'signal': 'atrapado', 'report_key': key, 'field': 'flags.atrapado'},
            {'signal': 'herido', 'report_key': key, 'quote': 'gritos'},
          ],
        },
      });
    }

    testWidgets('«Por qué esta prioridad» nombra al informe por su medio y por quién lo registró, NO por su clave interna', (tester) async {
      await mostrar(tester, conEvidencia(key: 'desp-a1b2c3d4e5f6'));
      final why = find.byKey(const Key('why_section'));
      expect(find.descendant(of: why, matching: find.textContaining('indicador marcado en el informe por teléfono de Ana Gómez', findRichText: true)), findsOneWidget);
      expect(find.descendant(of: why, matching: find.textContaining('«gritos en el segundo piso» en el texto del informe por teléfono de Ana Gómez', findRichText: true)), findsOneWidget);
      expect(find.descendant(of: why, matching: find.textContaining('desp-', findRichText: true)), findsNothing);
    });

    testWidgets('«En qué se apoya» de la recomendación tampoco enseña la clave interna de un informe', (tester) async {
      await mostrar(tester, conEvidencia(key: 'desp-a1b2c3d4e5f6'));
      expect(find.textContaining('(informe por teléfono de Ana Gómez)'), findsWidgets);
      expect(find.textContaining('(desp-'), findsNothing);
    });

    testWidgets('si el informe no está entre las observaciones cargadas, igual no se enseña la clave: «un informe de despachador»', (tester) async {
      final j = fixture('detail_p1_approved.json');
      final d = IncidentDetail.fromJson({
        ...j,
        'evidence': [{'reportKey': 'desp-zzzz', 'code': 'atrapado', 'field': 'flags.atrapado'}],
      });
      await mostrar(tester, d);
      final why = find.byKey(const Key('why_section'));
      expect(find.descendant(of: why, matching: find.textContaining('indicador marcado en el informe de un despachador', findRichText: true)), findsOneWidget);
    });

    testWidgets('la evidencia de un reporte de la app sigue nombrándolo por su clave, como siempre', (tester) async {
      await mostrar(tester, p1Detail());
      final why = find.byKey(const Key('why_section'));
      expect(find.descendant(of: why, matching: find.textContaining('indicador marcado en el reporte 00000000000000a1-1', findRichText: true)), findsWidgets);
    });

    testWidgets('una observación de la app NO cambia: «Reporte <clave> · hora»', (tester) async {
      await mostrar(tester, p1Detail());
      final h = tester.widget<Text>(find.byKey(const Key('obs_header_00000000000000a1-1'))).data!;
      expect(h, startsWith('Reporte 00000000000000a1-1 · '));
      expect(h, isNot(contains('Informe')));
    });
  });
}
