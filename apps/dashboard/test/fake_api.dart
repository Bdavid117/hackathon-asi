import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

IncidentsPage shortPage({bool stale = false, int ageMs = 0}) => IncidentsPage.fromJson(fixture('incidents_short.json'), stale: stale, ageMs: ageMs);
IncidentsPage allPage() => IncidentsPage.fromJson(fixture('incidents_all.json'));
IncidentsPage barePage() => IncidentsPage.fromJson(fixture('incidents_bare.json'));
IncidentDetail p1Detail() => IncidentDetail.fromJson(fixture('detail_p1_approved.json'));

/// Una llamada hecha al nodo simulado.
class Call {
  Call(this.name, [this.args = const {}]);
  final String name;
  final Map<String, Object?> args;
  @override
  String toString() => '$name$args';
}

/// El nodo, simulado: devuelve lo que se le programa y apunta lo que se le pide.
class FakeApi implements DashboardApi {
  FakeApi({IncidentsPage? short, IncidentsPage? all, IncidentsPage? bare, NodesStatus? nodes, Map<String, IncidentDetail>? details})
    : short = short ?? shortPage(),
      all = all ?? allPage(),
      bare = bare ?? barePage(),
      nodesStatus = nodes ?? NodesStatus.fromJson(fixture('nodes.json')),
      details = details ?? {'00000000000000a1-1': p1Detail()};

  IncidentsPage short;
  IncidentsPage all;
  IncidentsPage bare;
  NodesStatus nodesStatus;
  Map<String, IncidentDetail> details;
  Object? failIncidents;
  Object? failNodes;
  Object? failDetail;
  Object? failDecide;
  Object? failDispatch;

  /// Si se da, `dispatch` espera a que se complete (para probar el doble toque mientras se envía).
  Completer<void>? holdDispatch;
  final List<Call> calls = [];

  /// Si se da, el nodo simulado exige ese código (como `--coordinator-token`): sin él lanza [AccessDenied].
  String? requireCode;
  String? _code;
  @override
  set accessCode(String? code) => _code = code;
  String? get accessCode => _code;
  void _check() {
    if (requireCode != null && _code != requireCode) throw const AccessDenied();
  }

  /// Se ejecuta antes de contestar `detail`: permite cambiar el incidente «mientras la persona decide».
  void Function(String id)? onDetail;
  void Function()? onDecide;

  /// Si se da, la vista corta espera a que se complete (para probar respuestas tardías).
  Completer<void>? holdShort;

  List<Call> of(String name) => [for (final c in calls) if (c.name == name) c];

  @override
  Future<IncidentsPage> incidents({String view = 'short', String? urgency, bool? bare, bool? pending, int offset = 0, int limit = 200}) async {
    calls.add(Call('incidents', {'view': view, 'urgency': urgency, 'bare': bare, 'pending': pending, 'offset': offset, 'limit': limit}));
    _check();
    if (failIncidents != null) throw failIncidents!;
    if (view == 'short') {
      final gate = holdShort;
      if (gate != null) await gate.future;
      return short;
    }
    if (bare == true) return this.bare;
    final src = all;
    final items = [for (final i in src.items) if ((urgency == null || i.urgency == urgency) && (pending == null || i.isPendingDecision == pending)) i];
    final slice = items.skip(offset).take(limit).toList();
    return IncidentsPage(view: 'all', counters: src.counters, total: items.length, offset: offset, limit: limit, bare: null, items: slice);
  }

  @override
  Future<IncidentDetail> detail(String id) async {
    calls.add(Call('detail', {'id': id}));
    _check();
    onDetail?.call(id);
    if (failDetail != null) throw failDetail!;
    final d = details[id];
    if (d == null) throw IncidentGone(id);
    return d;
  }

  @override
  Future<NodesStatus> nodes() async {
    calls.add(Call('nodes'));
    _check();
    if (failNodes != null) throw failNodes!;
    return nodesStatus;
  }

  @override
  Future<void> decide({required String recommendationId, required String incidentId, required List<String> members, required bool granted, required String who, String note = '', List<String> supersedes = const []}) async {
    calls.add(Call('decide', {'recommendationId': recommendationId, 'incidentId': incidentId, 'members': members, 'granted': granted, 'who': who, 'note': note, 'supersedes': supersedes}));
    onDecide?.call();
    _check();
    if (failDecide != null) throw failDecide!;
  }

  @override
  Future<void> dispatch({required String id, required String text, required String medium, required String who, String? origin, List<String> flags = const [], int people = 0}) async {
    calls.add(Call('dispatch', {'id': id, 'text': text, 'medium': medium, 'who': who, 'origin': origin, 'flags': flags, 'people': people}));
    final gate = holdDispatch;
    if (gate != null) await gate.future;
    _check();
    if (failDispatch != null) throw failDispatch!;
  }
}
