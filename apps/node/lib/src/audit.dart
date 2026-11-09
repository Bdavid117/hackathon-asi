import 'dart:async';
import 'dart:isolate';

import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';
import 'merged_reports.dart';
import 'ownership.dart';
import 'pipeline.dart';

/// Los vínculos de cada reporte `target` contra el resto, para dejar rastro de auditoría.
///
/// Función **pura sobre listas** (lo único que viaja a otro isolate): devuelve, por reporte nuevo,
/// los vínculos `same`/`possible` ordenados por puntaje.
List<Map<String, Object?>> computeAuditLinks(List<Event> received, Set<String> targets) {
  final merged = mergeReports(received);
  final byKey = {for (final m in merged) m.reportKey: m};
  final result = computeLinks([for (final m in merged) m.toObservation()]);
  final per = <String, List<Map<String, Object?>>>{};
  for (final l in result.links) {
    // Un par deja UN solo rastro: si los dos son nuevos en este lote lo lleva el de clave mayor
    // (determinista); si sólo uno es nuevo, lo lleva ése.
    final bothNew = targets.contains(l.a) && targets.contains(l.b);
    for (final (me, other) in [(l.a, l.b), (l.b, l.a)]) {
      if (!targets.contains(me)) continue;
      if (bothNew && me.compareTo(other) < 0) continue;
      (per[me] ??= []).add({
        'other': other,
        'state': l.pair.state.name,
        'score': l.pair.score,
        'uncertainty': l.pair.uncertainty,
      });
    }
  }
  return [
    for (final k in per.keys.toList()..sort())
      {
        'key': k,
        'rev': byKey[k]!.rev,
        'links': per[k]!..sort((x, y) {
          final c = (y['score']! as double).compareTo(x['score']! as double);
          return c != 0 ? c : (x['other']! as String).compareTo(y['other']! as String);
        }),
      },
  ];
}

/// Escribe `incident.linked` **por lotes y fuera de la ruta del ACK**.
///
///  · sólo examina lo nuevo (reportes y revisiones que aún no auditó), pero puntúa contra todo;
///  · **idempotente entre reinicios y entre nodos**: nunca escribe un (reporte, revisión) que ya
///    tenga su `incident.linked` en el log (propio o replicado);
///  · con muchos reportes, el cálculo corre en otro isolate;
///  · [tick] la limita a lo sumo cada [minInterval] (o 5 veces lo que tardó la última), para que una
///    ráfaga no la dispare por cada trama.
class AuditLinker {
  AuditLinker(
    this._log, {
    this.isolateAbove = 300,
    DateTime Function()? clock,
    this.minInterval = const Duration(seconds: 5),
    List<Map<String, Object?>> Function(List<Event> received, Set<String> targets)? compute,
    this.ownership,
    this.onError,
  }) : _clock = clock ?? DateTime.now,
       _compute = compute;


  /// Sustituye el cálculo (pruebas). Si se da, corre en este hilo.
  final List<Map<String, Object?>> Function(List<Event>, Set<String>)? _compute;

  final EventLog _log;
  final int isolateAbove;
  final Duration minInterval;
  final DateTime Function() _clock;

  /// Reparto de la auditoría entre nodos (*rendezvous*); `null` = este nodo audita todo.
  final OwnershipPolicy? ownership;

  /// Se llama si un lote falla (p. ej. «Too many open files»): el fallo de una tarea de fondo se avisa y
  /// se reintenta, nunca derriba al nodo.
  final void Function(Object error, StackTrace stack)? onError;
  final Set<String> _done = {}; // «clave|rev» ya examinados en esta vida del proceso
  DateTime? _nextDue; // cuándo vence lo diferido (el plazo de relevo más cercano)
  bool _running = false;
  DateTime? _nextAllowed;
  int _lastReceived = -1;

  Future<int> runOnce() async {
    final received = _log.allOfType('report.received');
    final merged = mergeReports(received);
    // Lo ya examinado, por este nodo o por otro (las marcas de lote y los vínculos replican).
    final examined = <String>{
      for (final b in _log.allOfType('audit.batch')) ...((b.body['examined'] as List?) ?? const []).whereType<String>(),
      for (final e in _log.allOfType('incident.linked')) '${e.reportKey}|${e.rev}',
    };
    final now = _clock();
    final targets = <String, int>{};
    DateTime? nextDue;
    for (final m in merged) {
      final id = '${m.reportKey}|${m.rev}';
      if (_done.contains(id) || examined.contains(id)) continue;
      final policy = ownership;
      if (policy != null) {
        final receivedAt = DateTime.fromMillisecondsSinceEpoch(m.receivedAtMs, isUtc: true);
        if (!policy.due(m.reportKey, receivedAt, now)) {
          // todavía no le toca a este nodo: se anota cuándo vence para volver a mirar sin esperar reportes nuevos
          final due = receivedAt.add(policy.delayFor(m.reportKey));
          if (nextDue == null || due.isBefore(nextDue)) nextDue = due;
          continue;
        }
      }
      targets[m.reportKey] = m.rev;
    }
    _nextDue = nextDue;
    if (targets.isEmpty) return 0;
    final keys = targets.keys.toSet();
    final custom = _compute;
    final results = custom != null
        ? custom(received, keys)
        : received.length < isolateAbove
        ? computeAuditLinks(received, keys)
        : await Isolate.run(() => computeAuditLinks(received, keys));
    var written = 0;
    for (final r in results) {
      final key = r['key']! as String, rev = r['rev']! as int;
      final src = _log.find('report.received', key, rev);
      _log.append(
        'incident.linked',
        {'links': r['links'], 'agent_version': kAgentVersion},
        reportKey: key,
        rev: rev,
        inputs: [if (src != null) src.id],
      );
      written++;
    }
    // UNA marca por lote (no una por reporte): así los demás nodos saben qué se examinó aunque no haya
    // dejado vínculos, y un relevo no lo repite.
    _log.append('audit.batch', {'examined': [for (final e in targets.entries) '${e.key}|${e.value}'], 'agent_version': kAgentVersion});
    for (final e in targets.entries) {
      _done.add('${e.key}|${e.value}');
    }
    return written;
  }

  /// Corre un lote si hay reportes nuevos, no hay otro en curso y pasó el intervalo. `true` si corrió.
  Future<bool> tick() async {
    if (_running) return false;
    final now = _clock();
    if (_nextAllowed != null && now.isBefore(_nextAllowed!)) return false;
    final count = _log.countOfTypes(['report.received']);
    final dueNow = _nextDue != null && !now.isBefore(_nextDue!);
    if (count == _lastReceived && !dueNow) return false;
    _running = true;
    try {
      _lastReceived = count;
      await runOnce();
    } on Object catch (e, st) {
      _lastReceived = -1; // se reintenta en el siguiente tick
      onError?.call(e, st);
      return false;
    } finally {
      _running = false;
      final end = _clock();
      final took = end.difference(now);
      _nextAllowed = end.add(took * 5 > minInterval ? took * 5 : minInterval);
    }
    return true;
  }
}
