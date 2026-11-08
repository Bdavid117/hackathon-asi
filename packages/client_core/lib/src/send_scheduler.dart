import 'dart:math';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

import 'outbox.dart';

/// Envía lo vencido de la bandeja, en ráfaga, y aplica los ACK.
///
/// Un envío sin respuesta válida cuenta como intento fallido y se reprograma con espera
/// exponencial y variación completa.
class SendScheduler {
  SendScheduler({
    required Outbox outbox,
    required Channel channel,
    required Uint8List key,
    Random? rng,
    DateTime Function()? clock,
    this.backoffBase = const Duration(seconds: 2),
    this.backoffCap = const Duration(seconds: 300),
  })  : _outbox = outbox,
        _channel = channel,
        _key = key,
        _rng = rng ?? Random(),
        _clock = clock ?? DateTime.now;

  final Outbox _outbox;
  final Channel _channel;
  final Uint8List _key;
  final Random _rng;
  final DateTime Function() _clock;

  /// Base y tope de la espera entre reintentos (por defecto 2 s y 300 s).
  final Duration backoffBase;
  final Duration backoffCap;

  /// Máximo de tramas en vuelo por ráfaga.
  static const int window = 8;

  /// Espera aleatoria uniforme en `[0, min(cap, base·2^attempts)]`.
  static Duration backoff(int attempts, Random rng,
      {Duration base = const Duration(seconds: 2), Duration cap = const Duration(seconds: 300)}) {
    final grown = base.inMilliseconds * (1 << min(attempts, 20));
    final ceiling = min(cap.inMilliseconds, grown);
    return Duration(milliseconds: rng.nextInt(ceiling + 1));
  }

  /// Envía hasta [window] tramas vencidas. Devuelve cuántas fueron acusadas.
  Future<int> pump() async {
    final now = _clock();
    final batch = _outbox.due(now, limit: window);
    for (final e in batch) {
      _outbox.markSending(e.frameSeq);
    }
    final responses = await Future.wait([
      for (final e in batch)
        Future<Uint8List?>(() async {
          try {
            return await _channel.send(e.frame);
          } on Exception {
            return null;
          }
        }),
    ]);

    var acked = 0;
    for (var i = 0; i < batch.length; i++) {
      final e = batch[i];
      final bytes = responses[i];
      Ack? ack;
      if (bytes != null) {
        try {
          ack = decodeAck(bytes, _key);
        } on FrameException {
          ack = null;
        }
      }
      if (ack != null && ack.covers(e.frameSeq)) {
        _outbox.applyAck(ack);
        acked++;
      } else {
        _outbox.markFailed(e.frameSeq, nextTryAt: now.add(backoff(e.attempts, _rng, base: backoffBase, cap: backoffCap)));
      }
    }
    return acked;
  }
}
