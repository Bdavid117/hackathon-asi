import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'fake_node.dart';
import 'lossy_channel.dart';
import 'virtual_clock.dart';
import 'windowed_channel.dart';

final Uint8List _key = Uint8List.fromList(utf8.encode('clave-de-ejemplo'));
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(1700000000000);

/// Percentil por rango más cercano (p entre 0 y 1). Lista vacía → [Duration.zero].
Duration percentile(List<Duration> xs, double p) {
  if (xs.isEmpty) return Duration.zero;
  final s = [...xs]..sort();
  final i = (p * s.length).ceil().clamp(1, s.length) - 1;
  return s[i];
}

NewReport _report(int flags, {String? text}) => NewReport(
      incidentType: 1,
      flags: flags,
      peopleBucket: 1,
      batteryQ: 15,
      locQuality: LocQuality.within50m,
      lat: 5.07,
      lon: -75.51,
      text: text,
    );

const int _flagsP1 = SituationFlags.atrapado | SituationFlags.herido;

class DeliveryResult {
  DeliveryResult({
    required this.total,
    required this.delivered,
    required this.elapsed,
    required this.p1Latencies,
    required this.otherLatencies,
    required this.stats,
    required this.nodeReceived,
  });

  final int total;
  final int delivered;

  /// Tiempo virtual hasta la última entrega (o hasta el horizonte si no se entregó todo).
  final Duration elapsed;
  final List<Duration> p1Latencies;
  final List<Duration> otherLatencies;
  final TransportStats stats;

  /// Reportes distintos que el nodo guardó (no debe superar [total]).
  final int nodeReceived;

  double get ratio => total == 0 ? 1 : delivered / total;
}

/// T02/T03: [reports] SOS (la mitad P1, la mitad P4) creados a la vez, enviados por un canal con
/// pérdida (`loss` en la ida, `loss/2` en la respuesta, 5 % de duplicados), en tiempo virtual.
///
/// El planificador usa su espera real (2 s base, 300 s tope); el reloj salta directamente al
/// siguiente instante en que algo vence, así que simular horas cuesta milisegundos.
Future<DeliveryResult> runLossScenario({
  required double loss,
  int reports = 20,
  int seed = 1,
  Duration horizon = const Duration(hours: 6),
}) async {
  final clock = VirtualClock(_epoch);
  final node = FakeNodeChannel(_key);
  final channel = LossyChannel(node, seed: seed, lossRequest: loss, lossResponse: loss / 2, duplicate: 0.05);
  final outbox = Outbox.open(':memory:', key: _key);
  final scheduler = SendScheduler(outbox: outbox, channel: channel, key: _key, rng: Random(seed), clock: clock.now);

  final p1Seqs = <int>{};
  for (var i = 0; i < reports; i++) {
    final isP1 = i < reports ~/ 2;
    final e = outbox.enqueueSos(_report(isP1 ? _flagsP1 : 0), now: clock.now());
    if (isP1) p1Seqs.add(e.frameSeq);
  }

  final start = clock.now();
  final sentAt = <int, DateTime>{};
  var last = start;
  while (true) {
    await scheduler.pump();
    final all = outbox.all();
    for (final e in all) {
      if (e.state == OutboxState.sent && !sentAt.containsKey(e.frameSeq)) {
        sentAt[e.frameSeq] = clock.now();
        last = clock.now();
      }
    }
    if (all.every((e) => e.state == OutboxState.sent)) break;
    if (clock.now().difference(start) > horizon) break;
    final waits = [for (final e in all) if (e.state == OutboxState.queued) e.nextTryAt ?? clock.now()];
    final next = waits.reduce((a, b) => a.isBefore(b) ? a : b);
    final target = next.isAfter(clock.now()) ? next : clock.now().add(const Duration(milliseconds: 1));
    clock.advance(target.difference(clock.now()));
  }

  final created = {for (final e in outbox.all()) e.frameSeq: e.createdAt};
  final p1 = <Duration>[];
  final other = <Duration>[];
  sentAt.forEach((seq, at) => (p1Seqs.contains(seq) ? p1 : other).add(at.difference(created[seq]!)));
  final result = DeliveryResult(
    total: reports,
    delivered: sentAt.length,
    elapsed: last.difference(start),
    p1Latencies: p1,
    otherLatencies: other,
    stats: scheduler.stats,
    nodeReceived: node.received,
  );
  outbox.close();
  return result;
}

class WindowResult {
  WindowResult({required this.total, required this.deliveredEventually, required this.deliveredInFirstWindow, required this.latencies});

  final int total;
  final int deliveredEventually;

  /// Entregados antes de que se cierre la primera ventana abierta en o tras su creación.
  final int deliveredInFirstWindow;
  final List<Duration> latencies;

  double get firstWindowRatio => total == 0 ? 1 : deliveredInFirstWindow / total;
}

/// T04: [reports] SOS creados en instantes aleatorios a lo largo de [periods] ciclos de un canal
/// que sólo se abre [open] de cada `open + closed`. Dentro de la ventana, el canal pierde
/// [lossInWindow] de las tramas. La app envía al crear cada reporte y, como haría al volver la
/// conectividad, **libera las esperas de reintento al abrirse la ventana** (desactivable con
/// [releaseBackoffOnOpen] para medir su efecto) y reintenta cada segundo mientras dura.
///
/// [channelTimeout] modela el coste real de intentar enviar con la ventana cerrada: un nodo
/// inalcanzable retiene el envío hasta su plazo (5 s en `HttpChannel`), y lo que llega mientras
/// tanto espera a que termine (el planificador coalesce, no pierde). Con `Duration.zero` el canal
/// cerrado falla al instante: es el caso **ideal**, que sobrestima lo que se logra en la práctica.
Future<WindowResult> runWindowScenario({
  int reports = 100,
  int seed = 1,
  Duration open = const Duration(seconds: 3),
  Duration closed = const Duration(seconds: 57),
  int periods = 10,
  double lossInWindow = 0,
  bool releaseBackoffOnOpen = true,
  Duration channelTimeout = Duration.zero,
  int maxExtraPeriods = 60,
}) async {
  final clock = VirtualClock(_epoch);
  final node = FakeNodeChannel(_key);
  final lossy = LossyChannel(node, seed: seed, lossRequest: lossInWindow, lossResponse: lossInWindow / 2);
  final windowed = WindowedChannel(lossy, clock: clock, open: open, closed: closed, epoch: _epoch);
  final outbox = Outbox.open(':memory:', key: _key);
  final scheduler = SendScheduler(outbox: outbox, channel: windowed, key: _key, rng: Random(seed), clock: clock.now);

  final rng = Random(seed);
  final period = windowed.period;
  final creations = <Duration>[for (var i = 0; i < reports; i++) Duration(milliseconds: rng.nextInt(period.inMilliseconds * periods))]..sort();

  // Línea de tiempo: creaciones y un «tick» por segundo mientras la ventana está abierta.
  final events = <(Duration, int?)>[
    for (var i = 0; i < creations.length; i++) (creations[i], i),
    for (var k = 0; k < periods + maxExtraPeriods; k++)
      for (var s = 0; s < open.inSeconds; s++) (period * k + Duration(seconds: s), null),
  ]..sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      return (a.$2 == null ? 1 : 0).compareTo(b.$2 == null ? 1 : 0); // primero las creaciones
    });

  final createdAt = <int, DateTime>{};
  final sentAt = <int, DateTime>{};
  void noteSent() {
    for (final e in outbox.all()) {
      if (e.state == OutboxState.sent && !sentAt.containsKey(e.frameSeq)) sentAt[e.frameSeq] = clock.now();
    }
  }

  Future<void> pumpAll() async {
    final wasClosed = !windowed.isOpenAt(clock.now());
    final framesBefore = scheduler.stats.framesSent;
    while (await scheduler.pump() > 0) {}
    // Intentar enviar con la ventana cerrada bloquea el envío hasta el plazo del nodo inalcanzable.
    if (wasClosed && scheduler.stats.framesSent > framesBefore && channelTimeout > Duration.zero) {
      clock.advance(channelTimeout);
    }
    noteSent();
  }

  for (final (at, idx) in events) {
    final target = _epoch.add(at);
    if (target.isAfter(clock.now())) clock.advance(target.difference(clock.now()));
    if (idx != null) {
      final e = outbox.enqueueSos(_report(_flagsP1), now: clock.now());
      createdAt[e.frameSeq] = clock.now();
      await pumpAll();
    } else {
      if (releaseBackoffOnOpen && at.inMicroseconds % period.inMicroseconds == 0) outbox.releaseBackoff();
      await pumpAll();
    }
    if (idx == null && createdAt.length == reports && sentAt.length == reports) break;
  }

  var inFirst = 0;
  final latencies = <Duration>[];
  createdAt.forEach((seq, c) {
    final s = sentAt[seq];
    if (s == null) return;
    latencies.add(s.difference(c));
    if (!s.isAfter(windowed.windowEndFor(c))) inFirst++;
  });
  final result = WindowResult(
    total: reports,
    deliveredEventually: sentAt.length,
    deliveredInFirstWindow: inFirst,
    latencies: latencies,
  );
  outbox.close();
  return result;
}
