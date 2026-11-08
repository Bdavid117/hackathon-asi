import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

void main() {
  group('T02 · presupuesto de bytes', () {
    test(
      'sin pérdida un SOS confirmado cuesta 55 B (33 de ida + 22 de vuelta)',
      () async {
        final r = await runLossScenario(loss: 0, reports: 10, seed: 1);
        expect(r.delivered, 10);
        expect(r.stats.bytesPerAcked, 55.0);
      },
    );
  });

  group('T03 · entrega bajo pérdida (tiempo virtual)', () {
    test(
      'sin pérdida todo sale de inmediato y los P1 antes que los P4',
      () async {
        final r = await runLossScenario(loss: 0, reports: 20, seed: 7);
        expect(r.delivered, 20);
        expect(r.elapsed, lessThanOrEqualTo(const Duration(seconds: 1)));
        expect(
          percentile(r.p1Latencies, 0.5) <= percentile(r.otherLatencies, 0.5),
          isTrue,
        );
      },
    );

    for (final loss in [0.3, 0.6]) {
      test(
        'con pérdida $loss todo se entrega en menos de 30 min virtuales',
        () async {
          final r = await runLossScenario(loss: loss, reports: 20, seed: 7);
          expect(r.delivered, 20);
          expect(r.elapsed, lessThanOrEqualTo(const Duration(minutes: 30)));
        },
      );
    }

    test(
      'con pérdida 0.9 se entrega al menos el 95 % antes de 6 h virtuales',
      () async {
        final r = await runLossScenario(
          loss: 0.9,
          reports: 20,
          seed: 7,
          horizon: const Duration(hours: 6),
        );
        expect(r.ratio, greaterThanOrEqualTo(0.95));
      },
    );

    test('es reproducible: la misma semilla da el mismo resultado', () async {
      final a = await runLossScenario(loss: 0.6, reports: 20, seed: 3);
      final b = await runLossScenario(loss: 0.6, reports: 20, seed: 3);
      expect(a.elapsed, b.elapsed);
      expect(a.stats.bytesOut, b.stats.bytesOut);
    });

    test(
      'el nodo nunca guarda un reporte dos veces aunque el canal duplique y reintente',
      () async {
        final r = await runLossScenario(loss: 0.6, reports: 20, seed: 11);
        expect(r.nodeReceived, 20);
      },
    );
  });

  group('T04 · ventanas breves (3 s abiertas cada 60 s)', () {
    test(
      'sin pérdida en la ventana, ≥ 95 % de los SOS salen en la primera ventana disponible',
      () async {
        final r = await runWindowScenario(reports: 100, seed: 1);
        expect(r.deliveredEventually, 100);
        expect(r.firstWindowRatio, greaterThanOrEqualTo(0.95));
      },
    );

    test(
      'con 30 % de pérdida dentro de la ventana todo acaba entregándose',
      () async {
        final r = await runWindowScenario(
          reports: 100,
          seed: 1,
          lossInWindow: 0.3,
        );
        expect(r.deliveredEventually, 100);
        expect(r.firstWindowRatio, greaterThan(0.5));
      },
    );

    test(
      'liberar las esperas al abrirse la ventana es lo que permite salir en ella (100 % frente a menos del 80 %)',
      () async {
        final sin = await runWindowScenario(
          reports: 100,
          seed: 1,
          releaseBackoffOnOpen: false,
        );
        final con = await runWindowScenario(reports: 100, seed: 1);
        expect(con.firstWindowRatio, greaterThanOrEqualTo(0.95));
        expect(
          sin.firstWindowRatio,
          lessThan(0.8),
          reason: 'sin liberar, el reintento suele caer fuera de la ventana',
        );
      },
    );

    test(
      'si intentar enviar con la ventana cerrada cuesta el plazo de un nodo inalcanzable (5 s), salen menos SOS en la primera ventana',
      () async {
        final ideal = await runWindowScenario(reports: 100, seed: 1);
        final real = await runWindowScenario(
          reports: 100,
          seed: 1,
          channelTimeout: const Duration(seconds: 5),
        );
        expect(ideal.firstWindowRatio, greaterThanOrEqualTo(0.95));
        expect(
          real.firstWindowRatio,
          lessThan(ideal.firstWindowRatio),
          reason: 'el coste del intento fallido se come ventanas',
        );
      },
    );

    test(
      'aun con ese coste, todo acaba entregándose en ventanas posteriores',
      () async {
        final real = await runWindowScenario(
          reports: 100,
          seed: 1,
          channelTimeout: const Duration(seconds: 5),
        );
        expect(real.deliveredEventually, 100);
      },
    );
  });
}
