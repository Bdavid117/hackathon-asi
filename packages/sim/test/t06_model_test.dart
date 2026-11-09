import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sard_agents/sard_agents.dart';
import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// La medición de T06 con el modelo real (`bin/t06_model.dart`). Aquí se prueba SIN clave y sin red: contra un puerto
/// falso y contra el servidor falso. Lo que se verifica es la maquinaria (muestreo, gasto, fallos contados, salida), no la
/// calidad de ningún modelo.
class _Port implements LlmPort {
  _Port(this.respond);
  final Future<LlmResult> Function(LlmRequest) respond;
  int calls = 0;

  @override
  Future<LlmResult> completeJson(LlmRequest r) {
    calls++;
    return respond(r);
  }
}

LlmResult _verdict(String urgency, {int inTok = 1000, int outTok = 500, List<Map<String, String>> signals = const []}) => LlmResult(
  text: jsonEncode({'urgency': urgency, 'signals': signals, 'confidence': 0.8, 'escalate_to_human': false}),
  stopReason: 'end_turn',
  inputTokens: inTok,
  outputTokens: outTok,
  model: 'claude-sonnet-5-5',
  requestId: 'req_x',
);

const T06ModelConfig _base = T06ModelConfig(seeds: [601], perSeed: 12, model: 'claude-sonnet-5-5', effort: 'low', concurrency: 3, budgetUsd: 100);

void main() {
  group('muestreo', () {
    test('sólo reportes CON texto (sin texto el modelo no se consulta) y determinista: la misma configuración da las mismas claves', () {
      final a = sampleReports(_base);
      final b = sampleReports(_base);
      expect(a.map((r) => r.report.reportKey).toList(), b.map((r) => r.report.reportKey).toList());
      expect(a.length, 12);
      expect(a.every((r) => (r.report.text ?? '').trim().isNotEmpty), isTrue);
    });

    test('reparte la muestra por TODO el conjunto (no los primeros N): sube en orden y llega hasta el final', () {
      final ds = generateDataset(SynthConfig(seed: 601));
      final keys = [for (final r in ds.reports) if ((r.text ?? '').trim().isNotEmpty) r.reportKey];
      final s = sampleReports(const T06ModelConfig(seeds: [601], perSeed: 60, model: 'm', effort: 'low', concurrency: 1, budgetUsd: 1));
      final idx = [for (final r in s) keys.indexOf(r.report.reportKey)];
      expect(idx.every((i) => i >= 0), isTrue);
      expect([...idx]..sort(), idx, reason: 'en orden');
      expect(idx.last, greaterThan(keys.length * 0.8), reason: 'llega hasta el final del conjunto, no sólo a los primeros');
      expect(s.map((r) => r.report.subgroup).toSet().length, greaterThan(2));
    });

    test('pedir más de lo que hay devuelve todo lo que hay, sin repetir', () {
      final s = sampleReports(const T06ModelConfig(seeds: [601], perSeed: 1000000, model: 'm', effort: 'low', concurrency: 1, budgetUsd: 1));
      expect(s.map((r) => r.report.reportKey).toSet().length, s.length);
    });
  });

  group('precios y gasto', () {
    test('un modelo sin precio conocido NO se mide (el tope de gasto no valdría nada) salvo que se den los precios', () {
      expect(() => priceOf('modelo-desconocido'), throwsArgumentError);
      expect(priceOf('modelo-desconocido', inPerMTok: 1, outPerMTok: 5).outPerMTok, 5);
      expect(priceOf('claude-sonnet-5-5').inPerMTok, 2);
      expect(priceOf('claude-opus-5-5').outPerMTok, 20);
    });

    test('el coste de una llamada sale de SUS tokens y del precio por millón', () {
      final p = priceOf('claude-sonnet-5-5'); // 2 / 10
      expect(p.costOf(1000000, 0), closeTo(2.0, 1e-9));
      expect(p.costOf(0, 1000000), closeTo(10.0, 1e-9));
      expect(p.costOf(1000, 500), closeTo(0.002 + 0.005, 1e-9));
    });

    test('el gasto acumulado es la suma de los costes reales de las llamadas hechas', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P2', inTok: 1000, outTok: 500)));
      expect(r.records.where((x) => x.inputTokens != null).length, r.records.length);
      expect(r.spentUsd, closeTo(r.records.length * 0.007, 1e-9));
    });

    test('TOPE DURO: con un presupuesto para ~3 llamadas se hacen ≈ 3, no 12; se marca «cortada por presupuesto» y no se pasa', () async {
      const cfg = T06ModelConfig(seeds: [601], perSeed: 12, model: 'claude-sonnet-5-5', effort: 'low', concurrency: 1, budgetUsd: 0.025);
      final port = _Port((_) async => _verdict('P2', inTok: 1000, outTok: 500)); // 0,007 por llamada
      final r = await runT06Model(cfg, port);
      expect(r.stoppedByBudget, isTrue);
      expect(r.spentUsd, lessThanOrEqualTo(0.025 + 1e-9));
      expect(port.calls, inInclusiveRange(2, 4));
      expect(r.skipped, 12 - port.calls);
    });

    test('con concurrencia alta el tope también vale: las llamadas EN VUELO cuentan como gasto reservado', () async {
      const cfg = T06ModelConfig(seeds: [601], perSeed: 30, model: 'claude-sonnet-5-5', effort: 'low', concurrency: 10, budgetUsd: 0.05);
      final r = await runT06Model(cfg, _Port((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _verdict('P2', inTok: 1000, outTok: 500);
      }));
      expect(r.spentUsd, lessThanOrEqualTo(0.05 + 0.007 * 2), reason: 'a lo sumo se pasa por el error de la estimación de lo que valía una llamada en vuelo');
      expect(r.stoppedByBudget, isTrue);
    });
  });

  group('lo que se mide', () {
    test('cada registro lleva la verdad, lo que dijeron las reglas, lo que sale con el modelo, el modo y la latencia', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P1', signals: const [])));
      final x = r.records.first;
      expect(x.truth, isA<Urgency>());
      expect(x.rules, isA<Urgency>());
      expect(x.combined, isA<Urgency>());
      expect(x.mode, anyOf('rules', 'rules+llm'));
      expect(x.latencyMs, greaterThanOrEqualTo(0));
      expect(x.requestId, 'req_x');
    });

    test('PISO: el modelo nunca BAJA lo que dicen las reglas (un modelo que siempre dice P4 no cambia nada)', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P4')));
      for (final x in r.records) {
        expect(x.combined.index, lessThanOrEqualTo(x.rules.index), reason: '${x.reportKey}: P1 = 0 … P4 = 3');
      }
    });

    test('un modelo que sube a P1 SIN una señal nueva citada no sube nada (se mantiene la urgencia de las reglas)', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P1')));
      for (final x in r.records) {
        expect(x.combined, x.rules);
      }
    });

    test('los fallos se CUENTAN POR CAUSA (plazo, HTTP, negativa, salida inválida) y caen al respaldo de reglas', () async {
      var n = 0;
      final r = await runT06Model(_base, _Port((_) async {
        n++;
        return switch (n % 4) {
          0 => const LlmResult(timedOut: true),
          1 => const LlmResult(error: 'HTTP 529'),
          2 => const LlmResult(text: '{}', stopReason: 'refusal'),
          _ => const LlmResult(text: 'esto no es json', stopReason: 'end_turn'),
        };
      }));
      expect(r.fallbacks.keys, containsAll(['plazo_agotado', 'http_529', 'negativa', 'salida_invalida']));
      expect(r.fallbacks.values.fold<int>(0, (a, b) => a + b), r.records.length);
      expect(r.records.every((x) => x.mode == 'rules' && x.combined == x.rules), isTrue);
    });

    test('una excepción del puerto no tumba la medición: se cuenta como fallo y sigue', () async {
      final r = await runT06Model(_base, _Port((_) async => throw StateError('boom')));
      expect(r.records.length, 12);
      expect(r.fallbacks['excepcion'], 12);
    });
  });

  group('el informe', () {
    test('lleva recall de P1 con reglas y con modelo LADO A LADO, por subgrupo, el gasto, la latencia y los límites; no la clave', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P2')));
      final md = renderT06Model(_base, r);
      expect(md, contains('| | Sólo reglas | Reglas + modelo |'), reason: 'el resumen pone lado a lado reglas y reglas + modelo');
      for (final s in ['recall de P1', 'reglas', 'reglas + modelo', 'Por subgrupo', 'Gasto', 'p95', 'Fallos del modelo', 'Lo que esta medición NO dice', 'claude-sonnet-5-5']) {
        expect(md, contains(s), reason: s);
      }
      expect(md, isNot(contains('sk-ant')));
    });

    test('dice cuántas llamadas pasaron de 8 s (el plazo del nodo): sin eso un nodo con 8 s caería siempre al respaldo sin que se vea', () async {
      final r = await runT06Model(_base, _Port((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _verdict('P2');
      }));
      final md = renderT06Model(_base, r);
      expect(md, contains('8 s'));
    });

    test('el CSV de datos crudos no lleva el texto de los reportes ni nada parecido a una clave', () async {
      final r = await runT06Model(_base, _Port((_) async => _verdict('P2')));
      final csv = renderT06ModelCsv(r);
      expect(csv.split('\n').first, startsWith('seed,reportKey,subgroup,truth,rules,combined,mode'));
      expect(csv, isNot(contains('sk-ant')));
      final texts = sampleReports(_base).map((s) => s.report.text!).where((t) => t.length > 12);
      for (final t in texts) {
        expect(csv, isNot(contains(t)));
      }
    });
  });

  group('contra el servidor falso (la ruta HTTP de punta a punta, sin clave real)', () {
    test('ClaudeHttpPort + FakeClaudeServer: se mide y se escribe el informe', () async {
      final fake = await FakeClaudeServer.start();
      addTearDown(() => fake.close());
      final port = ClaudeHttpPort(client: http.Client(), apiKey: 'sk-ant-SECRETA', baseUrl: fake.url, model: 'claude-sonnet-5-5', effort: 'low');
      final r = await runT06Model(const T06ModelConfig(seeds: [601], perSeed: 8, model: 'claude-sonnet-5-5', effort: 'low', concurrency: 2, budgetUsd: 5), port);
      expect(r.records.length, 8);
      expect(r.records.every((x) => x.mode == 'rules+llm' || x.mode == 'rules'), isTrue);
      final md = renderT06Model(_base, r);
      expect(md, isNot(contains('SECRETA')));
    });
  });
}
