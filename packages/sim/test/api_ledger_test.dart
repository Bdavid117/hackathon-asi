import 'dart:convert';
import 'dart:io';

import 'package:sard_sim/sard_sim.dart';
import 'package:test/test.dart';

/// El registro de gasto de la API: la fuente de lo gastado (la consola de Anthropic manda). Falla CERRADO: ante la duda, no se gasta.
void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sard-ledger-');
    path = '${dir.path}/gasto.json';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void seed(List<Map<String, Object?>> entries) => File(path).writeAsStringSync(jsonEncode({'entries': entries}));
  Map<String, Object?> entry(String run, double usd, {bool estimated = false}) => {'run': run, 'date': '2026-11-09', 'usd': usd, 'note': 'x', 'estimated': estimated};

  group('guard', () {
    test('se niega a lanzar si lo gastado más el tope de la corrida pasa del límite menos la reserva', () {
      seed([entry('T07', 12.0)]);
      final l = ApiLedger.load(path);
      expect(() => l.guard(runCapUsd: 29.0), throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('12.00'), contains('29.00'), contains('40.00')))), reason: '12 + 29 = 41 > 50 − 10');
    });

    test('con un tope que cabe, deja lanzar (también en el límite exacto)', () {
      seed([entry('T07', 12.0)]);
      final l = ApiLedger.load(path);
      expect(() => l.guard(runCapUsd: 12.0), returnsNormally);
      expect(() => l.guard(runCapUsd: 28.0), returnsNormally, reason: '12 + 28 = 40 = 50 − 10: cabe');
      expect(() => l.guard(runCapUsd: 28.01), throwsStateError);
    });

    test('la reserva y el límite se pueden cambiar, y un tope negativo o cero no es válido', () {
      seed([entry('T07', 5.0)]);
      final l = ApiLedger.load(path);
      expect(() => l.guard(runCapUsd: 20, totalCapUsd: 30, reserveUsd: 5), returnsNormally);
      expect(() => l.guard(runCapUsd: 21, totalCapUsd: 30, reserveUsd: 5), throwsStateError);
      expect(() => l.guard(runCapUsd: 0), throwsArgumentError);
      expect(() => l.guard(runCapUsd: -1), throwsArgumentError);
    });
  });

  group('load', () {
    test('un archivo ausente falla cerrado (no se asume 0 gastado)', () {
      expect(() => ApiLedger.load('${dir.path}/no-existe.json'), throwsA(isA<StateError>()));
    });

    test('un archivo corrupto o con importes inválidos falla cerrado', () {
      for (final bad in ['no es json', '{"entries": 3}', '{"entries": [{"run": "x", "usd": "mucho"}]}', '{"entries": [{"run": "x", "usd": -1}]}', '{"entries": [{"run": "x", "usd": 1e999}]}', '{"entries": [{"usd": 1}]}', '[]']) {
        File(path).writeAsStringSync(bad);
        expect(() => ApiLedger.load(path), throwsA(isA<StateError>()), reason: bad);
      }
    });

    test('suma lo registrado', () {
      seed([entry('a', 1.5), entry('b', 2.25, estimated: true)]);
      final l = ApiLedger.load(path);
      expect(l.spentUsd, closeTo(3.75, 1e-9));
      expect(l.entries.map((e) => e.estimated), [false, true], reason: 'la marca de estimado se conserva al cargar');
    });
  });

  group('record y save', () {
    test('record acumula y save/load conserva el total y las entradas (con su marca de estimado)', () {
      seed([entry('a', 1.0)]);
      final l = ApiLedger.load(path)
        ..record(run: 'T07 ronda 2', usd: 8.5, note: 'seeds 706–713')
        ..record(run: 'piloto', usd: 0.5, note: 'sin medir', estimated: true);
      expect(l.spentUsd, closeTo(10.0, 1e-9));
      l.save();
      final again = ApiLedger.load(path);
      expect(again.spentUsd, closeTo(10.0, 1e-9));
      expect(again.entries.map((e) => e.run), ['a', 'T07 ronda 2', 'piloto']);
      expect(again.entries.map((e) => e.estimated), [false, false, true]);
    });

    test('un importe negativo o no finito no se registra', () {
      seed([entry('a', 1.0)]);
      final l = ApiLedger.load(path);
      for (final bad in [-0.01, double.nan, double.infinity]) {
        expect(() => l.record(run: 'x', usd: bad, note: 'n'), throwsArgumentError, reason: '$bad');
      }
      expect(l.spentUsd, 1.0);
    });

    test('el archivo no contiene nada parecido a una clave: record se niega a guardarla', () {
      seed([]);
      final l = ApiLedger.load(path);
      expect(() => l.record(run: 'x', usd: 1, note: 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789'), throwsArgumentError);
      expect(() => l.record(run: 'Bearer abcdefghijklmnopqrstuvwxyz0123456789', usd: 1, note: 'n'), throwsArgumentError);
      l.record(run: 'T07', usd: 1, note: 'una nota normal');
      l.save();
      expect(File(path).readAsStringSync(), isNot(contains('sk-')));
    });

    test('save escribe de forma atómica: no deja el archivo a medias ni archivos temporales', () {
      seed([entry('a', 1.0)]);
      final l = ApiLedger.load(path)..record(run: 'b', usd: 2, note: 'n');
      l.save();
      expect(dir.listSync().map((e) => e.path.split('/').last), ['gasto.json']);
      expect(() => jsonDecode(File(path).readAsStringSync()), returnsNormally);
    });
  });

  group('spend: una corrida de pago BAJO el registro', () {
    test('no llama a la corrida si el guard se niega', () async {
      seed([entry('a', 40.0)]);
      final l = ApiLedger.load(path);
      var called = false;
      await expectLater(l.spend<double>(run: 'T07', capUsd: 5, body: () async {
        called = true;
        return 1.0;
      }, costOf: (x) => x, noteOf: (_) => 'n'), throwsStateError);
      expect(called, isFalse);
      expect(ApiLedger.load(path).spentUsd, 40.0, reason: 'nada se registró');
    });

    test('registra el gasto REAL al terminar y lo guarda', () async {
      seed([entry('a', 2.0)]);
      final l = ApiLedger.load(path);
      final r = await l.spend<({double cost, int calls})>(run: 'T07 ronda 2', capUsd: 12, body: () async => (cost: 8.75, calls: 900), costOf: (x) => x.cost, noteOf: (x) => '${x.calls} llamadas');
      expect(r.calls, 900);
      final again = ApiLedger.load(path);
      expect(again.spentUsd, closeTo(10.75, 1e-9));
      expect(again.entries.last.run, 'T07 ronda 2');
      expect(again.entries.last.note, '900 llamadas');
      expect(again.entries.last.estimated, isFalse);
    });

    test('una nota que PARECE una clave (p. ej. un hash de 40 caracteres) no impide registrar el gasto REAL: se anota sin la nota', () async {
      seed([entry('a', 2.0)]);
      final l = ApiLedger.load(path);
      await l.spend<double>(run: 'T07', capUsd: 12, body: () async => 8.0, costOf: (x) => x, noteOf: (_) => 'commit 0123456789abcdef0123456789abcdef01234567');
      final again = ApiLedger.load(path);
      expect(again.spentUsd, closeTo(10.0, 1e-9), reason: 'el dinero gastado se anota SIEMPRE');
      expect(again.entries.last.note, isNot(contains('0123456789abcdef')));
      expect(again.entries.last.note, contains('nota omitida'));
    });

    test('si armar la nota lanza una excepción, el gasto real se anota igual', () async {
      seed([entry('a', 2.0)]);
      final l = ApiLedger.load(path);
      await l.spend<double>(run: 'T07', capUsd: 12, body: () async => 8.0, costOf: (x) => x, noteOf: (_) => throw const FormatException('no se pudo'));
      final again = ApiLedger.load(path);
      expect(again.spentUsd, closeTo(10.0, 1e-9));
      expect(again.entries.last.estimated, isFalse, reason: 'el importe es real; sólo falta la nota');
      expect(again.entries.last.note, contains('nota omitida'));
    });

    test('si el importe que devuelve la corrida es inválido (NaN, negativo) se anota el TOPE como estimación y no se pierde el gasto', () async {
      for (final bad in [double.nan, -1.0, double.infinity]) {
        seed([entry('a', 2.0)]);
        final l = ApiLedger.load(path);
        await l.spend<double>(run: 'T07', capUsd: 12, body: () async => bad, costOf: (x) => x, noteOf: (_) => 'n');
        final again = ApiLedger.load(path);
        expect(again.spentUsd, closeTo(14.0, 1e-9), reason: '$bad: se cuenta el tope entero');
        expect(again.entries.last.estimated, isTrue, reason: '$bad');
      }
    });

    test('si la corrida FALLA registra el tope como estimación conservadora y relanza el error', () async {
      seed([entry('a', 2.0)]);
      final l = ApiLedger.load(path);
      await expectLater(l.spend<double>(run: 'T07', capUsd: 12, body: () async => throw const FormatException('se cayó'), costOf: (x) => x, noteOf: (_) => 'n'), throwsA(isA<FormatException>()));
      final again = ApiLedger.load(path);
      expect(again.spentUsd, closeTo(14.0, 1e-9), reason: 'el tope entero cuenta: no se sabe lo que alcanzó a gastar');
      expect(again.entries.last.estimated, isTrue);
      expect(again.entries.last.note, contains('falló'));
    });
  });

  group('reconcileTo (la consola manda)', () {
    test('añade un ajuste para que el total sea el de la consola, hacia arriba o hacia abajo, y lo marca', () {
      seed([entry('a', 10.0)]);
      final l = ApiLedger.load(path)..reconcileTo(consoleUsd: 12.5, note: 'consola 10 nov');
      expect(l.spentUsd, closeTo(12.5, 1e-9));
      expect(l.entries.last.run, 'ajuste a la consola');
      expect(l.entries.last.usd, closeTo(2.5, 1e-9));
      final down = ApiLedger.load(path)..reconcileTo(consoleUsd: 8.0, note: 'consola menor');
      expect(down.spentUsd, closeTo(8.0, 1e-9));
      expect(down.entries.last.usd, closeTo(-2.0, 1e-9), reason: 'un ajuste a la baja es el único importe negativo que se admite');
    });
  });
}
