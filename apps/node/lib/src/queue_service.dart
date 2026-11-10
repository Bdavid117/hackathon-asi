import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';
import 'incident_index.dart';
import 'incidents.dart';

/// Una lectura de la cola: el JSON, si es de una versión anterior del log y qué antigüedad tiene.
class QueueRead {
  const QueueRead(this.json, {this.incidents, this.details = const {}, this.version = 0, this.epoch = '', required this.stale, required this.ageMs});
  final String json;

  /// Índice de incidentes (vista corta, contadores y páginas) calculado en la misma pasada que la cola.
  final IncidentIndex? incidents;

  /// Una página de incidentes (ver [IncidentIndex.page]). Lanza [ArgumentError] ante parámetros inválidos.
  String incidentsPage({String view = 'short', String? urgency, bool? bare, bool? pending, int offset = 0, int limit = 200}) =>
      (incidents ?? IncidentIndex.empty).page(view: view, urgency: urgency, bare: bare, pending: pending, offset: offset, limit: limit);

  /// Detalle ya codificado de cada incidente, por identificador.
  final Map<String, String> details;

  /// Número de la versión calculada (crece con cada cálculo nuevo): sirve para el `ETag`.
  final int version;
  final String epoch;

  /// El detalle JSON del incidente [id], o `null` si no existe en esta versión.
  String? detailOf(String id) => details[id];

  /// El log cambió después de calcular esto y el nodo prefirió no esperar al cálculo nuevo.
  final bool stale;
  final int ageMs;
}

class _Snap {
  _Snap(this.projection, this.count, this.computedAt, this.computeMs, this.version);
  final int version;
  final Projection projection;
  final int count;
  final DateTime computedAt;
  final int computeMs;
}

/// Sirve la cola **sin bloquear el hilo que atiende los ACK**.
///
/// Calcular la cola es caro (agrupa y puntúa pares): con 10 000 reportes tarda segundos. Por eso:
///  · el cálculo de colas grandes (≥ [isolateAbove] reportes) corre en **otro isolate**;
///  · el resultado se guarda y sólo se recalcula si cambió el número de eventos del log;
///  · si el último cálculo fue lento (≥ [slowMs]) y el log cambió, se devuelve la versión anterior
///    marcada como `stale` (con su antigüedad) mientras se recalcula en segundo plano, **pero sólo
///    si no pasa de [maxStaleMs]**: pasado ese tope se espera al dato fresco. El tablero muestra la
///    frescura (el PDF la exige);
///  · las lecturas simultáneas comparten un único cálculo.
class QueueService {
  QueueService(
    this._log, {
    this.isolateAbove = 300,
    this.slowMs = 200,
    this.maxStaleMs = 5000,
    DateTime Function()? clock,
    this.resources = const [],
    Future<String> Function(List<Event> received, List<Event> triage)? compute,
    Future<Projection> Function(List<Event> received, List<Event> triage, List<Event> approvals, List<Resource> resources)? computeProjection,
  }) : _clock = clock ?? DateTime.now,
       _compute = compute != null
           ? ((r, t, a, res) async => Projection(queueJson: await compute(r, t)))
           : (computeProjection ?? _defaultCompute(isolateAbove));

  final EventLog _log;
  final int isolateAbove;
  final int slowMs;

  /// Antigüedad máxima que se tolera servir: pasado este tope la lectura espera al dato fresco aunque
  /// el cálculo sea lento (una cola vieja puede esconder un P1 recién llegado).
  final int maxStaleMs;
  final DateTime Function() _clock;
  final Future<Projection> Function(List<Event>, List<Event>, List<Event>, List<Resource>) _compute;

  /// Recursos declarados que el agente 6 puede proponer.
  final List<Resource> resources;

  /// Los únicos eventos que cambian lo que muestra la cola: los reportes recibidos, el triaje (el del
  /// modelo) y las aprobaciones. Los latidos, la auditoría y las normalizaciones NO la invalidan: si
  /// no, cada uno forzaría un recálculo (segundos con muchos reportes) sin que nada relevante cambie.
  static const List<String> relevantTypes = ['report.received', 'triage.assessed', 'approval.granted', 'approval.denied'];

  _Snap? _snap;
  int _versions = 0;

  /// Distingue este arranque del servicio: el contador de versiones vuelve a 1 al reiniciar, y sin esto un
  /// `ETag` de antes del reinicio podría dar un 304 falso con datos distintos.
  final String epoch = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 30).toRadixString(36)}';
  Future<_Snap>? _job;

  static Future<Projection> Function(List<Event>, List<Event>, List<Event>, List<Resource>) _defaultCompute(int isolateAbove) =>
      (received, triage, approvals, resources) => received.length < isolateAbove
      ? Future.value(projectionFromEvents(received, triage, approvals, resources))
      : Isolate.run(() => projectionFromEvents(received, triage, approvals, resources));

  /// Espera a que termine el cálculo en curso, si lo hay (para pruebas y apagado).
  Future<void> get idle async {
    final j = _job;
    if (j == null) return;
    try {
      await j;
    } on Object {
      // el error ya lo recibió quien esperaba el cálculo
    }
  }

  QueueRead _read(_Snap s, {required bool stale}) =>
      QueueRead(s.projection.queueJson, incidents: s.projection.incidents, details: s.projection.details, version: s.version, epoch: epoch, stale: stale, ageMs: _clock().difference(s.computedAt).inMilliseconds);

  Future<_Snap> _start(int count) {
    final start = _clock();
    final received = _log.allOfType('report.received');
    final triage = _log.allOfType('triage.assessed');
    final approvals = [..._log.allOfType('approval.granted'), ..._log.allOfType('approval.denied')];
    late final Future<_Snap> f;
    f = _compute(received, triage, approvals, resources)
        .then((projection) {
          final end = _clock();
          return _snap = _Snap(projection, count, end, end.difference(start).inMilliseconds, ++_versions);
        })
        .whenComplete(() {
          if (identical(_job, f)) _job = null;
        });
    _job = f;
    f.then<void>((_) {}, onError: (Object _) {}); // si nadie espera, que el error no quede sin manejar
    return f;
  }

  Future<QueueRead> read() async {
    final count = _log.countOfTypes(relevantTypes);
    final snap = _snap;
    if (snap != null && snap.count == count) return _read(snap, stale: false);
    final tooOld = snap != null && _clock().difference(snap.computedAt).inMilliseconds > maxStaleMs;
    final slow = snap != null && snap.computeMs >= slowMs && !tooOld;
    final job = _job ?? _start(count);
    if (slow) return _read(snap, stale: true); // no esperar: el cálculo sigue en segundo plano
    final s = await job;
    return _read(s, stale: s.count != _log.countOfTypes(relevantTypes)); // si llegaron eventos mientras tanto, se dice
  }
}
