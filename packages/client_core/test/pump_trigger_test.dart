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

  test('no solapa dos envíos aunque lleguen dos disparadores a la vez', () async {
    slowPump = () => Future<int>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return 0;
        });
    final a = trigger.onEvent();
    final b = trigger.onEvent();
    await Future.wait([a, b]);
    expect(maxConcurrent, 1);
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
