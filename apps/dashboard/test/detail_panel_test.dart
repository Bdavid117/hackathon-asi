import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/detail_panel.dart';
import 'package:sard_dashboard/models.dart';

import 'fake_api.dart';

IncidentDetail detail(String file) => IncidentDetail.fromJson(fixture(file));

/// El incidente P1 del escenario, pero con la aprobación en el estado pedido.
IncidentDetail p1With({String status = 'pendiente', bool discrepancy = false, List<Map<String, Object?>> current = const [], List<Map<String, Object?>> stale = const [], Map<String, Object?>? recommendation, List<Map<String, Object?>> shared = const []}) {
  final j = fixture('detail_p1_approved.json');
  return IncidentDetail.fromJson({
    ...j,
    'approval': {'status': status, 'discrepancy': discrepancy, 'current': current, 'stale': stale},
    if (recommendation != null) 'recommendation': {...(j['recommendation']! as Map<String, Object?>), ...recommendation},
    'sharedResources': shared,
  });
}

Map<String, Object?> decision(String eventId, {bool granted = true, String who = 'Ana Gómez', String note = ''}) => {
  'eventId': eventId,
  'recommendationId': '3fa8370868b2c56c',
  'incidentId': '00000000000000a1-1',
  'decision': granted ? 'granted' : 'denied',
  'note': note,
  'who': who,
  'at': 1794196929674,
  'supersedes': <String>[],
};

const String p1 = '00000000000000a1-1';

void main() {
  Future<FakeApi> boot(WidgetTester tester, IncidentDetail d, {void Function(FakeApi api)? tweak, ValueNotifier<String>? who}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    final api = FakeApi(details: {p1: d});
    tweak?.call(api);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: p1, every: null, clock: () => DateTime.fromMillisecondsSinceEpoch(1786371100 * 1000), who: who ?? ValueNotifier<String>('')))));
    await tester.pumpAndSettle();
    return api;
  }

  group('por qué esta prioridad', () {
    testWidgets('las señales con su evidencia: el indicador marcado o la cita exacta, y el reporte', (tester) async {
      await boot(tester, p1With());
      final why = find.byKey(const Key('why_section'));
      expect(find.descendant(of: why, matching: find.textContaining('Atrapado')), findsWidgets);
      expect(find.descendant(of: why, matching: find.textContaining('indicador')), findsWidgets);
    });

    testWidgets('una cita del texto se muestra entre comillas con la señal que sugiere', (tester) async {
      final j = fixture('detail_pair.json');
      final d = IncidentDetail.fromJson({
        ...j,
        'evidence': [
          {'reportKey': (j['members']! as List).first, 'code': 'atrapado', 'quote': 'no puede salir'},
        ],
      });
      await boot(tester, d);
      expect(find.descendant(of: find.byKey(const Key('why_section')), matching: find.textContaining('«no puede salir»')), findsOneWidget);
    });

    testWidgets('la incertidumbre se lista y se dice que las contradicciones entre reportes no se evalúan', (tester) async {
      await boot(tester, p1With());
      expect(find.descendant(of: find.byKey(const Key('why_section')), matching: find.text('Fuente única')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('why_section')), matching: find.textContaining('Contradicciones entre reportes: no evaluadas')), findsOneWidget);
    });
  });

  group('observaciones originales', () {
    testWidgets('cada reporte con su texto, personas, hora y ubicación', (tester) async {
      await boot(tester, p1With());
      final obs = find.byKey(const Key('observations_section'));
      expect(find.descendant(of: obs, matching: find.textContaining('no puede salir del segundo piso')), findsOneWidget);
      expect(find.descendant(of: obs, matching: find.textContaining('2–5 personas')), findsOneWidget);
      expect(find.descendant(of: obs, matching: find.textContaining('00000000000000a1-1')), findsOneWidget);
    });

    testWidgets('un incidente de varios reportes los lista todos', (tester) async {
      await boot(tester, detail('detail_pair.json'), tweak: (api) => api.details = {p1: detail('detail_pair.json')});
      expect(find.descendant(of: find.byKey(const Key('observations_section')), matching: find.textContaining('Reporte ')), findsNWidgets(2));
    });
  });

  group('recomendación', () {
    testWidgets('una propuesta: acciones, recursos con su etiqueta y distancia, justificación y requisitos pendientes', (tester) async {
      await boot(tester, p1With());
      final rec = find.byKey(const Key('recommendation_section'));
      expect(find.descendant(of: rec, matching: find.text('Enviar rescate')), findsOneWidget);
      expect(find.descendant(of: rec, matching: find.text('Enviar atención médica')), findsOneWidget);
      expect(find.descendant(of: rec, matching: find.textContaining('Rescate estructural 1')), findsOneWidget);
      expect(find.descendant(of: rec, matching: find.textContaining('442 m')), findsOneWidget);
      expect(find.descendant(of: rec, matching: find.text('Confirmar con una segunda fuente')), findsOneWidget);
      expect(find.descendant(of: rec, matching: find.textContaining('requiere aprobación')), findsOneWidget);
    });

    testWidgets('los requisitos pendientes se presentan como lo que falta ANTES de aprobar', (tester) async {
      await boot(tester, p1With());
      expect(find.descendant(of: find.byKey(const Key('recommendation_section')), matching: find.textContaining('Antes de aprobar')), findsOneWidget);
    });

    testWidgets('«información requerida»: dice qué falta y NO ofrece aprobar ni rechazar', (tester) async {
      await boot(tester, detail('detail_fire_no_location.json'), tweak: (api) => api.details = {p1: detail('detail_fire_no_location.json')});
      expect(find.descendant(of: find.byKey(const Key('recommendation_section')), matching: find.textContaining('la ubicación')), findsOneWidget);
      expect(find.byKey(const Key('approve_button')), findsNothing);
      expect(find.byKey(const Key('reject_button')), findsNothing);
    });

    testWidgets('un SOS sin detalle: falta saber qué está pasando, sin botones', (tester) async {
      await boot(tester, detail('detail_bare.json'), tweak: (api) => api.details = {p1: detail('detail_bare.json')});
      expect(find.descendant(of: find.byKey(const Key('recommendation_section')), matching: find.textContaining('qué está pasando')), findsOneWidget);
      expect(find.byKey(const Key('approve_button')), findsNothing);
    });

    testWidgets('una propuesta descartada por la validación se dice, con el motivo, sin botones', (tester) async {
      final d = p1With(recommendation: {'state': 'rechazada', 'reason': 'cita_inventada: x', 'id': null, 'actions': <String>[], 'resourceIds': <String>[], 'resources': <Object?>[], 'justification': <Object?>[]});
      await boot(tester, d);
      expect(find.descendant(of: find.byKey(const Key('recommendation_section')), matching: find.textContaining('no pasó la validación')), findsOneWidget);
      expect(find.byKey(const Key('approve_button')), findsNothing);
    });

    testWidgets('un recurso que otro incidente también propone se marca', (tester) async {
      final d = p1With(shared: [
        {'resourceId': 'AMB-01', 'otherIncidents': ['bb-1'], 'approvedElsewhere': true},
      ]);
      await boot(tester, d);
      expect(find.byKey(const Key('shared_warning')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('shared_warning')), matching: find.textContaining('AMB-01')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('shared_warning')), matching: find.textContaining('ya aprobado')), findsOneWidget);
    });
  });

  group('estado de la aprobación', () {
    testWidgets('pendiente: se pueden aprobar y rechazar', (tester) async {
      await boot(tester, p1With());
      expect(find.descendant(of: find.byKey(const Key('approval_status')), matching: find.text('Pendiente de decisión')), findsOneWidget);
      expect(find.byKey(const Key('approve_button')), findsOneWidget);
      expect(find.byKey(const Key('reject_button')), findsOneWidget);
    });

    testWidgets('aprobada: quién, qué dijo, y se puede cambiar la decisión', (tester) async {
      await boot(tester, p1With(status: 'aprobada', current: [decision('A:000031', note: 'Sale el rescate')]));
      expect(find.descendant(of: find.byKey(const Key('approval_status')), matching: find.text('Aprobada')), findsOneWidget);
      final list = find.byKey(const Key('decisions'));
      expect(find.descendant(of: list, matching: find.textContaining('Ana Gómez')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.textContaining('Sale el rescate')), findsOneWidget);
    });

    testWidgets('caducada: se explica y las decisiones viejas quedan aparte, no cuentan como vigentes', (tester) async {
      await boot(tester, p1With(status: 'caduca', stale: [decision('A:000031')]));
      expect(find.descendant(of: find.byKey(const Key('approval_status')), matching: find.text('Caducada: el incidente cambió')), findsOneWidget);
      expect(find.byKey(const Key('stale_decisions')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('stale_decisions')), matching: find.textContaining('Ana Gómez')), findsOneWidget);
      expect(find.byKey(const Key('approve_button')), findsOneWidget, reason: 'la nueva versión se puede decidir');
    });

    testWidgets('DISCREPANCIA: dos decisiones contradictorias se ven, con quién dijo qué', (tester) async {
      await boot(tester, p1With(status: 'denegada', discrepancy: true, current: [decision('A:000031', who: 'Ana'), decision('B:000007', granted: false, who: 'Luis')]));
      expect(find.byKey(const Key('discrepancy_banner')), findsOneWidget);
      final list = find.byKey(const Key('decisions'));
      expect(find.descendant(of: list, matching: find.textContaining('Ana')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.textContaining('Luis')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('approval_status')), matching: find.text('Rechazada')), findsOneWidget);
    });
  });

  group('registrar una decisión', () {
    Future<void> open(WidgetTester tester, String button) async {
      await tester.ensureVisible(find.byKey(Key(button)));
      await tester.tap(find.byKey(Key(button)));
      await tester.pumpAndSettle();
    }

    testWidgets('«Aprobar» pide el nombre y no registra nada hasta confirmar', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      expect(find.byKey(const Key('approval_dialog')), findsOneWidget);
      expect(api.of('decide'), isEmpty);
    });

    testWidgets('sin nombre no se puede confirmar', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide'), isEmpty);
      expect(find.byKey(const Key('approval_dialog')), findsOneWidget);
      expect(find.byKey(const Key('who_error')), findsOneWidget);
    });

    testWidgets('confirmar envía la versión que la persona VIO, sus miembros, el nombre y la nota', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana Gómez');
      await tester.enterText(find.byKey(const Key('note_field')), 'Autorizado por el comandante');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      final c = api.of('decide').single.args;
      expect(c['recommendationId'], '3fa8370868b2c56c');
      expect(c['incidentId'], p1);
      expect(c['members'], [p1]);
      expect(c['granted'], true);
      expect(c['who'], 'Ana Gómez');
      expect(c['note'], 'Autorizado por el comandante');
      expect(find.byKey(const Key('approval_dialog')), findsNothing);
      expect(find.byKey(const Key('decision_ok')), findsOneWidget);
    });

    testWidgets('«Rechazar» se registra como rechazo', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'reject_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide').single.args['granted'], false);
    });

    testWidgets('el nombre se recuerda para la siguiente decisión (no hay que escribirlo cada vez)', (tester) async {
      final who = ValueNotifier<String>('');
      final api = await boot(tester, p1With(), who: who);
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(who.value, 'Ana');
      await open(tester, 'reject_button');
      expect((tester.widget(find.byKey(const Key('who_field'))) as TextField).controller!.text, 'Ana');
      expect(api.of('decide'), hasLength(1));
    });

    testWidgets('CARRERA: si el incidente cambia mientras se decide, NO se registra sobre la versión vieja y se avisa', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      // «mientras la persona decide» llega otro reporte: la recomendación tiene otro identificador
      api.details = {p1: p1With(recommendation: {'id': 'aaaaaaaaaaaaaaaa'})};
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide'), isEmpty, reason: 'la decisión era sobre otra versión');
      expect(find.byKey(const Key('changed_banner')), findsOneWidget);
      expect(find.byKey(const Key('approval_dialog')), findsNothing);
    });

    testWidgets('tras el aviso de cambio, la persona decide sobre la versión NUEVA con otro clic', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      api.details = {p1: p1With(recommendation: {'id': 'aaaaaaaaaaaaaaaa'})};
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      await open(tester, 'approve_button');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide').single.args['recommendationId'], 'aaaaaaaaaaaaaaaa');
    });

    testWidgets('si el recurso propuesto deja de estar en la recomendación al confirmar, también se avisa', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      api.details = {p1: p1With(recommendation: {'id': 'bbbbbbbbbbbbbbbb', 'resourceIds': <String>[], 'resources': <Object?>[]})};
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide'), isEmpty);
      expect(find.byKey(const Key('changed_banner')), findsOneWidget);
    });

    testWidgets('si el nodo rechaza la decisión, el diálogo sigue abierto con el motivo y NO se da por registrada', (tester) async {
      final api = await boot(tester, p1With(), tweak: (a) => a.failDecide = const ApiException(400, 'who debe ser texto'));
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide'), hasLength(1));
      expect(find.byKey(const Key('approval_dialog')), findsOneWidget);
      expect(find.byKey(const Key('decision_error')), findsOneWidget);
      expect(find.byKey(const Key('decision_ok')), findsNothing);
    });

    testWidgets('si el nodo no responde, lo mismo: no se afirma que quedó registrada', (tester) async {
      await boot(tester, p1With(), tweak: (a) => a.failDecide = http.ClientException('sin red'));
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('decision_error')), findsOneWidget);
      expect(find.byKey(const Key('decision_ok')), findsNothing);
    });

    testWidgets('si el nodo ya no acepta el código, lo dice con esas palabras y NO se da por registrada', (tester) async {
      await boot(tester, p1With(), tweak: (a) => a.failDecide = const AccessDenied());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('approval_dialog')), findsOneWidget);
      expect(find.byKey(const Key('decision_ok')), findsNothing);
      final msg = tester.widget<Text>(find.byKey(const Key('decision_error'))).data!;
      expect(msg, contains('código de acceso'));
      expect(msg, contains('NO quedó registrada'));
      expect(msg, isNot(contains('AccessDenied')), reason: 'nada de nombres de clases en pantalla');
    });

    testWidgets('un doble clic en «Registrar» envía UNA sola decisión', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Ana');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.tap(find.byKey(const Key('confirm_decision')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(api.of('decide'), hasLength(1));
    });

    testWidgets('con una decisión vigente de otra persona, se ofrece SUSTITUIRLA (hay que marcarlo) y viaja en supersedes', (tester) async {
      final api = await boot(tester, p1With(status: 'aprobada', current: [decision('A:000031', who: 'Ana')]));
      await open(tester, 'reject_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Luis');
      expect((tester.widget(find.byKey(const Key('supersede_A:000031'))) as CheckboxListTile).value, isFalse, reason: 'sustituir es una decisión explícita, no por omisión');
      await tester.tap(find.byKey(const Key('supersede_A:000031')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide').single.args['supersedes'], ['A:000031']);
    });

    testWidgets('sin marcar «sustituir», la decisión NO sustituye a la otra (queda la discrepancia visible)', (tester) async {
      final api = await boot(tester, p1With(status: 'aprobada', current: [decision('A:000031', who: 'Ana')]));
      await open(tester, 'reject_button');
      await tester.enterText(find.byKey(const Key('who_field')), 'Luis');
      await tester.tap(find.byKey(const Key('confirm_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide').single.args['supersedes'], isEmpty);
    });

    testWidgets('cancelar no registra nada', (tester) async {
      final api = await boot(tester, p1With());
      await open(tester, 'approve_button');
      await tester.tap(find.byKey(const Key('cancel_decision')));
      await tester.pumpAndSettle();
      expect(api.of('decide'), isEmpty);
      expect(find.byKey(const Key('approval_dialog')), findsNothing);
    });

    testWidgets('el diálogo recuerda a la persona que la recomendación NO se despacha sola', (tester) async {
      await boot(tester, p1With());
      await open(tester, 'approve_button');
      expect(find.descendant(of: find.byKey(const Key('approval_dialog')), matching: find.textContaining('queda registrada')), findsOneWidget);
    });
  });

  group('fallos al leer el detalle', () {
    testWidgets('un incidente que ya no existe se dice (se fusionó o se dividió)', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var gone = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: FakeApi(details: {}), id: 'zz-9', every: null, who: ValueNotifier(''), onGone: () => gone = true))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_gone')), findsOneWidget);
      expect(gone, isTrue);
    });

    testWidgets('un fallo de red al leer el detalle: aviso y botón para reintentar, sin pantalla en blanco', (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeApi()..failDetail = http.ClientException('x');
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: IncidentDetailView(api: api, id: p1, every: null, who: ValueNotifier('')))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_error')), findsOneWidget);
      api.failDetail = null;
      await tester.tap(find.byKey(const Key('detail_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('detail_panel')), findsOneWidget);
    });
  });
}
