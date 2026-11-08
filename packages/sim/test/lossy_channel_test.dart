import 'dart:typed_data';

import 'package:sard_protocol/sard_protocol.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// Canal interno que cuenta las entregas y responde siempre con un ACK ficticio de 1 byte.
class _Counting implements Channel {
  int calls = 0;
  @override
  Future<Uint8List?> send(Uint8List frame) async {
    calls++;
    return Uint8List.fromList([calls]);
  }
}

final Uint8List _frame = Uint8List.fromList([1, 2, 3]);

Future<List<bool>> _outcomes(
  int seed,
  int n, {
  double lossRequest = 0.3,
  double lossResponse = 0,
  double duplicate = 0,
}) async {
  final ch = LossyChannel(
    _Counting(),
    seed: seed,
    lossRequest: lossRequest,
    lossResponse: lossResponse,
    duplicate: duplicate,
  );
  return [for (var i = 0; i < n; i++) (await ch.send(_frame)) != null];
}

void main() {
  test('lossRequest 1: no entrega y devuelve null', () async {
    final inner = _Counting();
    final ch = LossyChannel(inner, seed: 1, lossRequest: 1);
    expect(await ch.send(_frame), isNull);
    expect(inner.calls, 0);
  });

  test(
    'duplicate 1: el nodo recibe la trama dos veces y se devuelve la primera respuesta',
    () async {
      final inner = _Counting();
      final ch = LossyChannel(inner, seed: 1, duplicate: 1);
      expect(await ch.send(_frame), [1]);
      expect(inner.calls, 2);
    },
  );

  test(
    'lossResponse 1: se entrega una vez pero la respuesta se pierde',
    () async {
      final inner = _Counting();
      final ch = LossyChannel(inner, seed: 1, lossResponse: 1);
      expect(await ch.send(_frame), isNull);
      expect(inner.calls, 1);
    },
  );

  test('sin fallos configurados, el canal es transparente', () async {
    final inner = _Counting();
    final ch = LossyChannel(inner, seed: 1);
    expect(await ch.send(_frame), [1]);
    expect(inner.calls, 1);
  });

  test('la misma semilla produce la misma secuencia en 100 envíos', () async {
    expect(await _outcomes(42, 100), await _outcomes(42, 100));
  });

  test('semillas distintas producen secuencias distintas', () async {
    expect(await _outcomes(1, 100), isNot(await _outcomes(2, 100)));
  });

  test(
    'con lossRequest 0.3 la tasa observada en 1000 envíos está entre 0.2 y 0.4',
    () async {
      final out = await _outcomes(7, 1000);
      final lost = out.where((ok) => !ok).length / out.length;
      expect(lost, inInclusiveRange(0.2, 0.4));
    },
  );

  test('las probabilidades fuera de 0..1 se rechazan', () {
    expect(
      () => LossyChannel(_Counting(), seed: 1, lossRequest: 1.5),
      throwsArgumentError,
    );
    expect(
      () => LossyChannel(_Counting(), seed: 1, duplicate: -0.1),
      throwsArgumentError,
    );
  });
}
