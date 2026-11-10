import 'dart:convert';

import 'package:http/http.dart' as http;

import 'fingerprint.dart';

/// Sondas HTTP contra nodos REALES para los scripts de medición (T18, T19): lo que ve el coordinador, hasta que el nodo contesta con
/// una vista fresca. Todas esperan con un plazo y devuelven lo último leído si no llega a lo pedido (el script decide si es fallo).
class NodeProbe {
  NodeProbe(this.client);

  final http.Client client;

  Future<Map<String, Object?>> _getMap(Uri url, {Duration timeout = const Duration(seconds: 30)}) async =>
      (jsonDecode((await client.get(url).timeout(timeout)).body) as Map).cast<String, Object?>();

  Future<Map<String, Object?>> health(Uri node) => _getMap(node.resolve('/api/health'), timeout: const Duration(seconds: 5));

  /// `/api/nodes`: lo que el nodo sabe de sus pares (estado y último error).
  Future<Map<String, Object?>> nodes(Uri node) => _getMap(node.resolve('/api/nodes'), timeout: const Duration(seconds: 10));

  /// ¿Responde `/api/health`? (un proceso muerto no).
  Future<bool> alive(Uri node) async {
    try {
      await health(node);
      return true;
    } on Object {
      return false;
    }
  }

  /// La cola con vista FRESCA (`x-queue-stale: false`) y, si se pide, con al menos [expect] reportes.
  Future<List<Map<String, Object?>>> queue(Uri node, {int? expect, Duration within = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(within);
    List<Map<String, Object?>> last = const [];
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await client.get(node.resolve('/api/queue')).timeout(const Duration(seconds: 30));
        last = (jsonDecode(r.body) as List).cast<Map<String, Object?>>();
        if (r.headers['x-queue-stale'] == 'false' && (expect == null || last.length >= expect)) return last;
      } on Object {
        // reintenta
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return last;
  }

  /// Los incidentes (vista completa) con vista fresca, con [reports] reportes contados y, si se da, hasta que se cumpla [until].
  Future<List<Map<String, Object?>>> incidents(Uri node, {int? reports, bool Function(List<Map<String, Object?>>)? until, Duration within = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(within);
    List<Map<String, Object?>> last = const [];
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await client.get(node.resolve('/api/incidents?view=all&limit=1000')).timeout(const Duration(seconds: 30));
        final env = (jsonDecode(r.body) as Map).cast<String, Object?>();
        last = (env['items'] as List).cast<Map<String, Object?>>();
        final counters = (env['counters'] as Map).cast<String, Object?>();
        if (r.headers['x-queue-stale'] == 'false' && (reports == null || counters['reports'] == reports) && (until == null || until(last))) return last;
      } on Object {
        // reintenta
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return last;
  }

  /// La huella de las proyecciones del nodo (cola + incidentes), o `null` si no se pudo leer una vista fresca con [reports] reportes.
  Future<String?> fingerprint(Uri node, {required int reports, Duration within = const Duration(seconds: 20)}) async {
    final q = await queue(node, expect: reports, within: within);
    if (q.length != reports) return null;
    final i = await incidents(node, reports: reports, within: within);
    return projectionFingerprint(q, incidents: i);
  }

  /// Quita los eventos repetidos (mismo `id`) conservando el orden de la primera aparición. Al consultar a VARIOS nodos que ya
  /// convergieron cada evento llega una vez por nodo: sin esto cualquier conteo queda multiplicado por el número de nodos. Un evento
  /// sin `id` no se puede identificar y se conserva siempre.
  static List<Map<String, Object?>> uniqueById(Iterable<Map<String, Object?>> events) {
    final seen = <Object?>{};
    return [
      for (final e in events)
        if (e['id'] == null || seen.add(e['id'])) e,
    ];
  }

  /// Los eventos `triage.assessed` DEL MODELO (`mode: rules+llm`) que [node] tiene de los orígenes dados.
  Future<List<Map<String, Object?>>> modelJudgments(Uri node, List<String> origins) async {
    final out = <Map<String, Object?>>[];
    for (final origin in origins) {
      var after = 0;
      while (true) {
        final page = (jsonDecode((await client.get(node.resolve('/api/events?origin=$origin&after=$after&limit=1000')).timeout(const Duration(seconds: 30))).body) as List).cast<Map<String, Object?>>();
        if (page.isEmpty) break;
        out.addAll(page.where((e) => e['type'] == 'triage.assessed' && (e['body'] as Map)['mode'] == 'rules+llm'));
        after = page.last['seq']! as int;
      }
    }
    return out;
  }
}
