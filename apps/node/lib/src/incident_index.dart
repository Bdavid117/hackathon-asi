import 'dart:convert';

import 'incidents.dart';

/// Cuántos incidentes P3/P4 **con información** (los más recientes) entran en la vista corta.
const int kShortViewLowUrgency = 20;

/// Tope de filas por página en la vista completa.
const int kMaxIncidentPage = 1000;

class _Row {
  const _Row(this.id, this.u, this.bare, this.firstAt, this.lastAt, this.json, {this.pending = false});
  final String id;
  final int u;
  final bool bare;

  /// Una propuesta que todavía espera a una persona (ver [IncidentIndex.isPending]).
  final bool pending;
  final int firstAt;
  final int lastAt;
  final String json;
}

/// Las filas resumen de todos los incidentes, ya codificadas, con los **contadores** y la **vista corta**.
///
/// Un tablero que sondea cada pocos segundos no puede recibir 10 000 incidentes (≈ 8 MB) en cada
/// lectura: la vista corta es lo que se pide por omisión y es la que reparte la atención. Reglas
/// (decisión 11):
///  · **todos** los P1 y P2 (ninguno queda fuera, haya los que haya);
///  · más los [kShortViewLowUrgency] P3/P4 **con información** más recientes;
///  · los **SOS sin detalle** (lo que más emitirá la app real) no se listan uno a uno: van en **una fila
///    agregada** con su cuenta, y se ven aparte con `bare=true`;
///  · los **contadores** son sobre el total real, para no esconder lo que la vista corta no muestra.
///
/// El orden es siempre el mismo: más grave primero, luego el más antiguo (la antigüedad se atiende),
/// luego por identificador.
class IncidentIndex {
  IncidentIndex._(this._rows, this._shortBody, this._counters);

  /// Un índice sin incidentes.
  static final IncidentIndex empty = IncidentIndex.build(const []);

  final List<_Row> _rows;
  final String _shortBody;
  final Map<String, Object?> _counters;

  factory IncidentIndex.build(List<IncidentData> incidents) {
    final rows = <_Row>[
      for (final i in incidents)
        _Row(
          i.id,
          i.urgency.index,
          i.summary['bareSos'] == true,
          (i.summary['firstAt'] as num?)?.toInt() ?? 0,
          (i.summary['lastAt'] as num?)?.toInt() ?? 0,
          jsonEncode(i.summary),
          pending: isPending(i.summary),
        ),
    ];
    // Se vuelve a ordenar aquí: quien llama puede no haberlo hecho, y el orden es parte del contrato.
    rows.sort((a, b) {
      final u = a.u.compareTo(b.u);
      if (u != 0) return u;
      final f = a.firstAt.compareTo(b.firstAt);
      return f != 0 ? f : a.id.compareTo(b.id);
    });

    final informativeLow = [for (final r in rows) if (r.u >= 2 && !r.bare) r]
      ..sort((a, b) {
        final t = b.lastAt.compareTo(a.lastAt);
        return t != 0 ? t : a.id.compareTo(b.id);
      });
    final shownLow = {for (final r in informativeLow.take(kShortViewLowUrgency)) r.id};
    final shortRows = [
      for (final r in rows)
        if (!r.bare && (r.u <= 1 || shownLow.contains(r.id))) r,
    ];
    final bares = [for (final r in rows) if (r.bare) r];

    var reports = 0, high = 0, review = 0, discrepancies = 0;
    final byUrgency = [0, 0, 0, 0];
    for (final r in rows) {
      byUrgency[r.u]++;
    }
    for (final i in incidents) {
      reports += (i.summary['size'] as num?)?.toInt() ?? 1;
      if (i.summary['highUncertainty'] == true) high++;
      if (i.summary['needsReview'] == true) review++;
      if ((i.summary['approval'] as Map?)?['discrepancy'] == true) discrepancies++;
    }
    final pendingRows = [for (final r in rows) if (r.pending) r];
    final counters = <String, Object?>{
      'incidents': rows.length,
      'reports': reports,
      'byUrgency': {'P1': byUrgency[0], 'P2': byUrgency[1], 'P3': byUrgency[2], 'P4': byUrgency[3]},
      'bareSos': bares.length,
      'highUncertainty': high,
      'needsReview': review,
      'inShortView': shortRows.length,
      // Propuestas que esperan a una persona (sobre el TOTAL, no sobre la vista corta) y desde cuándo espera la más antigua:
      // la HORA, no la edad (la edad la calcula quien lee, con su reloj). Las decisiones contradictorias van aparte.
      'pendingDecision': pendingRows.length,
      'pendingOldestAt': pendingRows.isEmpty ? null : pendingRows.map((r) => r.firstAt).reduce((a, b) => a < b ? a : b),
      'discrepancies': discrepancies,
      'followUp': informativeLow.length > kShortViewLowUrgency ? informativeLow.length - kShortViewLowUrgency : 0,
    };

    String? aggregate;
    if (bares.isNotEmpty) {
      aggregate = jsonEncode({
        'count': bares.length,
        'oldestAt': bares.map((r) => r.firstAt).reduce((a, b) => a < b ? a : b),
        'newestAt': bares.map((r) => r.lastAt).reduce((a, b) => a > b ? a : b),
        'sampleIds': [for (final r in bares.take(5)) r.id],
      });
    }

    final shortBody = _envelope(view: 'short', counters: counters, items: shortRows, total: shortRows.length, offset: 0, limit: shortRows.length, bareAggregate: aggregate);
    return IncidentIndex._(rows, shortBody, counters);
  }

  /// Una **propuesta** de recomendación cuya decisión está pendiente o caducada. No cuentan las ya aprobadas o rechazadas,
  /// lo que no es una propuesta (falta información, descartada) ni las decisiones contradictorias (van en `discrepancies`).
  static bool isPending(Map<String, Object?> summary) {
    final recommendation = summary['recommendation'];
    final approval = summary['approval'];
    if (recommendation is! Map || approval is! Map || recommendation['state'] != 'propuesta' || approval['discrepancy'] == true) return false;
    return approval['status'] == 'pendiente' || approval['status'] == 'caduca';
  }

  static String _envelope({required String view, required Map<String, Object?> counters, required List<_Row> items, required int total, required int offset, required int limit, required String? bareAggregate}) =>
      '{"view":"$view","counters":${jsonEncode(counters)},"total":$total,"offset":$offset,"limit":$limit,'
      '"bareSos":${bareAggregate ?? 'null'},"items":[${items.map((r) => r.json).join(',')}]}';

  /// Cuántos incidentes hay en total.
  int get length => _rows.length;

  /// El JSON de una página.
  ///
  ///  · `view: 'short'` (por omisión): la vista corta; **ignora** offset y limit (si no, un P1 podría
  ///    quedar fuera) y no admite filtros.
  ///  · `view: 'all'`: todos los incidentes, paginados por [offset] y [limit] (máx. [kMaxIncidentPage]),
  ///    con filtros opcionales por [urgency] (`P1`…`P4`), por [bare] (sólo / sin los SOS sin detalle) y por [pending]
  ///    (sólo / sin las propuestas que esperan una decisión).
  ///
  /// Lanza [ArgumentError] ante parámetros inválidos.
  String page({String view = 'short', String? urgency, bool? bare, bool? pending, int offset = 0, int limit = 200}) {
    if (view != 'short' && view != 'all') throw ArgumentError.value(view, 'view', 'debe ser «short» o «all»');
    final u = urgency == null ? null : const {'P1': 0, 'P2': 1, 'P3': 2, 'P4': 3}[urgency];
    if (urgency != null && u == null) throw ArgumentError.value(urgency, 'urgency', 'debe ser P1, P2, P3 o P4');
    if (view == 'short') {
      if (urgency != null || bare != null || pending != null) throw ArgumentError('los filtros sólo valen con view=all');
      return _shortBody;
    }
    if (offset < 0) throw ArgumentError.value(offset, 'offset', 'no puede ser negativo');
    if (limit < 1) throw ArgumentError.value(limit, 'limit', 'debe ser positivo');
    final cap = limit > kMaxIncidentPage ? kMaxIncidentPage : limit;
    final filtered = [
      for (final r in _rows)
        if ((u == null || r.u == u) && (bare == null || r.bare == bare) && (pending == null || r.pending == pending)) r,
    ];
    final slice = filtered.skip(offset).take(cap).toList();
    return _envelope(view: 'all', counters: _counters, items: slice, total: filtered.length, offset: offset, limit: cap, bareAggregate: null);
  }
}
