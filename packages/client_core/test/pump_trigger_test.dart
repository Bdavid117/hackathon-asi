import 'package:sard_client_core/sard_client_core.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late List<String> calls;
  late PumpTrigger trigger;
  var inFlight = 0;
  var maxConcurrent = 0;
  late Future<int> Function() slowPump;

  Future<int> pump() async {
    calls.add('pump');
    inFlight++;
    if (inFlight > maxConcurrent) maxConcurrent = inFlight;
    await slowPump();
    inFlight--;
    return 0;
  }

  setUp(() {
    now = DateTime.fromMillisecondsSinceEpoch(1000000000);
    calls = [];
    inFlight = 0;
    maxConcurrent = 0;
    slowPump = () async => 0;
    trigger = PumpTrigger(
      pump: pump,
      releaseBackoff: () => calls.add('release'),
      minGap: const Duration(milliseconds: 500),
      clock: () => now,
    );
  });

  tearDown(() => trigger.dispose());

  test('al volver la red libera las esperas y envía de inmediato, en ese orden', () async {
    await trigger.onConnectivity(false);
    now = now.add(const Duration(seconds: 5));
    await trigger.onConnectivity(true);
    expect(calls, ['release', 'pump']);
  });

  test('un evento del temporizador sin red no envía', () async {
    await trigger.onConnectivity(false);
    await trigger.onEvent();
    expect(calls, isEmpty);
  });

  test('un evento del temporizador con red (o sin información todavía) envía, sin liberar esperas', () async {
    await trigger.onEvent();
    expect(calls, ['pump']);
  });

  test('los cambios de red repetidos dentro de minGap cuentan como uno', () async {
    await trigger.onConnectivity(true);
    now = now.add(const Duration(milliseconds: 100));
    await trigger.onConnectivity(true);
    now = now.add(const Duration(milliseconds: 100));
    await trigger.onConnectivity(true);
    expect(calls.where((c) => c == 'pump').length, 1);
    now = now.add(const Duration(milliseconds: 600));
    await trigger.onConnectivity(true);
    expect(calls.where((c) => c == 'pump').length, 2);
  });

  test('una red que parpadea (cae y vuelve) dentro de minGap no martillea el envío', () async {
    await trigger.onConnectivity(true);
    await trigger.onConnectivity(false);
    now = now.add(const Duration(milliseconds: 50));
    await trigger.onConnectivity(true);
    expect(calls.where((c) => c == 'pump').length, 1);
  });

  test('no solapa dos envíos: el segundo disparador espera a que termine el primero y entonces se atiende', () async {
    slowPump = () => Future<int>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 0;
        });
    final a = trigger.onEvent();
    final b = trigger.onEvent();
    await Future.wait([a, b]);
    expect(maxConcurrent, 1);
    expect(calls.where((c) => c == 'pump').length, 2, reason: 'coalescidos en UNA ronda de seguimiento');
  });

  test('muchos disparadores durante un envío se coalescen en una sola ronda de seguimiento', () async {
    slowPump = () => Future<int>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 0;
        });
    final futures = [for (var i = 0; i < 6; i++) trigger.onEvent()];
    await Future.wait(futures);
    expect(calls.where((c) => c == 'pump').length, 2);
    expect(maxConcurrent, 1);
  });

  test('una reconexión que llega a mitad de un envío no pierde la liberación de esperas', () async {
    slowPump = () => Future<int>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 0;
        });
    final first = trigger.onEvent(); // envío en curso con un nodo lento
    now = now.add(const Duration(seconds: 1));
    final reconnect = trigger.onConnectivity(true); // vuelve la señal mientras tanto
    await Future.wait([first, reconnect]);
    expect(calls, ['pump', 'release', 'pump'], reason: 'tras el envío en curso: se liberan las esperas y se reenvía');
  });

  test('un SOS recién tocado no se descarta por el filtro anti-parpadeo (minGap)', () async {
    await trigger.onEvent();
    calls.clear();
    now = now.add(const Duration(milliseconds: 10)); // dentro de minGap
    await trigger.onNewReport();
    expect(calls, ['pump']);
  });

  test('un SOS recién tocado sin red no intenta enviar (saldrá al volver la señal)', () async {
    await trigger.onConnectivity(false);
    await trigger.onNewReport();
    expect(calls, isEmpty);
  });

  test('si el reloj del teléfono retrocede (corrección de hora al volver la red) no se descarta la reconexión', () async {
    await trigger.onEvent();
    calls.clear();
    now = now.subtract(const Duration(hours: 1)); // el teléfono corrige su hora hacia atrás
    await trigger.onConnectivity(true);
    expect(calls, ['release', 'pump'], reason: 'una diferencia negativa cuenta como hueco superado, no como «muy reciente»');
  });

  test('si el reloj retrocede tampoco se descarta un evento del temporizador', () async {
    await trigger.onEvent();
    calls.clear();
    now = now.subtract(const Duration(minutes: 30));
    await trigger.onEvent();
    expect(calls, ['pump']);
  });

  test('un disparo descartado por minGap no se pierde: se repite una vez al terminar el hueco', () async {
    final real = PumpTrigger(
      pump: pump,
      releaseBackoff: () => calls.add('release'),
      minGap: const Duration(milliseconds: 120),
    );
    await real.onConnectivity(true);
    expect(calls, ['release', 'pump']);
    await real.onConnectivity(true); // dentro del hueco: no se envía ahora…
    expect(calls, ['release', 'pump']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls, ['release', 'pump', 'release', 'pump'], reason: '…pero se repite al terminar el hueco, con su liberación de esperas');
    real.dispose();
  });

  test('varios disparos descartados dentro del mismo hueco dan una sola repetición', () async {
    final real = PumpTrigger(pump: pump, releaseBackoff: () => calls.add('release'), minGap: const Duration(milliseconds: 120));
    await real.onConnectivity(true);
    for (var i = 0; i < 5; i++) {
      await real.onConnectivity(true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls.where((c) => c == 'pump').length, 2);
    real.dispose();
  });

  test('dispose cancela la repetición pendiente', () async {
    final real = PumpTrigger(pump: pump, releaseBackoff: () => calls.add('release'), minGap: const Duration(milliseconds: 120));
    await real.onConnectivity(true);
    await real.onConnectivity(true);
    real.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls.where((c) => c == 'pump').length, 1);
  });

  test('tras una caída, el siguiente evento del temporizador ya no envía hasta que vuelva la red', () async {
    await trigger.onConnectivity(true);
    now = now.add(const Duration(seconds: 3));
    await trigger.onConnectivity(false);
    calls.clear();
    now = now.add(const Duration(seconds: 3));
    await trigger.onEvent();
    expect(calls, isEmpty);
  });
}
