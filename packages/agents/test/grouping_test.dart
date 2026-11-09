import 'dart:math';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';
import 'package:test/test.dart';

const double _lat = 5.07, _lon = -75.52;
final int _t0 = DateTime.utc(2026, 8, 10, 14).millisecondsSinceEpoch;
double _east(double m) => _lon + m / (111320.0 * cos(_lat * pi / 180));
double _north(double m) => _lat + m / 111320.0;

const String _t = 'puente colapsado calle veinte carros abajo';

Observation obs(
  String key, {
  double? eastM = 0,
  double northM = 0,
  LocQuality q = LocQuality.within50m,
  int dtMs = 0,
  int type = 1,
  String? text = _t,
  String device = '',
}) => Observation(
  reportKey: key,
  deviceId: device.isEmpty ? 'dev-$key' : device,
  incidentType: type,
  flags: 0,
  lat: eastM == null ? null : _north(northM),
  lon: eastM == null ? null : _east(eastM),
  locQuality: eastM == null ? LocQuality.none : q,
  capturedAtMs: _t0 + dtMs,
  text: text,
  sourceClass: 'app',
);

Set<String> g(List<Set<String>> groups, String key) => groups.firstWhere((s) => s.contains(key));

void main() {
  group('agrupar: sólo `same` une; `possible` sólo se sugiere', () {
    test('dos reportes en el mismo punto, hora y texto forman un grupo; uno lejano queda aparte', () {
      final groups = groupObservations([obs('a'), obs('b', eastM: 10), obs('c', eastM: 5000)]);
      expect(g(groups, 'a'), {'a', 'b'});
      expect(g(groups, 'c'), {'c'});
    });

    test('sin texto el puntaje queda en 0,70 (possible): NO agrupa', () {
      final groups = groupObservations([obs('a', text: null), obs('b', text: null)]);
      expect(groups, hasLength(2));
    });

    test('la cadena A~B y B~C une a los tres (componentes conexos), aunque A y C no sean pareja directa', () {
      // a—b y b—c a 30 m (puntaje 0,88: same); a—c a 60 m queda en 0,76 (possible, no une por sí solo)
      final groups = groupObservations([obs('a'), obs('b', eastM: 30), obs('c', eastM: 60)]);
      expect(groups, hasLength(1));
    });

    test('todo reporte pertenece a exactamente un grupo (nada desaparece)', () {
      final all = [for (var i = 0; i < 30; i++) obs('r$i', eastM: i * 700.0, text: 'texto $i distinto')];
      final groups = groupObservations(all);
      final flat = groups.expand((s) => s).toList();
      expect(flat.length, 30);
      expect(flat.toSet().length, 30);
    });
  });

  group('bloqueo: ventana, tipo y dispositivo', () {
    test('idénticos pero con 4 h de diferencia (fuera de la ventana de 3 h) NO se agrupan', () {
      expect(groupObservations([obs('a'), obs('b', dtMs: 4 * 3600000)]), hasLength(2));
    });

    test('tipos incompatibles (2 y 3) no se agrupan; el SOS genérico (1) es compatible con cualquiera', () {
      expect(groupObservations([obs('a', type: 2), obs('b', type: 3)]), hasLength(2));
      expect(groupObservations([obs('a', type: 1), obs('b', type: 2)]), hasLength(1));
    });

    test('un reporte sin ubicación sólo se une con texto idéntico y a la misma hora (umbral estricto)', () {
      expect(groupObservations([obs('a', eastM: null), obs('b', eastM: null)]), hasLength(1));
      expect(
        groupObservations([obs('a', eastM: null), obs('b', eastM: null, text: 'otra cosa totalmente distinta aquí')]),
        hasLength(2),
      );
    });

    test('un reporte impreciso (over1km) puede unirse a uno preciso cercano con el mismo texto', () {
      final groups = groupObservations([obs('a', q: LocQuality.over1km), obs('b', eastM: 400, q: LocQuality.within10m)]);
      expect(groups, hasLength(1));
    });
  });

  group('reversible y sin pérdida', () {
    test('desvincular un par lo separa y se puede deshacer', () {
      final all = [obs('a'), obs('b', eastM: 10)];
      expect(groupObservations(all), hasLength(1));
      expect(groupObservations(all, unlinked: {pairKey('a', 'b')}), hasLength(2));
      expect(groupObservations(all), hasLength(1));
    });

    test('un reporte que primero no tenía ubicación y luego la recibe se re-puntúa y se une', () {
      final antes = [obs('a', text: 'texto largo y bien distinto del otro reporte'), obs('b', eastM: null, text: _t)];
      expect(groupObservations(antes), hasLength(2));
      final despues = [obs('a'), obs('b', eastM: 10, text: _t)]; // llega la revisión con GPS
      expect(groupObservations(despues), hasLength(1));
    });

    test('dos observaciones con la misma clave: gana la última (las revisiones ya vienen fundidas)', () {
      final groups = groupObservations([obs('a', eastM: 5000), obs('b'), obs('a')]);
      expect(g(groups, 'a'), {'a', 'b'});
    });
  });

  group('determinismo: el resultado no depende del orden de entrada', () {
    test('con un tope de candidatos pequeño y muchos reportes casi idénticos, 25 barajas dan los mismos grupos', () {
      final all = [
        for (var i = 0; i < 25; i++)
          obs('r${i.toString().padLeft(2, '0')}', eastM: (i % 5) * 8.0, northM: (i ~/ 5) * 8.0, dtMs: i * 20000),
      ];
      String sig(List<Set<String>> gs) => (gs.map((s) => (s.toList()..sort()).join(',')).toList()..sort()).join('|');
      final ref = sig(groupObservations(all, maxCandidates: 3));
      final r = Random(3);
      for (var k = 0; k < 25; k++) {
        final sh = [...all]..shuffle(r);
        expect(sig(groupObservations(sh, maxCandidates: 3)), ref);
      }
    });

    test('los grupos se devuelven en un orden estable (por la clave más pequeña)', () {
      final groups = groupObservations([obs('z', eastM: 9000), obs('b'), obs('a', eastM: 5), obs('m', eastM: 20000)]);
      final mins = groups.map((s) => (s.toList()..sort()).first).toList();
      expect(mins, [...mins]..sort());
    });
  });

  group('el bloqueo por celdas no pierde pares cerca de una frontera de celda', () {
    // Dos reportes con ±200 m cada uno a 120 m de distancia, mismo texto y hora: puntaje 0,88 (same).
    // Se barren posiciones para que en algún caso queden a ambos lados de una frontera de celda.
    test('barrido en longitud', () {
      for (var k = 0; k < 60; k++) {
        final shift = k * 0.00037;
        final a = Observation(
          reportKey: 'a', deviceId: 'da', incidentType: 1, flags: 0,
          lat: _lat, lon: _lon + shift, locQuality: LocQuality.within200m,
          capturedAtMs: _t0, text: _t, sourceClass: 'app',
        );
        final b = Observation(
          reportKey: 'b', deviceId: 'db', incidentType: 1, flags: 0,
          lat: _lat, lon: _lon + shift + 120 / (111320.0 * cos(_lat * pi / 180)), locQuality: LocQuality.within200m,
          capturedAtMs: _t0, text: _t, sourceClass: 'app',
        );
        expect(groupObservations([a, b]), hasLength(1), reason: 'desplazamiento $k');
      }
    });

    test('barrido en latitud', () {
      for (var k = 0; k < 60; k++) {
        final shift = k * 0.00037;
        final a = Observation(
          reportKey: 'a', deviceId: 'da', incidentType: 1, flags: 0,
          lat: _lat + shift, lon: _lon, locQuality: LocQuality.within200m,
          capturedAtMs: _t0, text: _t, sourceClass: 'app',
        );
        final b = Observation(
          reportKey: 'b', deviceId: 'db', incidentType: 1, flags: 0,
          lat: _lat + shift + 120 / 111320.0, lon: _lon, locQuality: LocQuality.within200m,
          capturedAtMs: _t0, text: _t, sourceClass: 'app',
        );
        expect(groupObservations([a, b]), hasLength(1), reason: 'desplazamiento $k');
      }
    });
  });

  group('un reporte de poca evidencia espacial NO puede unir dos grupos lejanos (hallazgo del banco de pruebas: 1 705 reportes en 27 km)', () {
    test('sin ubicación: se une a UNO de los dos grupos, pero A y B (a 20 km) siguen separados', () {
      final groups = groupObservations([
        obs('a', eastM: 0, q: LocQuality.within10m),
        obs('b', eastM: 20000, q: LocQuality.within10m),
        obs('u', eastM: null),
      ]);
      expect(groups, hasLength(2));
      expect(g(groups, 'a').contains('b'), isFalse);
      expect(g(groups, 'u').length, 2, reason: 'u se sumó a uno de los dos');
    });

    test('impreciso (σ 3 km) entre dos precisos a 2 km: tampoco los une', () {
      final groups = groupObservations([
        obs('a', eastM: -1000, q: LocQuality.within10m),
        obs('b', eastM: 1000, q: LocQuality.within10m),
        obs('i', eastM: 0, q: LocQuality.over1km),
      ]);
      expect(groups, hasLength(2));
      expect(g(groups, 'a').contains('b'), isFalse);
    });

    test('dos sin ubicación enlazados, cada uno ya pegado a un grupo distinto, tampoco los unen', () {
      final groups = groupObservations([
        obs('a', eastM: 0, q: LocQuality.within10m),
        obs('b', eastM: 20000, q: LocQuality.within10m),
        obs('u1', eastM: null),
        obs('u2', eastM: null),
      ]);
      expect(g(groups, 'a').contains('b'), isFalse);
    });

    test('un rumor copiado (sin ubicación, sin anclas) SÍ forma un solo grupo aunque cada copia sólo mire a 3 vecinas', () {
      final copies = [for (var i = 0; i < 60; i++) obs('c${i.toString().padLeft(2, '0')}', eastM: null, dtMs: i * 7000)];
      expect(groupObservations(copies, maxCandidates: 3), hasLength(1));
    });

    test('dos precisos que SÍ son el mismo suceso se unen siempre (la regla no frena ancla con ancla)', () {
      expect(groupObservations([obs('a', q: LocQuality.within10m), obs('b', eastM: 5, q: LocQuality.within10m)]), hasLength(1));
    });

    test('con la regla, el resultado sigue sin depender del orden de llegada (25 barajas)', () {
      final all = [
        obs('a', eastM: 0, q: LocQuality.within10m),
        obs('b', eastM: 20000, q: LocQuality.within10m),
        obs('c', eastM: 20005, q: LocQuality.within10m),
        obs('u1', eastM: null),
        obs('u2', eastM: null, dtMs: 30000),
        obs('i', eastM: 10, q: LocQuality.over1km),
      ];
      String sig(List<Set<String>> gs) => (gs.map((x) => (x.toList()..sort()).join(',')).toList()..sort()).join('|');
      final ref = sig(groupObservations(all));
      final r = Random(11);
      for (var k = 0; k < 25; k++) {
        expect(sig(groupObservations([...all]..shuffle(r))), ref);
      }
    });
  });

  group('política de bloqueo sin ubicación: sólo con el MISMO contenido de texto', () {
    test('sin ubicación, textos iguales salvo una falta de ortografía NO se agrupan (conservador a propósito)', () {
      final groups = groupObservations([
        obs('a', eastM: null, text: 'puente colapsado calle veinte carros abajo'),
        obs('b', eastM: null, text: 'puente colapsado calle veinte carros abjo'),
      ]);
      expect(groups, hasLength(2));
    });

    test('el orden de las palabras, las mayúsculas, las tildes y las muletillas no cambian «el mismo contenido»', () {
      final groups = groupObservations([
        obs('a', eastM: null, text: 'puente colapsado calle veinte carros abajo'),
        obs('b', eastM: null, text: 'CARROS ABAJO, puente colapsado, calle veinte, por favor ayuda'),
      ]);
      expect(groups, hasLength(1));
    });

    test('blockingPolicyAllows: ventana, tipo y, sin ubicación, texto idéntico de al menos 5 palabras', () {
      final a = obs('a', eastM: null, text: 'puente colapsado calle veinte carros abajo');
      expect(blockingPolicyAllows(a, obs('b', eastM: null, text: 'abajo carros veinte calle colapsado puente')), isTrue);
      expect(blockingPolicyAllows(a, obs('b', eastM: null, text: 'otra cosa totalmente distinta aquí ahora mismo')), isFalse);
      expect(blockingPolicyAllows(a, obs('b', eastM: 0, text: 'puente colapsado calle veinte carros abajo')), isTrue, reason: 'un reporte sin ubicación también compara con uno que sí la tiene');
      expect(blockingPolicyAllows(obs('c', eastM: null, text: 'hay un incendio'), obs('d', eastM: null, text: 'hay un incendio')), isFalse, reason: 'una frase corta no basta');
      expect(blockingPolicyAllows(a, obs('b', eastM: null, text: 'puente colapsado calle veinte carros abajo', dtMs: 4 * 3600000)), isFalse);
      expect(blockingPolicyAllows(obs('e', type: 2), obs('f', type: 3)), isFalse);
      expect(blockingPolicyAllows(obs('g'), obs('h', eastM: 5000)), isTrue, reason: 'con ubicación en ambos no hay política de texto: lo decide el puntaje');
    });
  });

  group('rendimiento: la lectura no puede ser cuadrática', () {
    test('3 000 reportes (10 % sin ubicación, 5 % imprecisos, muchos con el mismo texto) se agrupan en menos de 4 s', () {
      final r = Random(9);
      final all = <Observation>[
        for (var i = 0; i < 3000; i++)
          obs(
            'r${i.toString().padLeft(5, '0')}',
            eastM: i % 10 == 0 ? null : r.nextDouble() * 20000,
            northM: r.nextDouble() * 20000,
            q: i % 20 == 3 ? LocQuality.over1km : LocQuality.within50m,
            dtMs: r.nextInt(2 * 3600000),
            text: i % 3 == 0 ? _t : (i % 3 == 1 ? 'otro texto distinto numero ${i % 7} para este reporte' : null),
          ),
      ];
      final sw = Stopwatch()..start();
      final g = groupObservations(all);
      sw.stop();
      expect(g.expand((s) => s).length, 3000);
      expect(sw.elapsedMilliseconds, lessThan(4000), reason: 'tardó ${sw.elapsedMilliseconds} ms');
    });

    test('analyzeGrouping da los mismos grupos que groupObservations y expone los vínculos puntuados una sola vez', () {
      final all = [obs('a'), obs('b', eastM: 10), obs('c', eastM: 5000)];
      final r = analyzeGrouping(all);
      expect(r.groups, groupObservations(all));
      expect(r.links.where((l) => l.pair.state == LinkState.same), hasLength(1));
      expect(r.comparisons, greaterThan(0));
    });
  });

  group('bloqueo eficiente', () {
    test('600 reportes repartidos por una ciudad se comparan MUCHO menos que todos con todos', () {
      final r = Random(5);
      final all = [
        for (var i = 0; i < 600; i++)
          obs('r$i', eastM: r.nextDouble() * 20000, northM: r.nextDouble() * 20000, dtMs: r.nextInt(2 * 3600000), text: 'texto $i'),
      ];
      final res = computeLinks(all);
      const bruteForce = 600 * 599 ~/ 2;
      expect(res.comparisons, lessThan(bruteForce ~/ 20), reason: '${res.comparisons} comparaciones frente a $bruteForce');
    });

    test('linksFor devuelve los vínculos de UN reporte nuevo contra los ya conocidos (≤ K)', () {
      final known = [obs('a'), obs('b', eastM: 10), obs('c', eastM: 9000)];
      final links = linksFor(obs('n', eastM: 5), known);
      expect(links.map((l) => l.b).toSet(), {'a', 'b'});
      expect(links.every((l) => l.pair.state == LinkState.same), isTrue);
      expect(linksFor(obs('n', eastM: 5), known, maxCandidates: 1), hasLength(1));
    });
  });
}
