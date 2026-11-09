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

/// Vínculos y grupos calculados en una sola pasada.
class GroupingResult {
  const GroupingResult(this.links, this.groups, this.comparisons);
  final List<Link> links;
  final List<Set<String>> groups;
  final int comparisons;
}

/// Una observación con lo que hace falta para decidir si compararla con otra.
class _Info {
  _Info(this.o)
    : precise = o.hasLocation && o.sigma! <= 200,
      cx = o.hasLocation ? (o.lat! / _cell).floor() : 0,
      cy = o.hasLocation ? (o.lon! / _cell).floor() : 0,
      tokens = contentTokens(o.text) {
    key = tokens.length >= _minKeyTokens ? (tokens.toList()..sort()).join(' ') : null;
  }
  final Observation o;
  final bool precise;
  final int cx, cy;
  final Set<String> tokens;

  /// Contenido canónico del texto (palabras de contenido ordenadas) si tiene al menos
  /// [_minKeyTokens] palabras: es lo que debe coincidir para comparar un reporte sin ubicación.
  late final String? key;
}

const double _cell = 0.0045; // ≈ 500 m: más que la suma de σ de dos reportes precisos (≤ 400 m)
const double _cellMeters = 500;
const double _maxSigma = 3000; // σ de la peor ubicación con coordenadas
const int _minKeyTokens = 5; // la masa de evidencia del texto: menos palabras no prueban nada

/// La **política de bloqueo**: ¿vale la pena puntuar este par?
///
///  · ventana de tiempo y tipo compatible;
///  · si **alguno no tiene ubicación**, sólo se comparan los que tienen el MISMO contenido de texto
///    (al menos 5 palabras de contenido iguales, sin importar orden, mayúsculas, tildes ni
///    muletillas). Es conservador a propósito: con el umbral de «sin ubicación» (0,92) y la masa de
///    evidencia del texto, sólo textos casi idénticos podían ser `same`, y así ningún reporte sin
///    ubicación obliga a recorrer a todos los demás;
///  · con ubicación en ambos no hay política de texto: lo decide el puntaje (un par más lejos que
///    σ₁+σ₂ no tiene término espacial y su puntaje máximo, 0,60, queda bajo θhi).
bool blockingPolicyAllows(Observation a, Observation b, {Duration window = const Duration(hours: 3)}) =>
    _policy(_Info(a), _Info(b), window);

bool _policy(_Info a, _Info b, Duration window) {
  if ((a.o.capturedAtMs - b.o.capturedAtMs).abs() > window.inMilliseconds) return false;
  if (!typesCompatible(a.o.incidentType, b.o.incidentType)) return false;
  if (!a.o.hasLocation || !b.o.hasLocation) return a.key != null && a.key == b.key;
  return true;
}

/// La política más el bloqueo espacial: si ambos tienen ubicación, sólo se comparan los que están
/// más cerca que σ₁+σ₂ (más lejos no hay término espacial y el puntaje máximo, 0,60, queda bajo θhi:
/// nunca serían `same`; tampoco se sugieren). Es una optimización de lo que decide el puntaje.
/// Devuelve la distancia si se puede calcular (para no repetirla al ordenar).
({bool ok, double? d}) _canCompare(_Info a, _Info b, Duration window) {
  if (!_policy(a, b, window)) return (ok: false, d: null);
  if (a.o.hasLocation && b.o.hasLocation) {
    final d = distanceMeters(a.o.lat!, a.o.lon!, b.o.lat!, b.o.lon!);
    return (ok: d < a.o.sigma! + b.o.sigma!, d: d);
  }
  return (ok: true, d: null);
}

/// Orden de preferencia de un candidato (más pequeño = antes): primero los espacialmente
/// compatibles, luego los que comparten más palabras, luego los más cercanos en el tiempo y en el
/// espacio, y por último la clave (para que el resultado no dependa del orden de llegada).
typedef _Rank = (int, int, int, double);

_Rank _rank(_Info q, _Info c, double? d) {
  final compatible = d == null || d < q.o.sigma! + c.o.sigma!;
  // con el mismo contenido de texto no hace falta intersectar los conjuntos de palabras
  final overlap = (q.key != null && q.key == c.key) ? q.tokens.length : q.tokens.intersection(c.tokens).length;
  return (compatible ? 0 : 1, -overlap, (q.o.capturedAtMs - c.o.capturedAtMs).abs(), d ?? 1e18);
}

int _compareRanks(_Rank a, _Rank b) {
  var c = a.$1.compareTo(b.$1);
  if (c != 0) return c;
  c = a.$2.compareTo(b.$2);
  if (c != 0) return c;
  c = a.$3.compareTo(b.$3);
  if (c != 0) return c;
  return a.$4.compareTo(b.$4);
}

List<_Info> _canonical(Iterable<Observation> input) {
  final byKey = <String, Observation>{};
  for (final o in input) {
    byKey[o.reportKey] = o; // la última gana: las revisiones ya vienen fundidas
  }
  final keys = byKey.keys.toList()..sort();
  return [for (final k in keys) _Info(byKey[k]!)];
}

LinkResult _computeLinks(List<_Info> infos, Weights weights, int maxCandidates, Duration window) {
  final n = infos.length;

  // Índices. Sin ellos cada reporte recorrería a todos los demás (cuadrático: 4 min con 10 000).
  final fine = <(int, int), List<int>>{}; // sólo precisos, por celda
  final wide = <(int, int), List<int>>{}; // todos los que tienen ubicación, por celda
  final byKey = <String, List<int>>{}; // todos los que tienen texto con contenido suficiente
  for (var i = 0; i < n; i++) {
    final x = infos[i];
    if (x.o.hasLocation) {
      (wide[(x.cx, x.cy)] ??= []).add(i);
      if (x.precise) (fine[(x.cx, x.cy)] ??= []).add(i);
    }
    if (x.key != null) (byKey[x.key!] ??= []).add(i);
  }

  final pairs = <int>{}; // i*n + j con i < j
  for (var i = 0; i < n; i++) {
    final q = infos[i];
    final cand = <int>{};
    if (!q.o.hasLocation) {
      // Un reporte sin ubicación sólo compara con los de su mismo contenido de texto.
      if (q.key != null) cand.addAll(byKey[q.key!]!);
    } else if (q.precise) {
      // Un preciso mira las 8 celdas vecinas de precisos; los imprecisos que lo cubren lo encuentran
      // ellos mismos (ver abajo), y los sin ubicación también.
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          cand.addAll(fine[(q.cx + dx, q.cy + dy)] ?? const <int>[]);
        }
      }
    } else {
      // Un impreciso mira todos los localizados que caen dentro de σ₁+σ₂ (con σ₂ ≤ 3 km).
      final r = ((q.o.sigma! + _maxSigma) / _cellMeters).ceil();
      for (var dx = -r; dx <= r; dx++) {
        for (var dy = -r; dy <= r; dy++) {
          cand.addAll(wide[(q.cx + dx, q.cy + dy)] ?? const <int>[]);
        }
      }
    }
    cand.remove(i);
    final ranked = <(_Rank, int)>[
      for (final j in cand)
        if (_canCompare(q, infos[j], window) case (ok: true, :final d)) (_rank(q, infos[j], d), j),
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

/// Puntúa los pares candidatos de [all] y devuelve los vínculos `same` y `possible`.
///
/// Es **independiente del orden de entrada**: cada observación evalúa como mucho [maxCandidates]
/// candidatos elegidos con un orden total determinista, y un par se puntúa si lo elige cualquiera
/// de los dos. Con `maxCandidates` ilimitado el resultado es el de comparar todos con todos entre
/// los pares que permite [blockingPolicyAllows].
LinkResult computeLinks(
  List<Observation> all, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
}) => _computeLinks(_canonical(all), weights, maxCandidates, window);

/// Los vínculos de UN reporte [o] contra los ya conocidos [known] (para dejar rastro de auditoría
/// al ingerirlo). Aplica la misma política de bloqueo y el mismo orden de candidatos.
List<Link> linksFor(
  Observation o,
  Iterable<Observation> known, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
}) {
  final q = _Info(o);
  final ranked = <(_Rank, _Info)>[];
  for (final k in known) {
    if (k.reportKey == o.reportKey) continue;
    final c = _Info(k);
    final r = _canCompare(q, c, window);
    if (r.ok) ranked.add((_rank(q, c, r.d), c));
  }
  ranked.sort((x, y) {
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

/// Forma los grupos: componentes conexos de los vínculos `same` con UNA restricción.
///
/// Un reporte de **poca evidencia espacial** (sin ubicación o impreciso) puede sumarse a un grupo
/// pero **no puede unir dos grupos que ya tienen un reporte localizado con precisión** (un «ancla»):
/// sin esta regla, un solo reporte sin ubicación con un texto común enlaza con dos grupos lejanos y,
/// por transitividad, los fusiona (en el banco de pruebas salió un grupo de 1 705 reportes que
/// abarcaba 27 km). Los vínculos entre dos anclas nunca se frenan. Los vínculos se procesan en un
/// orden canónico (anclas primero; luego por puntaje descendente y claves) para que el resultado no
/// dependa del orden de llegada. Un vínculo `same` frenado queda disponible como sugerencia.
List<Set<String>> _groups(List<_Info> infos, List<Link> links, Set<(String, String)> unlinked) {
  final parent = <String, String>{for (final i in infos) i.o.reportKey: i.o.reportKey};
  final anchored = <String>{for (final i in infos) if (i.precise) i.o.reportKey}; // raíces con algún ancla
  final isAnchor = {for (final i in infos) i.o.reportKey: i.precise};
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

  void union(String ra, String rb) {
    // la raíz es siempre la clave más pequeña: el resultado no depende del orden de unión
    final root = ra.compareTo(rb) < 0 ? ra : rb;
    final other = root == ra ? rb : ra;
    final hasAnchor = anchored.contains(ra) || anchored.contains(rb);
    parent[other] = root;
    anchored.remove(other);
    if (hasAnchor) anchored.add(root);
  }

  final same = [
    for (final l in links)
      if (l.pair.state == LinkState.same && !unlinked.contains(pairKey(l.a, l.b))) l,
  ];
  bool anchorLink(Link l) => isAnchor[l.a]! && isAnchor[l.b]!;
  same.sort((x, y) {
    final ax = anchorLink(x), ay = anchorLink(y);
    if (ax != ay) return ax ? -1 : 1;
    final c = y.pair.score.compareTo(x.pair.score);
    if (c != 0) return c;
    return x.a != y.a ? x.a.compareTo(y.a) : x.b.compareTo(y.b);
  });
  for (final l in same) {
    final ra = find(l.a), rb = find(l.b);
    if (ra == rb) continue;
    if (!anchorLink(l) && anchored.contains(ra) && anchored.contains(rb)) continue; // no hace de puente
    union(ra, rb);
  }
  final groups = <String, Set<String>>{};
  for (final i in infos) {
    groups.putIfAbsent(find(i.o.reportKey), () => <String>{}).add(i.o.reportKey);
  }
  final keys = groups.keys.toList()..sort();
  return [for (final k in keys) groups[k]!];
}

/// Vínculos **y** grupos en una sola pasada (así quien necesite ambos no puntúa dos veces).
///
/// Los grupos son los componentes conexos de los vínculos `same` (menos los [unlinked]): **función
/// pura de las observaciones fusionadas**, sin depender del orden de entrada ni de qué nodo vio qué,
/// y por tanto segura ante la replicación. Nunca borra ni modifica una observación: todo reporte
/// pertenece a exactamente un grupo (aunque sea él solo), ordenados por su clave más pequeña.
GroupingResult analyzeGrouping(
  List<Observation> all, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
  Set<(String, String)> unlinked = const {},
}) {
  final infos = _canonical(all);
  final res = _computeLinks(infos, weights, maxCandidates, window);
  return GroupingResult(res.links, _groups(infos, res.links, unlinked), res.comparisons);
}

/// Los grupos que resultan de unos vínculos YA puntuados (para barrer umbrales sin volver a puntuar):
/// aplica exactamente la misma formación de grupos —incluida la regla anti-puente— que
/// [analyzeGrouping].
List<Set<String>> groupsFromLinks(List<Observation> all, List<Link> links, {Set<(String, String)> unlinked = const {}}) =>
    _groups(_canonical(all), links, unlinked);

/// Sólo los grupos de [all] (ver [analyzeGrouping]).
List<Set<String>> groupObservations(
  List<Observation> all, {
  Weights weights = const Weights(),
  int maxCandidates = 20,
  Duration window = const Duration(hours: 3),
  Set<(String, String)> unlinked = const {},
}) => analyzeGrouping(all, weights: weights, maxCandidates: maxCandidates, window: window, unlinked: unlinked).groups;

/// Atajo: reportKey → identificador de su grupo (la clave más pequeña del grupo).
Map<String, String> groupIds(List<Set<String>> groups) => {
  for (final g in groups)
    for (final k in g) k: (g.toList()..sort()).first,
};

/// Cota para pruebas: un `maxCandidates` «sin límite».
const int kNoCandidateLimit = 1 << 30;
