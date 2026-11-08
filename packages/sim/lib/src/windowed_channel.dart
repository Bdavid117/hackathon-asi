import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';

import 'virtual_clock.dart';

/// Un canal que sólo existe durante «ventanas»: abierto [open], cerrado [closed], y vuelta a
/// empezar. En la fase cerrada no entrega nada y devuelve `null`.
///
/// La fase abierta del ciclo *k* es `[epoch + k·(open+closed), epoch + k·(open+closed) + open)`;
/// por tanto el instante exacto `epoch + open` ya está cerrado.
class WindowedChannel implements Channel {
  WindowedChannel(
    this._inner, {
    required VirtualClock clock,
    required this.open,
    required this.closed,
    DateTime? epoch,
  })  : _clock = clock,
        epoch = epoch ?? clock.now();

  final Channel _inner;
  final VirtualClock _clock;
  final Duration open;
  final Duration closed;
  final DateTime epoch;

  Duration get period => open + closed;

  int _offsetMicros(DateTime t) {
    final p = period.inMicroseconds;
    return ((t.difference(epoch).inMicroseconds % p) + p) % p;
  }

  bool isOpenAt(DateTime t) => _offsetMicros(t) < open.inMicroseconds;

  /// El primer instante, igual o posterior a [t], en que la ventana está abierta.
  DateTime nextOpenAtOrAfter(DateTime t) {
    if (isOpenAt(t)) return t;
    return t.add(Duration(microseconds: period.inMicroseconds - _offsetMicros(t)));
  }

  /// Cuándo se cierra la ventana abierta en [t] o, si [t] cae en la fase cerrada, la siguiente.
  DateTime windowEndFor(DateTime t) {
    final opensAt = nextOpenAtOrAfter(t);
    return opensAt.add(open - Duration(microseconds: _offsetMicros(opensAt)));
  }

  @override
  Future<Uint8List?> send(Uint8List frame) async {
    if (!isOpenAt(_clock.now())) return null;
    return _inner.send(frame);
  }
}
