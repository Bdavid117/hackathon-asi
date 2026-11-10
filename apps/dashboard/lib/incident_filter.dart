import 'incident_card.dart' show headlineOf;
import 'models.dart';

// Filtros y búsqueda del tablero, sobre los incidentes YA CARGADOS (el nodo es quien cuenta el total).
//
// Regla central: un filtro nunca esconde nada sin decirlo. Todo lo que oculta se cuenta, y de eso se dice cuántos
// son P1 (un P1 escondido por una búsqueda es el error que más cuesta). El filtro activo siempre se puede leer.

/// Las marcas que se pueden activar. Cada una acota (se suman: «sin ubicación» Y «incertidumbre alta»).
enum FilterFlag {
  noLocation('Sin ubicación'),
  singleSource('Fuente única'),
  secondHand('De segunda mano'),
  highUncertainty('Incertidumbre alta'),
  needsReview('A revisar'),
  pending('Pendientes de decisión');

  const FilterFlag(this.label);
  final String label;

  bool matches(IncidentRow r) => switch (this) {
    FilterFlag.noLocation => !r.hasLocation,
    FilterFlag.singleSource => r.sources == 1,
    FilterFlag.secondHand => r.hasDispatch,
    FilterFlag.highUncertainty => r.highUncertainty,
    FilterFlag.needsReview => r.needsReview,
    FilterFlag.pending => r.isPendingDecision,
  };
}

/// El resultado de aplicar un filtro: lo que se ve, lo que se esconde, y cuánto de lo escondido es urgente.
class FilterResult {
  const FilterResult({required this.shown, required this.hidden, required this.hiddenByUrgency});

  final List<IncidentRow> shown;
  final List<IncidentRow> hidden;
  final Map<String, int> hiddenByUrgency;

  /// «4 ocultos por el filtro (2 son P1)»; nulo si no se esconde nada.
  String? get hiddenSummary {
    if (hidden.isEmpty) return null;
    final n = hidden.length;
    final p1 = hiddenByUrgency['P1'] ?? 0;
    return '$n ${n == 1 ? 'oculto' : 'ocultos'} por el filtro${p1 == 0 ? '' : (p1 == 1 ? ' (1 es P1)' : ' ($p1 son P1)')}';
  }
}

/// Un filtro inmutable: un texto y un conjunto de marcas.
class IncidentFilter {
  const IncidentFilter({this.query = '', this.flags = const {}});

  final String query;
  final Set<FilterFlag> flags;

  bool get isActive => query.trim().isNotEmpty || flags.isNotEmpty;

  IncidentFilter withQuery(String q) => IncidentFilter(query: q, flags: flags);

  IncidentFilter withFlag(FilterFlag f, bool on) => IncidentFilter(query: query, flags: on ? {...flags, f} : ({...flags}..remove(f)));

  IncidentFilter cleared() => const IncidentFilter();

  /// El filtro en una línea, para tenerlo siempre a la vista: «atrapado» · Sin ubicación.
  String describe() => [if (query.trim().isNotEmpty) '«${query.trim()}»', for (final f in FilterFlag.values) if (flags.contains(f)) f.label].join(' · ');

  /// Minúsculas y sin tildes (ni la eñe): «Vía» se encuentra con «via».
  static String _plain(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñ';
    const to = 'aaaaeeeeiiiioooouuuun';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i < 0 ? c : to[i]);
    }
    return b.toString();
  }

  bool matches(IncidentRow r) {
    for (final f in flags) {
      if (!f.matches(r)) return false;
    }
    final terms = _plain(query).split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (terms.isEmpty) return true;
    final haystack = _plain('${headlineOf(r)} ${r.id}');
    return terms.every(haystack.contains);
  }

  FilterResult apply(List<IncidentRow> rows) {
    final shown = <IncidentRow>[], hidden = <IncidentRow>[];
    final byUrgency = {for (final u in kUrgencies) u: 0};
    for (final r in rows) {
      if (matches(r)) {
        shown.add(r);
      } else {
        hidden.add(r);
        byUrgency[r.urgency] = (byUrgency[r.urgency] ?? 0) + 1;
      }
    }
    return FilterResult(shown: shown, hidden: hidden, hiddenByUrgency: byUrgency);
  }
}
