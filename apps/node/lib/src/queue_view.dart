import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';
import 'merged_reports.dart';

/// Un reporte (con todas sus revisiones fundidas) tal como lo ve el coordinador.
class QueueItem {
  const QueueItem({
    required this.reportKey,
    required this.urgency,
    required this.rev,
    required this.flags,
    this.lat,
    this.lon,
    this.text,
    required this.capturedAt,
    required this.receivedAtMs,
    required this.signals,
    this.group = '',
    this.groupSize = 1,
    this.groupUrgency = Urgency.p4,
    this.sources = 1,
    this.confidence = 0,
    this.uncertainty = const [],
    this.escalate = false,
    this.similar = const [],
  });

  final String reportKey;

  /// Urgencia de ESTE reporte según el triaje por reglas.
  final Urgency urgency;

  /// Revisión más alta conocida.
  final int rev;
  final int flags;
  final double? lat;
  final double? lon;
  final String? text;
  final int capturedAt;

  /// Cuándo recibió este nodo la primera trama del reporte.
  final int receivedAtMs;
  final List<String> signals;

  /// Identificador del grupo (la clave más pequeña de sus miembros) y cuántos reportes tiene.
  final String group;
  final int groupSize;

  /// La más grave de las urgencias de los miembros del grupo: lo que se muestra como urgencia
  /// del suceso.
  final Urgency groupUrgency;

  /// Fuentes independientes detrás del grupo y confianza (noisy-OR) de que el suceso sea real.
  final int sources;
  final double confidence;

  /// Incertidumbre del reporte (triaje) y del grupo (fuentes).
  final List<String> uncertainty;

  /// «Ante la duda sube a revisión»: el triaje pide ojos humanos.
  final bool escalate;

  /// Reportes que *podrían* ser el mismo suceso (vínculos `possible`): sólo se sugieren.
  final List<String> similar;

  Map<String, Object?> toJson() => {
    'reportKey': reportKey,
    'urgency': urgency.name.toUpperCase(),
    'rev': rev,
    'flags': flags,
    'lat': lat,
    'lon': lon,
    'text': text,
    'capturedAt': capturedAt,
    'receivedAt': receivedAtMs,
    'signals': signals,
    'group': group,
    'groupSize': groupSize,
    'groupUrgency': groupUrgency.name.toUpperCase(),
    'sources': sources,
    'confidence': confidence,
    'uncertainty': uncertainty,
    'escalate': escalate,
    'similar': similar,
  };
}

/// Cola priorizada derivada del log. **No descarta ningún reporte.**
///
/// Las revisiones de un mismo reporte se funden por campo (ver [mergeReports]). El **grupo** se
/// calcula aquí, al leer, como función pura de los reportes fusionados: no depende del orden de
/// llegada ni de qué nodo vio qué, así que dos nodos que trabajaron aislados y luego replicaron
/// muestran los mismos grupos. Los eventos `incident.linked` del log son auditoría y no cuentan.
List<QueueItem> buildQueue(EventLog log) =>
    buildQueueFromEvents(log.allOfType('report.received'), log.allOfType('triage.assessed'));

/// La cola a partir de listas de eventos (lo único que puede viajar a otro isolate). [triage] son los
/// `triage.assessed` del log; sólo cuentan los del modelo (`mode: rules+llm`).
List<QueueItem> buildQueueFromEvents(List<Event> received, List<Event> triageEvents) {
  final merged = mergeReports(received);
  final obs = {for (final m in merged) m.reportKey: m.toObservation()};
  final ordered = obs.values.toList();
  // Una sola pasada: los grupos y las sugerencias salen de los mismos vínculos puntuados.
  final grouping = analyzeGrouping(ordered);
  final groups = grouping.groups;
  final ids = groupIds(groups);

  // Juicios del modelo de lenguaje (si los hubo), por reporte. Sólo valen para el texto que analizaron.
  final modelEvents = <String, List<Event>>{};
  for (final e in triageEvents) {
    if (e.body['mode'] != 'rules+llm' || e.reportKey == null) continue;
    (modelEvents[e.reportKey!] ??= []).add(e);
  }
  final triaged = {
    for (final m in merged)
      m.reportKey: _effective(
        triage(m.flags, text: m.text, hasLocation: m.hasLocation && m.locQuality.hasCoordinates),
        [for (final e in modelEvents[m.reportKey] ?? const <Event>[]) if (m.text != null && e.body['analyzed_text'] == m.text) e],
      ),
  };
  final assessments = <String, GroupAssessment>{};
  final groupUrgency = <String, Urgency>{};
  for (final g in groups) {
    final id = ids[g.first]!;
    assessments[id] = assessGroup([for (final k in g) obs[k]!]);
    groupUrgency[id] = g.map((k) => triaged[k]!.urgency).reduce((a, b) => a.index <= b.index ? a : b);
  }
  final groupSize = {for (final g in groups) ids[g.first]!: g.length};

  // Sugerencias: vínculos `possible` —y los `same` que la regla anti-puente frenó— entre reportes que
  // NO quedaron en el mismo grupo.
  final similar = <String, List<(double, String)>>{};
  for (final l in grouping.links) {
    if (ids[l.a] == ids[l.b]) continue;
    (similar[l.a] ??= []).add((l.pair.score, l.b));
    (similar[l.b] ??= []).add((l.pair.score, l.a));
  }

  final items = <QueueItem>[];
  for (final m in merged) {
    final t = triaged[m.reportKey]!;
    final id = ids[m.reportKey]!;
    final a = assessments[id]!;
    final sug = (similar[m.reportKey] ?? [])..sort((x, y) => y.$1 != x.$1 ? y.$1.compareTo(x.$1) : x.$2.compareTo(y.$2));
    items.add(
      QueueItem(
        reportKey: m.reportKey,
        urgency: t.urgency,
        rev: m.rev,
        flags: m.flags,
        lat: m.lat,
        lon: m.lon,
        text: m.text,
        capturedAt: m.capturedAt,
        receivedAtMs: m.receivedAtMs,
        signals: t.signals,
        group: id,
        groupSize: groupSize[id]!,
        groupUrgency: groupUrgency[id]!,
        sources: a.independentSources,
        confidence: a.confidence,
        uncertainty: ({...t.uncertainty, ...a.uncertainty}.toList()..sort()),
        escalate: t.escalateToHuman,
        similar: [for (final s in sug.take(5)) s.$2],
      ),
    );
  }
  items.sort((a, b) {
    final u = a.urgency.index.compareTo(b.urgency.index);
    if (u != 0) return u;
    final c = a.capturedAt.compareTo(b.capturedAt);
    return c != 0 ? c : a.reportKey.compareTo(b.reportKey);
  });
  return items;
}

const List<String> _codeOrder = [
  'atrapado',
  'herido',
  'incendio',
  'dificultad_respiratoria',
  'via_bloqueada',
  'estructura_inestable',
  'menores_mayores',
  'medicacion',
];

/// Triaje por reglas combinado con los juicios del modelo sobre el texto vigente: manda la urgencia
/// **más grave** (el modelo nunca baja nada), las señales se unen, y si los juicios difieren se
/// marca `juicios_discrepantes`. Listas en orden canónico para que dos nodos produzcan lo mismo.
TriageResult _effective(TriageResult rules, List<Event> model) {
  if (model.isEmpty) return rules;
  var urgency = rules.urgency;
  final modelUrgencies = <Urgency>{};
  final signals = {...rules.signals};
  final uncertainty = {...rules.uncertainty};
  var modelAsksReview = false;
  var interpreted = false;
  for (final e in model) {
    final u = Urgency.values.firstWhere((x) => x.name.toUpperCase() == e.body['urgency'], orElse: () => Urgency.p4);
    modelUrgencies.add(u);
    if (u.index < urgency.index) urgency = u;
    for (final c in (e.body['signals'] as List? ?? const []).cast<String>()) {
      if (!rules.signals.contains(c)) interpreted = true;
      signals.add(c);
    }
    uncertainty.addAll((e.body['uncertainty'] as List? ?? const []).cast<String>());
    if (e.body['escalate_to_human'] == true) modelAsksReview = true;
  }
  if (interpreted) {
    uncertainty.remove('texto_no_interpretado');
    uncertainty.remove('sin_detalle');
  }
  if (modelUrgencies.length > 1 || modelUrgencies.any((u) => u != rules.urgency)) uncertainty.add('juicios_discrepantes');
  return TriageResult(
    urgency: urgency,
    signals: [for (final c in _codeOrder) if (signals.contains(c)) c],
    mode: 'rules+llm',
    evidence: rules.evidence,
    confidence: rules.confidence,
    uncertainty: uncertainty.toList()..sort(),
    escalateToHuman: modelAsksReview || (rules.escalateToHuman && !interpreted),
  );
}

/// La cola ya codificada como JSON, calculada sólo a partir de listas de eventos: es lo que se
/// ejecuta en otro isolate para no bloquear el hilo que atiende los ACK.
String queueJsonFromEvents(List<Event> received, List<Event> triageEvents) =>
    jsonEncode([for (final i in buildQueueFromEvents(received, triageEvents)) i.toJson()]);
