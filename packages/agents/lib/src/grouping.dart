import 'correlation.dart';
import 'geo.dart';
import 'text_sim.dart';

/// Un par de claves en orden canónico.
(String, String) pairKey(String a, String b) => a.compareTo(b) <= 0 ? (a, b) : (b, a);

/// El SOS genérico (tipo 1) es compatible con cualquier tipo; los demás sólo con el mismo.
bool typesCompatible(int a, int b) => a == b || a == 1 || b == 1;

class Link {
  const Link(this.a, this.b, this.pair);
  final String a;
  final String b;
  final PairScore pair;
}

class LinkResult {
  const LinkResult(this.links, this.comparisons);
  final List<Link> links;

  /// Cuántos pares se puntuaron (para comprobar que el bloqueo evita comparar todo con todo).
  final int comparisons;
}

/// Una observación con lo que hace falta para decidir si compararla con otra.
class _Info {
  _Info(this.o)
    : precise = o.hasLocation && o.sigma! <= 200,
      cx = o.hasLocation ? (o.lat! / _cell).floor() : 0,
      cy = o.hasLocation ? (o.lon! / _cell).floor() : 0,
      tokens = contentTokens(o.text);
  final Observation o;
  final bool precise;
  final int cx, cy;
  final Set<String> tokens;
}

const double _cell = 0.01; // ≈ 1,1 km: más que la suma de σ de dos reportes precisos (≤ 400 m)

/// ¿Vale la pena puntuar este par? Ventana de tiempo, tipo compatible y, entre dos reportes
/// precisos, celdas vecinas. Si alguno es impreciso o no tiene ubicación no hay bloqueo espacial.
///
/// Un par más lejos que σ₁+σ₂ no tiene término espacial y su puntaje máximo (0,60) queda bajo
/// θhi: nunca sería `same`, así que no hace falta encontrarlo.
bool _canCompare(_Info a, _Info b, Duration window) {
  if ((a.o.capturedAtMs - b.o.capturedAtMs).abs() > window.inMilliseconds) return false;
  if (!typesCompatible(a.o.incidentType, b.o.incidentType)) return false;
  if (a.precise && b.precise) return (a.cx - b.cx).abs() <= 1 && (a.cy - b.cy).abs() <= 1;
  return true;
}

/// Orden de preferencia de un candidato (más pequeño = antes): primero los espacialmente
/// compatibles, luego los que comparten más palabras, luego los más cercanos en el tiempo y en el
/// espacio, y por último la clave (para que el resultado no dependa del orden de llegada).
List<num> _rank(_Info q, _Info c) {
  double? d;
  if (q.o.hasLocation && c.o.hasLocation) {
    d = distanceMeters(q.o.lat!, q.o.lon!, c.o.lat!, c.o.lon!);
  }
  final compatible = d == null || d < q.o.sigma! + c.o.sigma!;
  final overlap = q.tokens.intersection(c.tokens).length;
  return [
    compatible ? 0 : 1,
    -overlap,
    (q.o.capturedAtMs - c.o.capturedAtMs).abs(),
    d ?? 1e18,
  ];
}

int _compareRanks(List<num> a, List<num> b) {
  for (var i = 0; i < a.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}

List<_Info> _canonical(Iterable<Observation> input) {
  final byKey = <String, Observation>{};
  for (final o in input) {
    byKey[o.reportKey] = o; // la última gana: las revisiones ya vienen fundidas
  }
  final keys = byKey.keys.toList()..sort();
  return [for (final k in keys) _Info(byKey[k]!)];
}

/// Puntúa los pares candidatos de [all] y devuelve los vínculos `same` y `possible`.
///
/// Es **independiente del orden de entrada**: cada observación evalúa como mucho [maxCandidates]
/// candidatos elegidos con un orden total determinista, y un par se puntúa si lo elige cualquiera
/// de los dos. Con `maxCandidates` ilimitado el resultado es el de comparar todos con todos entre
/// los pares que superan el bloqueo.
LinkResult computeLinks(
  List<Observation> all, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
}) {
  final infos = _canonical(all);
  final n = infos.length;

  // Índices: celdas para los precisos; listas para imprecisos y sin ubicación; orden por tiempo.
  final cells = <(int, int), List<int>>{};
  final loose = <int>[]; // imprecisos y sin ubicación: se comparan con todo lo de la ventana
  for (var i = 0; i < n; i++) {
    if (infos[i].precise) {
      (cells[(infos[i].cx, infos[i].cy)] ??= []).add(i);
    } else {
      loose.add(i);
    }
  }
  final byTime = List<int>.generate(n, (i) => i)
    ..sort((x, y) {
      final c = infos[x].o.capturedAtMs.compareTo(infos[y].o.capturedAtMs);
      return c != 0 ? c : x.compareTo(y);
    });
  final times = [for (final i in byTime) infos[i].o.capturedAtMs];

  int lowerBound(int t) {
    var lo = 0, hi = n;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  final pairs = <int>{}; // i*n + j con i < j
  for (var i = 0; i < n; i++) {
    final q = infos[i];
    final cand = <int>{};
    if (q.precise) {
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          cand.addAll(cells[(q.cx + dx, q.cy + dy)] ?? const <int>[]);
        }
      }
      cand.addAll(loose);
    } else {
      final w = window.inMilliseconds;
      for (var k = lowerBound(q.o.capturedAtMs - w); k < n && times[k] <= q.o.capturedAtMs + w; k++) {
        cand.add(byTime[k]);
      }
    }
    cand.remove(i);
    final ranked = <(List<num>, int)>[
      for (final j in cand)
        if (_canCompare(q, infos[j], window)) (_rank(q, infos[j]), j),
    ]..sort((x, y) {
        final c = _compareRanks(x.$1, y.$1);
        return c != 0 ? c : infos[x.$2].o.reportKey.compareTo(infos[y.$2].o.reportKey);
      });
    for (final (_, j) in ranked.take(maxCandidates)) {
      pairs.add(i < j ? i * n + j : j * n + i);
    }
  }

  final links = <Link>[];
  var comparisons = 0;
  for (final p in pairs) {
    final i = p ~/ n, j = p % n;
    comparisons++;
    final s = scorePair(infos[i].o, infos[j].o, weights);
    if (s.state != LinkState.different) links.add(Link(infos[i].o.reportKey, infos[j].o.reportKey, s));
  }
  links.sort((x, y) => x.a != y.a ? x.a.compareTo(y.a) : x.b.compareTo(y.b));
  return LinkResult(links, comparisons);
}

/// Los vínculos de UN reporte [o] contra los ya conocidos [known] (para dejar rastro de auditoría
/// al ingerirlo). Aplica el mismo bloqueo y el mismo orden de candidatos que [computeLinks].
List<Link> linksFor(
  Observation o,
  Iterable<Observation> known, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
}) {
  final q = _Info(o);
  final ranked = <(List<num>, _Info)>[
    for (final k in known)
      if (k.reportKey != o.reportKey)
        if (_canCompare(q, _Info(k), window)) (_rank(q, _Info(k)), _Info(k)),
  ]..sort((x, y) {
      final c = _compareRanks(x.$1, y.$1);
      return c != 0 ? c : x.$2.o.reportKey.compareTo(y.$2.o.reportKey);
    });
  final out = <Link>[];
  for (final (_, c) in ranked.take(maxCandidates)) {
    final s = scorePair(o, c.o, weights);
    if (s.state != LinkState.different) out.add(Link(o.reportKey, c.o.reportKey, s));
  }
  return out;
}

/// Grupos de [all]: los componentes conexos de los vínculos `same` (menos los [unlinked]).
///
/// **Función pura de las observaciones fusionadas**: no depende del orden de entrada ni de qué
/// nodo vio qué, y por eso es segura ante la replicación. Nunca borra ni modifica una observación:
/// todo reporte pertenece a exactamente un grupo (aunque sea él solo). Los grupos salen ordenados
/// por su clave más pequeña.
List<Set<String>> groupObservations(
  List<Observation> all, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
  Set<(String, String)> unlinked = const {},
}) {
  final infos = _canonical(all);
  final parent = <String, String>{for (final i in infos) i.o.reportKey: i.o.reportKey};
  String find(String x) {
    var r = x;
    while (parent[r] != r) {
      r = parent[r]!;
    }
    var c = x;
    while (parent[c] != r) {
      final nx = parent[c]!;
      parent[c] = r;
      c = nx;
    }
    return r;
  }

  final res = computeLinks(all, weights: weights, maxCandidates: maxCandidates, window: window);
  for (final l in res.links) {
    if (l.pair.state != LinkState.same) continue;
    if (unlinked.contains(pairKey(l.a, l.b))) continue;
    final ra = find(l.a), rb = find(l.b);
    if (ra == rb) continue;
    // la raíz es siempre la clave más pequeña: el resultado no depende del orden de unión
    if (ra.compareTo(rb) < 0) {
      parent[rb] = ra;
    } else {
      parent[ra] = rb;
    }
  }
  final groups = <String, Set<String>>{};
  for (final i in infos) {
    groups.putIfAbsent(find(i.o.reportKey), () => <String>{}).add(i.o.reportKey);
  }
  final keys = groups.keys.toList()..sort();
  return [for (final k in keys) groups[k]!];
}

/// Atajo: reportKey → identificador de su grupo (la clave más pequeña del grupo).
Map<String, String> groupIds(List<Set<String>> groups) => {
  for (final g in groups)
    for (final k in g) k: (g.toList()..sort()).first,
};

/// Cota para pruebas: un `maxCandidates` «sin límite».
const int kNoCandidateLimit = 1 << 30;
