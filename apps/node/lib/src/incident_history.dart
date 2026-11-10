import 'approvals.dart';
import 'event_log.dart';

/// La HISTORIA de un incidente: qué hizo cada agente y quién decidió qué, sólo en el DETALLE (nunca en la cola, la lista ni el
/// resumen: así la huella de las proyecciones no puede cambiar por esto).
///
/// Qué lleva y qué no:
///  · Un paso RESPALDADO por un evento (recepción, normalización, triaje, vínculo auditado, decisión, declaración de una unidad
///    propuesta) trae su nodo de origen y su hora (la parte física del `hlc`).
///  · Lo que se CALCULA al leer (el agrupamiento, las contradicciones, la recomendación) sale rotulado como derivado y SIN hora:
///    no hay un evento al que atribuirle una.
///  · Los agentes 4 (comunicación, en el teléfono) y 5 (resiliencia, estado de los nodos) no dejan eventos por incidente: no se les
///    inventa fila.
///  · La aprobación sólo guarda el identificador de la versión de la recomendación: se dice quién, cuándo, en qué estado y qué
///    decisión sustituyó, no QUÉ se aprobó.
///  · Nunca lleva el texto de un reporte.

/// Un paso de la traza de agentes.
class HistoryStep {
  const HistoryStep({required this.agent, required this.kind, required this.summary, this.nodeId, this.atMs, this.derived = false, this.eventIds = const []});

  /// «1 · Recepción», «2 · Triaje», «3 · Correlación», «6 · Coordinación» o «Persona».
  final String agent;

  /// `recibido`, `normalizado`, `triaje`, `vinculo`, `decision`, `recurso`, `agrupamiento`, `contradicciones` o `recomendacion`.
  final String kind;
  final String summary;

  /// El nodo que escribió el evento (no el que sirve el detalle). `null` en un paso derivado.
  final String? nodeId;

  /// Milisegundos de la hora del evento. `null` en un paso derivado.
  final int? atMs;
  final bool derived;
  final List<String> eventIds;

  Map<String, Object?> toJson() => {'agent': agent, 'kind': kind, 'summary': summary, 'nodeId': nodeId, 'atMs': atMs, 'derived': derived, 'eventIds': eventIds};
}

/// Una decisión humana, para la línea de tiempo de la auditoría.
class AuditEntry {
  const AuditEntry({required this.eventId, required this.who, required this.decision, required this.atMs, required this.status, this.supersedes = const [], this.note});

  final String eventId;
  final String who;

  /// `granted` o `denied`.
  final String decision;
  final int atMs;

  /// `vigente`, `caduca` (vio otra versión de la recomendación) o `sustituida` (otra decisión la nombró).
  final String status;
  final List<String> supersedes;
  final String? note;

  Map<String, Object?> toJson() => {'eventId': eventId, 'who': who, 'decision': decision, 'atMs': atMs, 'status': status, 'supersedes': supersedes, 'note': note};
}

class IncidentHistory {
  const IncidentHistory({required this.steps, required this.stepsTotal, required this.audit, required this.auditTotal});

  final List<HistoryStep> steps;

  /// Cuántos pasos hay en total (los mostrados son los MÁS RECIENTES si no caben).
  final int stepsTotal;
  final List<AuditEntry> audit;
  final int auditTotal;

  Map<String, Object?> toJson() => {
    'steps': [for (final s in steps) s.toJson()],
    'stepsTotal': stepsTotal,
    'audit': [for (final a in audit) a.toJson()],
    'auditTotal': auditTotal,
  };
}

const int kMaxAuditEntries = 50;
const String _a1 = '1 · Recepción', _a2 = '2 · Triaje', _a3 = '3 · Correlación', _a6 = '6 · Coordinación', _human = 'Persona';
const List<String> _agentOrder = [_a1, _a2, _a3, _a6, _human];
const Set<String> _memberTypes = {'report.received', 'report.normalized', 'triage.assessed', 'incident.linked'};

int _ms(Event e) => int.tryParse(e.hlc.split('-').first) ?? 0;

/// Arma la historia del incidente descrito por [detail] (el detalle ya calculado) con los eventos que lo respaldan.
///
/// Función pura: no depende del orden de entrada. [memberEvents] son los eventos de los reportes del incidente; [approvalEvents]
/// todas las decisiones (se filtran con la misma regla que `deriveApproval`); [resourceEvents] las declaraciones de unidades (sólo
/// entran las de unidades que la recomendación propone). Con más de [maxSteps] pasos se conservan los más recientes.
IncidentHistory buildIncidentHistory({
  required Map<String, Object?> detail,
  required List<Event> memberEvents,
  required List<Event> approvalEvents,
  required List<Event> resourceEvents,
  int maxSteps = 60,
}) {
  final incidentId = detail['id'] as String? ?? '';
  final memberKeys = {for (final m in (detail['members'] as List? ?? const [])) if (m is String) m};
  final rec = detail['recommendation'] is Map ? (detail['recommendation']! as Map).cast<String, Object?>() : const <String, Object?>{};
  final recId = rec['id'] as String?;
  final proposed = {for (final r in (rec['resourceIds'] as List? ?? const [])) if (r is String) r};

  final timed = <HistoryStep>[];
  for (final e in memberEvents) {
    final key = e.reportKey;
    if (key == null || !memberKeys.contains(key) || !_memberTypes.contains(e.type)) continue;
    final base = (agent: '', kind: '', summary: '');
    var step = switch (e.type) {
      'report.received' => (agent: _a1, kind: 'recibido', summary: 'Reporte $key · revisión ${e.rev ?? 0} · canal ${e.body['channel'] is String ? e.body['channel'] : 'app'}'),
      'report.normalized' => (agent: _a1, kind: 'normalizado', summary: _normalizedSummary(e)),
      'triage.assessed' => (agent: _a2, kind: 'triaje', summary: _triageSummary(e)),
      'incident.linked' => (agent: _a3, kind: 'vinculo', summary: 'Vínculos auditados: ${e.body['links'] is List ? (e.body['links']! as List).length : 0}'),
      _ => base,
    };
    timed.add(HistoryStep(agent: step.agent, kind: step.kind, summary: step.summary, nodeId: e.origin, atMs: _ms(e), eventIds: [e.id]));
  }

  // Auditoría: la misma regla de pertenencia y de estado que deriveApproval (no se duplica la regla).
  final decisions = readApprovals(approvalEvents);
  final state = deriveApproval(incidentId: incidentId, memberKeys: memberKeys, currentRecommendationId: recId, approvals: decisions);
  final byId = {for (final e in approvalEvents) e.id: e};
  final staleIds = {for (final d in state.stale) d.eventId};
  final currentIds = {for (final d in state.current) d.eventId};
  final audit = <AuditEntry>[];
  for (final d in decisions) {
    if (!(d.incidentId == incidentId || d.members.any(memberKeys.contains))) continue;
    final status = staleIds.contains(d.eventId) ? 'caduca' : (currentIds.contains(d.eventId) ? 'vigente' : 'sustituida');
    audit.add(AuditEntry(eventId: d.eventId, who: d.who, decision: d.granted ? 'granted' : 'denied', atMs: d.atMs, status: status, supersedes: d.supersedes, note: d.note.isEmpty ? null : d.note));
    final origin = byId[d.eventId]?.origin;
    timed.add(HistoryStep(
      agent: _human,
      kind: 'decision',
      summary: '${d.who} ${d.granted ? 'aprobó' : 'rechazó'} la versión ${d.recommendationId} ($status)',
      nodeId: origin,
      atMs: d.atMs,
      eventIds: [d.eventId],
    ));
  }
  audit.sort((a, b) => a.atMs != b.atMs ? a.atMs.compareTo(b.atMs) : a.eventId.compareTo(b.eventId));

  for (final e in resourceEvents) {
    if (e.type != 'resource.declared') continue;
    final r = e.body['resource'];
    final id = r is Map ? r['id'] : null;
    if (id is! String || !proposed.contains(id)) continue;
    final available = r is Map && r['available'] == true;
    final who = e.body['declared_by'] is String ? e.body['declared_by']! as String : 'alguien';
    timed.add(HistoryStep(agent: _human, kind: 'recurso', summary: '$who declaró $id ${available ? 'disponible' : 'no disponible'}', nodeId: e.origin, atMs: _ms(e), eventIds: [e.id]));
  }

  timed.sort((a, b) {
    final c = (a.atMs ?? 0).compareTo(b.atMs ?? 0);
    if (c != 0) return c;
    final r = _agentOrder.indexOf(a.agent).compareTo(_agentOrder.indexOf(b.agent));
    return r != 0 ? r : a.eventIds.first.compareTo(b.eventIds.first);
  });

  final derived = <HistoryStep>[
    HistoryStep(agent: _a3, kind: 'agrupamiento', summary: 'Grupo de ${memberKeys.length} ${memberKeys.length == 1 ? 'reporte' : 'reportes'} · ${detail['sources'] ?? 1} ${(detail['sources'] ?? 1) == 1 ? 'fuente' : 'fuentes'}', derived: true),
    if (_count(detail['contradictions']) > 0)
      HistoryStep(agent: _a3, kind: 'contradicciones', summary: '${_count(detail['contradictions'])} ${_count(detail['contradictions']) == 1 ? 'contradicción' : 'contradicciones'} entre reportes', derived: true),
    if (rec.isNotEmpty)
      HistoryStep(
        agent: _a6,
        kind: 'recomendacion',
        summary: 'Recomendación (${rec['state'] ?? 'sin estado'}): ${(rec['actions'] as List? ?? const []).length} acciones, ${(rec['pending'] as List? ?? const []).length} requisitos pendientes',
        derived: true,
      ),
  ];

  final room = maxSteps - derived.length < 0 ? 0 : maxSteps - derived.length;
  final shown = timed.length <= room ? timed : timed.sublist(timed.length - room);
  final auditShown = audit.length <= kMaxAuditEntries ? audit : audit.sublist(audit.length - kMaxAuditEntries);
  return IncidentHistory(steps: [...shown, ...derived], stepsTotal: timed.length + derived.length, audit: auditShown, auditTotal: audit.length);
}

int _count(Object? v) => v is int ? v : (v is List ? v.length : 0);

String _normalizedSummary(Event e) {
  final missing = e.body['missing'];
  if (missing is! List || missing.isEmpty) return 'Normalizado · sin campos faltantes';
  return 'Normalizado · faltan: ${missing.join(', ')}';
}

String _triageSummary(Event e) {
  final llm = e.body['mode'] == 'rules+llm';
  final urgency = e.body['urgency'] is String ? e.body['urgency']! as String : '?';
  final version = e.body['agent_version'] is String ? e.body['agent_version']! as String : 'sin versión';
  return 'Urgencia $urgency · ${llm ? 'reglas + modelo' : 'por reglas'} (agente $version)';
}
