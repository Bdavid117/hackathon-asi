import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'approvals.dart';
import 'coverage.dart';
import 'event_log.dart';
import 'incident_index.dart';
import 'queue_view.dart';

/// Un incidente listo para servir: la fila **resumen** (compacta, para el tablero) y el **detalle**
/// (observaciones originales, recomendación completa, decisiones) que se pide al abrirlo.
class IncidentData {
  const IncidentData({required this.id, required this.urgency, required this.firstAt, required this.summary, required this.detail});

  final String id;
  final Urgency urgency;

  /// Segundos de la observación más antigua (para ordenar: la antigüedad se atiende).
  final int firstAt;
  final Map<String, Object?> summary;
  final Map<String, Object?> detail;
}

const Set<String> _reviewCodes = {'texto_no_interpretado', 'juicios_discrepantes', 'baja_confianza_modelo'};
const Set<String> _highUncertaintyCodes = {'ubicacion_ausente', 'ubicacion_imprecisa', 'texto_no_interpretado', 'baja_confianza_modelo', 'juicios_discrepantes'};

/// Cuántas entradas de evidencia y cuántos miembros lleva la fila resumen (el detalle lleva todo).
const int kSummaryEvidence = 4;
const int kSummaryMembers = 20;

/// Los incidentes como **proyección de lectura**: una función pura de la cola ya agrupada, las
/// decisiones registradas y los recursos declarados. No guarda nada; dos nodos con los mismos eventos
/// producen los mismos incidentes.
///
/// La recomendación de cada incidente se calcula **por separado** (el identificador no depende de los
/// demás) y después se marcan los recursos que dos incidentes proponen a la vez. Toda propuesta pasa
/// por el validador antes de mostrarse.
List<IncidentData> buildIncidents(List<QueueItem> items, {required List<ApprovalDecision> approvals, required List<Resource> resources}) {
  final byGroup = <String, List<QueueItem>>{};
  for (final i in items) {
    (byGroup[i.group] ??= []).add(i);
  }

  // Decisiones indexadas por incidente y por cada miembro, para no recorrerlas todas por incidente.
  final approvalsByKey = <String, Set<ApprovalDecision>>{};
  for (final a in approvals) {
    (approvalsByKey[a.incidentId] ??= {}).add(a);
    for (final m in a.members) {
      (approvalsByKey[m] ??= {}).add(a);
    }
  }

  final resourceById = {for (final r in resources) r.id: r};
  // Restricciones operativas conocidas: las vías bloqueadas que reportan los incidentes (con ubicación). Cada incidente las ve
  // todas MENOS las suyas (el agente 6 descarta las del mismo incidente). Sólo se avisa («confirmar ruta»); nada se recalcula.
  final roadBlocks = [
    for (final i in items)
      if (i.signals.contains('via_bloqueada') && i.lat != null && i.lon != null) RoadBlock(lat: i.lat!, lon: i.lon!, source: i.group),
  ];
  final built = <_Built>[];
  for (final entry in byGroup.entries) {
    final members = [...entry.value]..sort((a, b) => a.reportKey.compareTo(b.reportKey));
    final id = entry.key;
    final view = IncidentView(
      id: id,
      urgency: members.first.groupUrgency,
      members: [
        for (final m in members)
          IncidentMember(
            reportKey: m.reportKey,
            rev: m.rev,
            urgency: m.urgency,
            signals: m.signals,
            evidence: m.evidence,
            text: m.text,
            lat: m.lat,
            lon: m.lon,
            people: m.people,
          ),
      ],
      sources: members.first.sources,
      uncertainty: ({for (final m in members) ...m.uncertainty}.toList()..sort()),
    );
    var outcome = recommend(view, resources, blockedRoads: roadBlocks);
    if (outcome is Recommendation) {
      final bad = validateRecommendation(outcome, view, resources);
      if (bad != null) outcome = bad; // defensa en profundidad: nunca se muestra algo que no pase la puerta
    }
    built.add(_Built(id, members, view, outcome));
  }

  // Recursos propuestos por más de un incidente.
  final proposedBy = <String, List<String>>{};
  for (final b in built) {
    final o = b.outcome;
    if (o is Recommendation) {
      for (final r in o.resourceIds) {
        (proposedBy[r] ??= []).add(b.id);
      }
    }
  }

  final states = <String, ApprovalState>{};
  for (final b in built) {
    final candidates = <ApprovalDecision>{...?approvalsByKey[b.id], for (final m in b.members) ...?approvalsByKey[m.reportKey]}.toList();
    states[b.id] = deriveApproval(
      incidentId: b.id,
      memberKeys: {for (final m in b.members) m.reportKey},
      currentRecommendationId: b.outcome is Recommendation ? (b.outcome as Recommendation).id : null,
      approvals: candidates,
    );
  }

  final out = <IncidentData>[];
  for (final b in built) {
    final shared = <Map<String, Object?>>[];
    final o = b.outcome;
    if (o is Recommendation) {
      for (final r in o.resourceIds) {
        final others = [for (final x in proposedBy[r]!) if (x != b.id) x]..sort();
        if (others.isNotEmpty) {
          shared.add({'resourceId': r, 'otherIncidents': others, 'approvedElsewhere': others.any((x) => states[x]!.status == ApprovalStatus.aprobada)});
        }
      }
      shared.sort((a, c) => (a['resourceId']! as String).compareTo(c['resourceId']! as String));
    }
    out.add(_assemble(b, states[b.id]!, shared, resourceById));
  }
  out.sort((a, b) {
    final u = a.urgency.index.compareTo(b.urgency.index);
    if (u != 0) return u;
    final f = a.firstAt.compareTo(b.firstAt);
    return f != 0 ? f : a.id.compareTo(b.id);
  });
  return out;
}

class _Built {
  _Built(this.id, this.members, this.view, this.outcome);
  final String id;
  final List<QueueItem> members;
  final IncidentView view;
  final RecommendationOutcome outcome;
}

Map<String, Object?> _briefRecommendation(RecommendationOutcome o) => switch (o) {
  Recommendation r => {'state': 'propuesta', 'id': r.id, 'actions': r.actions, 'resourceIds': r.resourceIds, 'pending': r.pending},
  InfoRequired i => {'state': 'informacion_requerida', 'missing': i.missing},
  Rejected r => {'state': 'rechazada', 'reason': r.reason},
};

IncidentData _assemble(_Built b, ApprovalState approval, List<Map<String, Object?>> shared, Map<String, Resource> resourceById) {
  final members = b.members;
  final signals = {for (final m in members) ...m.signals};
  final uncertainty = b.view.uncertainty;
  final located = [for (final m in members) if (m.lat != null && m.lon != null) m];
  double? lat, lon;
  if (located.isNotEmpty) {
    lat = located.fold<double>(0, (s, m) => s + m.lat!) / located.length;
    lon = located.fold<double>(0, (s, m) => s + m.lon!) / located.length;
  }
  // Contradicciones entre los reportes del incidente (negación explícita y personas incompatibles): sólo se SEÑALAN;
  // no cambian la urgencia, «a revisar» ni la incertidumbre, y no fusionan ni separan nada. Un solo reporte no tiene con quién.
  final contradictions = members.length < 2 ? const <Contradiction>[] : detectContradictions([for (final m in members) ReportFacts(reportKey: m.reportKey, flags: m.flags, people: m.people, text: m.text)]);
  // La PEOR precisión entre los reportes localizados: mostrar la mejor sugeriría una exactitud que el incidente no tiene.
  final qualities = [for (final m in located) if (m.locQuality != LocQuality.none) m.locQuality];
  final locQuality = qualities.isEmpty ? null : qualities.reduce((a, b) => a.index >= b.index ? a : b).name;
  final people = members.fold<int>(0, (m, i) => i.people > m ? i.people : m);
  final urgency = b.view.urgency;
  final captured = [for (final m in members) m.capturedAt]..sort();
  final received = members.fold<int>(0, (m, i) => i.receivedAtMs > m ? i.receivedAtMs : m);

  final evidence = <Map<String, Object?>>[
    for (final m in members)
      for (final e in m.evidence) {'reportKey': m.reportKey, ...e},
  ];
  final inGroup = {for (final m in members) m.reportKey};
  final similar = ({for (final m in members) ...m.similar}.where((k) => !inGroup.contains(k)).toList()..sort()).take(5).toList();

  final bare = members.every((m) => m.flags == 0 && m.text == null && m.people == 0);
  final highUncertainty = (urgency == Urgency.p1 || urgency == Urgency.p2) && uncertainty.any(_highUncertaintyCodes.contains);

  final base = <String, Object?>{
    'id': b.id,
    'urgency': urgency.name.toUpperCase(),
    'size': members.length,
    'members': [for (final m in members.take(kSummaryMembers)) m.reportKey],
    'signals': [for (final c in kSignalCodeOrder) if (signals.contains(c)) c],
    'people': people,
    'peopleLabel': PeopleBucket.fromCode(people).label,
    'sources': b.view.sources,
    // Cuántos de los reportes del grupo son informes de despachador (segunda mano), para que la lista lo diga.
    'fromDispatch': members.where((m) => m.source == 'radio').length,
    'confidence': members.first.confidence,
    'uncertainty': uncertainty,
    'needsReview': uncertainty.any(_reviewCodes.contains),
    'highUncertainty': highUncertainty,
    'bareSos': bare,
    'lat': lat,
    'locQuality': locQuality,
    'contradictions': contradictions.length,
    'lon': lon,
    'firstAt': captured.first,
    'lastAt': captured.last,
    'receivedAt': received,
    'similar': similar,
  };

  final o = b.outcome;
  final summary = {
    ...base,
    'evidence': evidence.take(kSummaryEvidence).toList(),
    'recommendation': _briefRecommendation(o),
    'approval': {'status': approval.status.name, 'discrepancy': approval.discrepancy, 'decisions': approval.current.length},
    'sharedResources': shared,
  };

  final byTime = [...members]..sort((a, c) {
    final t = a.capturedAt.compareTo(c.capturedAt);
    return t != 0 ? t : a.reportKey.compareTo(c.reportKey);
  });
  final recFull = <String, Object?>{
    ..._briefRecommendation(o),
    if (o is Recommendation) ...{
      'justification': [for (final c in o.justification) c.toJson()],
      'uncertainty': o.uncertainty,
      'requires_approval': o.requiresApproval,
    },
    if (o is Recommendation)
      'resources': [
        for (final rid in o.resourceIds)
          if (resourceById[rid] != null)
            {
              ...resourceById[rid]!.toJson(),
              'distanceMeters': lat == null ? null : distanceMeters(lat, lon!, resourceById[rid]!.lat, resourceById[rid]!.lon).round(),
            },
      ],
  };
  final detail = {
    ...summary,
    // todas las claves (el resumen sólo lleva las primeras) y, aparte, las observaciones originales
    'members': [for (final m in members) m.reportKey],
    'observations': [for (final m in byTime) m.toJson()],
    'evidence': evidence,
    'membersTotal': members.length,
    'contradictions': [for (final c in contradictions) c.toJson()],
    'recommendation': recFull,
    'approval': approval.toJson(),
  };
  return IncidentData(id: b.id, urgency: urgency, firstAt: captured.first, summary: summary, detail: detail);
}

/// Todo lo que se sirve de una sola pasada de cálculo: la cola, los incidentes (índice con vista corta,
/// contadores y páginas) y el detalle de cada incidente ya codificado. Se calcula en el mismo isolate
/// que la cola, sobre los mismos grupos, sin volver a agrupar.
class Projection {
  const Projection({required this.queueJson, this.incidents, this.details = const {}, this.coverage = const [], this.unlocatedAtMs = const []});

  final String queueJson;

  /// El índice de incidentes; `null` sólo en cálculos de prueba que no los producen.
  final IncidentIndex? incidents;

  /// Detalle JSON de cada incidente, por identificador.
  final Map<String, String> details;

  /// Los reportes con ubicación utilizable (y su hora de recepción) para la capa de silencio; y la hora de recepción de los que no la tienen.
  final List<CoverageReport> coverage;
  final List<int> unlocatedAtMs;
}

/// La proyección completa a partir de listas de eventos (lo único que puede viajar a otro isolate).
Projection projectionFromEvents(List<Event> received, List<Event> triageEvents, List<Event> approvalEvents, List<Resource> resources) {
  final items = buildQueueFromEvents(received, triageEvents);
  final incidents = buildIncidents(items, approvals: readApprovals(approvalEvents), resources: resources);
  return Projection(
    queueJson: jsonEncode([for (final i in items) i.toJson()]),
    incidents: IncidentIndex.build(incidents),
    details: {for (final i in incidents) i.id: jsonEncode(i.detail)},
    coverage: [
      for (final i in items)
        if (i.lat != null && i.lon != null && hasUsableCoordinates(i.locQuality)) CoverageReport(lat: i.lat!, lon: i.lon!, receivedAtMs: i.receivedAtMs, urgent: i.urgency == Urgency.p1 || i.urgency == Urgency.p2),
    ],
    unlocatedAtMs: [
      for (final i in items)
        if (!(i.lat != null && i.lon != null && hasUsableCoordinates(i.locQuality))) i.receivedAtMs,
    ],
  );
}
