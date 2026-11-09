import 'dart:async';

import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';
import 'merged_reports.dart';

/// Versión de las reglas de los agentes; queda escrita en cada evento que producen.
const String kAgentVersion = 'rules-2';

/// Ejecuta los agentes de reglas sobre un `report.received` y deja su rastro en el log:
/// `report.normalized` (agente 1), `triage.assessed` (agente 2) y, si el reporte tiene candidatos
/// parecidos, `incident.linked` (agente 3), cada uno apuntando a su entrada. Sólo se invoca para
/// tramas recién guardadas en **este** nodo; los eventos derivados llegan a los demás por
/// replicación.
///
/// `incident.linked` es **auditoría**: dice qué pares puntuó el agente al ingerir el reporte. La
/// cola NO lo usa para agrupar (el grupo se calcula al leer sobre los reportes fusionados), de
/// modo que un vínculo que este nodo no pudo ver —porque el otro reporte llegó a otro nodo— no se
/// pierde ni deja un grupo viejo.
class PipelineRunner {
  PipelineRunner(this._log, {LlmPort? llm}) : _llm = llm;

  final EventLog _log;
  final LlmPort? _llm;
  final Set<Future<void>> _jobs = {};

  /// Espera a que terminen las consultas al modelo que estén en curso (para pruebas y apagado).
  Future<void> get idle async {
    while (_jobs.isNotEmpty) {
      await Future.wait(_jobs.toList());
    }
  }

  List<Event> run(Event received) {
    final normalized = _log.append(
      'report.normalized',
      normalize(received.body),
      reportKey: received.reportKey,
      rev: received.rev,
      inputs: [received.id],
    );
    final hasLocation = received.body['lat'] != null && received.body['lon'] != null;
    final t = triage(
      (received.body['flags'] as num?)?.toInt() ?? 0,
      text: received.body['text'] as String?,
      hasLocation: hasLocation,
    );
    final triaged = _log.append(
      'triage.assessed',
      {
        'urgency': t.urgency.name.toUpperCase(),
        'signals': t.signals,
        'mode': t.mode,
        'evidence': [
          for (final e in t.evidence)
            {'code': e.code, if (e.field != null) 'field': e.field, if (e.quote != null) 'quote': e.quote},
        ],
        'confidence': t.confidence,
        'uncertainty': t.uncertainty,
        'escalate_to_human': t.escalateToHuman,
        'agent_version': kAgentVersion,
      },
      reportKey: received.reportKey,
      rev: received.rev,
      inputs: [normalized.id],
    );
    final out = [normalized, triaged];

    // Agente 3 (auditoría): ¿a qué reportes ya conocidos se parece este?
    final merged = mergeReports(_log.allOfType('report.received'));
    final me = merged.where((m) => m.reportKey == received.reportKey).toList();
    if (me.isNotEmpty) {
      final others = [for (final m in merged) if (m.reportKey != received.reportKey) m.toObservation()];
      final links = linksFor(me.single.toObservation(), others);
      if (links.isNotEmpty) {
        out.add(
          _log.append(
            'incident.linked',
            {
              'links': [
                for (final l in links)
                  {'other': l.b, 'state': l.pair.state.name, 'score': l.pair.score, 'uncertainty': l.pair.uncertainty},
              ],
              'agent_version': kAgentVersion,
            },
            reportKey: received.reportKey,
            rev: received.rev,
            inputs: [triaged.id],
          ),
        );
      }
    }
    // El modelo (si hay) se consulta DESPUÉS: el ACK y los eventos de reglas no esperan por él.
    if (_llm != null) {
      late final Future<void> job;
      job = enrich(received).then<void>((_) {}, onError: (Object _) {}).whenComplete(() => _jobs.remove(job));
      _jobs.add(job);
    }
    return out;
  }

  /// Consulta al modelo de lenguaje sobre el texto vigente de un reporte y, si responde con un
  /// juicio válido, escribe **otro** `triage.assessed` con `mode: 'rules+llm'`, su evidencia citada
  /// y el texto que analizó. Devuelve `null` si no hay modelo, no hay texto, ya se analizó ese
  /// texto o el modelo falló: el triaje por reglas nunca depende de él.
  Future<Event?> enrich(Event received) async {
    final llm = _llm;
    final key = received.reportKey;
    if (llm == null || key == null) return null;
    MergedReport? me() {
      for (final m in mergeReports(_log.allOfType('report.received'))) {
        if (m.reportKey == key) return m;
      }
      return null;
    }

    bool analyzed(String text) => _log.allOfType('triage.assessed').any(
      (e) => e.reportKey == key && e.body['mode'] == 'rules+llm' && e.body['analyzed_text'] == text,
    );

    final m = me();
    final text = m?.text;
    if (m == null || text == null || text.trim().isEmpty || analyzed(text)) return null;
    final t = await triageWithModel(llm, m.flags, text, hasLocation: m.hasLocation);
    if (t.mode != 'rules+llm') return null;
    if (analyzed(text)) return null; // otra consulta terminó mientras esperábamos
    return _log.append(
      'triage.assessed',
      {
        'urgency': t.urgency.name.toUpperCase(),
        'signals': t.signals,
        'mode': t.mode,
        'evidence': [
          for (final e in t.evidence)
            {'code': e.code, if (e.field != null) 'field': e.field, if (e.quote != null) 'quote': e.quote},
        ],
        'confidence': t.confidence,
        'uncertainty': t.uncertainty,
        'escalate_to_human': t.escalateToHuman,
        'analyzed_text': text,
        'agent_version': 'llm-1',
      },
      reportKey: key,
      rev: received.rev,
      inputs: [received.id],
    );
  }
}
