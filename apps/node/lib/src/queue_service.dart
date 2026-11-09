import 'dart:async';
import 'dart:isolate';

import 'event_log.dart';
import 'queue_view.dart';

/// Una lectura de la cola: el JSON, si es de una versión anterior del log y qué antigüedad tiene.
class QueueRead {
  const QueueRead(this.json, {required this.stale, required this.ageMs});
  final String json;

  /// El log cambió después de calcular esto y el nodo prefirió no esperar al cálculo nuevo.
  final bool stale;
  final int ageMs;
}

class _Snap {
  _Snap(this.json, this.count, this.computedAt, this.computeMs);
  final String json;
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
    Future<String> Function(List<Event> received, List<Event> triage)? compute,
  }) : _clock = clock ?? DateTime.now,
       _compute = compute ?? _defaultCompute(isolateAbove);

  final EventLog _log;
  final int isolateAbove;
  final int slowMs;

  /// Antigüedad máxima que se tolera servir: pasado este tope la lectura espera al dato fresco aunque
  /// el cálculo sea lento (una cola vieja puede esconder un P1 recién llegado).
  final int maxStaleMs;
  final DateTime Function() _clock;
  final Future<String> Function(List<Event>, List<Event>) _compute;

  _Snap? _snap;
  Future<_Snap>? _job;

  static Future<String> Function(List<Event>, List<Event>) _defaultCompute(int isolateAbove) =>
      (received, triage) => received.length < isolateAbove
      ? Future.value(queueJsonFromEvents(received, triage))
      : Isolate.run(() => queueJsonFromEvents(received, triage));

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
      QueueRead(s.json, stale: stale, ageMs: _clock().difference(s.computedAt).inMilliseconds);

  Future<_Snap> _start(int count) {
    final start = _clock();
    final received = _log.allOfType('report.received');
    final triage = _log.allOfType('triage.assessed');
    late final Future<_Snap> f;
    f = _compute(received, triage)
        .then((json) {
          final end = _clock();
          return _snap = _Snap(json, count, end, end.difference(start).inMilliseconds);
        })
        .whenComplete(() {
          if (identical(_job, f)) _job = null;
        });
    _job = f;
    f.then<void>((_) {}, onError: (Object _) {}); // si nadie espera, que el error no quede sin manejar
    return f;
  }

  Future<QueueRead> read() async {
    final count = _log.count();
    final snap = _snap;
    if (snap != null && snap.count == count) return _read(snap, stale: false);
    final tooOld = snap != null && _clock().difference(snap.computedAt).inMilliseconds > maxStaleMs;
    final slow = snap != null && snap.computeMs >= slowMs && !tooOld;
    final job = _job ?? _start(count);
    if (slow) return _read(snap, stale: true); // no esperar: el cálculo sigue en segundo plano
    final s = await job;
    return _read(s, stale: s.count != _log.count()); // si llegaron eventos mientras tanto, se dice
  }
}
