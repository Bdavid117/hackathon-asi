import 'dart:convert';

import 'package:sard_agents/sard_agents.dart';
import 'package:sard_protocol/sard_protocol.dart';

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
    this.people = 0,
    this.evidence = const [],
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
    this.source = 'app',
    this.medium,
    this.origin,
    this.registeredBy,
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

  /// Personas afectadas según quien reporta (código de `PeopleBucket`; 0 = no indicado).
  final int people;

  /// Por qué el sistema cree lo que cree: cada señal con su campo estructurado (`flags.atrapado`) o con
  /// la **cita exacta** del texto del reporte. Reglas y modelo; las citas del modelo sólo entran si son
  /// subcadena del texto vigente. Orden canónico y sin repetidos.
  final List<Map<String, String>> evidence;

  String get peopleLabel => PeopleBucket.fromCode(people).label;
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

  /// De dónde viene: `app` o `radio` (informe de segunda mano que registró un despachador). Sólo en los de
  /// despachador hay medio, origen y quién lo registró.
  final String source;
  final String? medium;
  final String? origin;
  final String? registeredBy;

  Map<String, Object?> toJson() => {
    'reportKey': reportKey,
    'urgency': urgency.name.toUpperCase(),
    'rev': rev,
    'flags': flags,
    'lat': lat,
    'lon': lon,
    'text': text,
    'people': people,
    'peopleLabel': peopleLabel,
    'evidence': evidence,
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
    'source': source,
    'medium': medium,
    'origin': origin,
    'registeredBy': registeredBy,
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
        m.text,
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
        people: m.people,
        evidence: _evidenceJson(t.evidence),
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
        source: m.sourceClass,
        medium: m.medium,
        origin: m.origin,
        registeredBy: m.registeredBy,
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

/// Señales en orden canónico (para que dos nodos produzcan listas idénticas).
const List<String> kSignalCodeOrder = [
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
TriageResult _effective(TriageResult rules, List<Event> model, String? text) {
  if (model.isEmpty) return rules;
  var urgency = rules.urgency;
  final modelUrgencies = <Urgency>{};
  final signals = {...rules.signals};
  final uncertainty = {...rules.uncertainty};
  var modelAsksReview = false;
  var interpreted = false;
  final evidence = [...rules.evidence];
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
    // Una cita del modelo sólo vale si es subcadena EXACTA del texto vigente: nunca se muestra una inventada.
    for (final ev in (e.body['evidence'] as List? ?? const [])) {
      if (ev is! Map) continue;
      final code = ev['code'], quote = ev['quote'];
      if (code is! String || quote is! String || quote.isEmpty || text == null || !text.contains(quote)) continue;
      if (!kSignalCodeOrder.contains(code)) continue;
      evidence.add(Signal(code, quote: quote));
    }
  }
  if (interpreted) {
    uncertainty.remove('texto_no_interpretado');
    uncertainty.remove('sin_detalle');
  }
  if (modelUrgencies.length > 1 || modelUrgencies.any((u) => u != rules.urgency)) uncertainty.add('juicios_discrepantes');
  return TriageResult(
    urgency: urgency,
    signals: [for (final c in kSignalCodeOrder) if (signals.contains(c)) c],
    mode: 'rules+llm',
    evidence: evidence,
    confidence: rules.confidence,
    uncertainty: uncertainty.toList()..sort(),
    escalateToHuman: modelAsksReview || (rules.escalateToHuman && !interpreted),
  );
}

/// La evidencia en JSON, sin repetidos y en orden canónico (código, campo, cita): dos nodos con los
/// mismos datos producen la misma lista.
List<Map<String, String>> _evidenceJson(List<Signal> evidence) {
  final seen = <String>{};
  final rows = <(int, String, String, Map<String, String>)>[];
  for (final e in evidence) {
    final row = {'code': e.code, if (e.field != null) 'field': e.field!, if (e.quote != null) 'quote': e.quote!};
    if (!seen.add(jsonEncode(row))) continue;
    final order = kSignalCodeOrder.indexOf(e.code);
    rows.add((order < 0 ? kSignalCodeOrder.length : order, e.field ?? '', e.quote ?? '', row));
  }
  rows.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    if (c != 0) return c;
    final f = a.$2.compareTo(b.$2);
    return f != 0 ? f : a.$3.compareTo(b.$3);
  });
  return [for (final r in rows) r.$4];
}
