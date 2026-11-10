import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sard_dashboard/api.dart';
import 'package:sard_dashboard/models.dart';

Map<String, Object?> fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, Object?>();

IncidentRow rowWith(Map<String, Object?> over) {
  final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
  return IncidentRow.fromJson({...base, ...over});
}

Map<String, Object?> countersWith(Map<String, Object?> extra) => {...(fixture('incidents_short.json')['counters']! as Map).cast<String, Object?>(), ...extra};

void main() {
  group('Counters: lo que esperan las personas, sobre el total real', () {
    test('pendientes de decisión, la hora de la más antigua y las decisiones contradictorias', () {
      final c = Counters.fromJson(countersWith({'pendingDecision': 4, 'pendingOldestAt': 1786370900, 'discrepancies': 2}));
      expect(c.pendingDecision, 4);
      expect(c.pendingOldestAt, 1786370900);
      expect(c.discrepancies, 2);
    });

    test('un nodo anterior no los manda: 0, 0 y sin hora (no un error)', () {
      final c = Counters.fromJson(fixture('incidents_short.json')['counters']);
      expect(c.pendingDecision, 0);
      expect(c.pendingOldestAt, isNull);
      expect(c.discrepancies, 0);
    });

    test('un valor de otro tipo se lee como 0 / sin hora, no rompe', () {
      final c = Counters.fromJson(countersWith({'pendingDecision': 'muchos', 'pendingOldestAt': 'ayer', 'discrepancies': -3}));
      expect((c.pendingDecision, c.pendingOldestAt, c.discrepancies), (0, null, 0));
    });
  });

  group('IncidentRow.isPendingDecision: la misma definición que el nodo', () {
    IncidentRow row(String rec, String status, {bool discrepancy = false}) => rowWith({
      'recommendation': {'state': rec, 'id': 'r1', 'actions': ['enviar_rescate']},
      'approval': {'status': status, 'discrepancy': discrepancy, 'decisions': 0},
    });

    test('una propuesta pendiente o caducada espera a una persona', () {
      expect(row('propuesta', 'pendiente').isPendingDecision, isTrue);
      expect(row('propuesta', 'caduca').isPendingDecision, isTrue);
    });

    test('una ya aprobada o rechazada no', () {
      expect(row('propuesta', 'aprobada').isPendingDecision, isFalse);
      expect(row('propuesta', 'denegada').isPendingDecision, isFalse);
    });

    test('lo que no es una propuesta no', () {
      expect(row('informacion_requerida', 'pendiente').isPendingDecision, isFalse);
      expect(row('rechazada', 'pendiente').isPendingDecision, isFalse);
    });

    test('las decisiones contradictorias van aparte, aunque el estado sea «caduca»', () {
      expect(row('propuesta', 'caduca', discrepancy: true).isPendingDecision, isFalse);
    });
  });

  group('IncidentRow.receivedAt: cuándo recibió el nodo lo último (en el reloj del nodo)', () {
    test('se lee', () {
      expect(rowWith({'receivedAt': 1794197853485}).receivedAt, 1794197853485);
    });

    test('un nodo anterior no lo manda: nulo', () {
      final base = ((fixture('incidents_short.json')['items']! as List).first as Map).cast<String, Object?>();
      expect(IncidentRow.fromJson({...base}..remove('receivedAt')).receivedAt, isNull);
    });
  });

  group('HttpDashboardApi.incidents con pending', () {
    test('pending=true se manda al nodo en la vista completa', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return http.Response.bytes(utf8.encode(jsonEncode(fixture('incidents_all.json'))), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }), Uri.parse('http://nodo:8081'));
      await api.incidents(view: 'all', pending: true);
      expect(seen.queryParameters, {'view': 'all', 'pending': 'true'});
    });

    test('sin pending no aparece en la consulta', () async {
      late Uri seen;
      final api = HttpDashboardApi(MockClient((r) async {
        seen = r.url;
        return http.Response.bytes(utf8.encode(jsonEncode(fixture('incidents_all.json'))), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }), Uri.parse('http://nodo:8081'));
      await api.incidents(view: 'all');
      expect(seen.queryParameters.containsKey('pending'), isFalse);
    });
  });
}
