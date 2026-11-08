import 'dart:math';
import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

/// Envuelve un [Channel] y le aplica pérdidas y duplicados de forma reproducible.
///
/// En cada envío se sortean siempre los tres eventos (en el mismo orden), de modo que
/// la secuencia de resultados sólo depende de la semilla y del número de envíos.
class LossyChannel implements Channel {
  LossyChannel(
    this._inner, {
    required int seed,
    double lossRequest = 0,
    double lossResponse = 0,
    double duplicate = 0,
  })  : _rng = Random(seed),
        _lossRequest = _prob('lossRequest', lossRequest),
        _lossResponse = _prob('lossResponse', lossResponse),
        _duplicate = _prob('duplicate', duplicate);

  final Channel _inner;
  final Random _rng;
  final double _lossRequest;
  final double _lossResponse;
  final double _duplicate;

  static double _prob(String name, double p) {
    if (p < 0 || p > 1) throw ArgumentError.value(p, name, 'debe estar entre 0 y 1');
    return p;
  }

  @override
  Future<Uint8List?> send(Uint8List frame) async {
    final dropRequest = _rng.nextDouble() < _lossRequest;
    final dup = _rng.nextDouble() < _duplicate;
    final dropResponse = _rng.nextDouble() < _lossResponse;
    if (dropRequest) return null;
    final response = await _inner.send(frame);
    if (dup) await _inner.send(frame);
    return dropResponse ? null : response;
  }
}
