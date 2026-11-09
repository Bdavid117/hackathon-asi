import 'dart:async';

import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';
import 'merged_reports.dart';

/// Versión de las reglas de los agentes; queda escrita en cada evento que producen.
const String kAgentVersion = 'rules-2';

/// Cuántas veces se consultó al modelo, cuántas sirvió y por qué se cayó al respaldo en las demás.
class LlmStats {
  int consultas = 0;
  int usadas = 0;
  final Map<String, int> fallos = {};

  Map<String, Object?> toJson() => {
    'consultas': consultas,
    'usadas': usadas,
    'fallos': {for (final k in fallos.keys.toList()..sort()) k: fallos[k]!},
  };
}

/// Ejecuta los agentes de reglas sobre un `report.received` y deja su rastro en el log:
/// `report.normalized` (agente 1) y `triage.assessed` (agente 2), cada uno apuntando a su entrada.
/// Sólo se invoca para tramas recién guardadas en **este** nodo; los eventos derivados llegan a los
/// demás por replicación. **Trabajo constante por trama**: no recorre el log.
///
/// La auditoría de vínculos (`incident.linked`) NO se hace aquí sino por lotes ([AuditLinker]): la
/// cola no la usa para agrupar (el grupo se calcula al leer sobre los reportes fusionados), así que
/// no hay motivo para pagar su coste en la ruta del ACK. Si hay modelo de lenguaje, se consulta
/// DESPUÉS ([enrich]) y deja su propio evento.
class PipelineRunner {
  PipelineRunner(this._log, {LlmPort? llm, this.onLlmFallback}) : _llm = llm, llmStats = llm == null ? null : LlmStats();

  /// Estadísticas del modelo; `null` si no hay modelo configurado.
  final LlmStats? llmStats;

  /// Se llama con el motivo cada vez que el modelo falla y se usa el respaldo por reglas.
  final void Function(String reason)? onLlmFallback;

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
    final hasLocation = received.body['lat'] != null && received.body['lon'] != null;
    final tri = triage(
      (received.body['flags'] as num?)?.toInt() ?? 0,
      text: received.body['text'] as String?,
      hasLocation: hasLocation,
    );
    // Un solo lote = una sola transacción (un `fsync`) y trabajo constante por trama: nada aquí crece
    // con el número de reportes (la auditoría de vínculos es un lote aparte, ver `AuditLinker`).
    final out = _log.appendAll([
      NewEvent('report.normalized', normalize(received.body), reportKey: received.reportKey, rev: received.rev, inputs: [received.id]),
      NewEvent(
        'triage.assessed',
        {
          'urgency': tri.urgency.name.toUpperCase(),
          'signals': tri.signals,
          'mode': tri.mode,
          'evidence': [
            for (final e in tri.evidence)
              {'code': e.code, if (e.field != null) 'field': e.field, if (e.quote != null) 'quote': e.quote},
          ],
          'confidence': tri.confidence,
          'uncertainty': tri.uncertainty,
          'escalate_to_human': tri.escalateToHuman,
          'agent_version': kAgentVersion,
        },
        reportKey: received.reportKey,
        rev: received.rev,
        chainPrevious: true,
      ),
    ]);

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
    llmStats!.consultas++;
    final t = await triageWithModel(
      llm,
      m.flags,
      text,
      hasLocation: m.hasLocation,
      onFallback: (reason) {
        llmStats!.fallos[reason] = (llmStats!.fallos[reason] ?? 0) + 1;
        onLlmFallback?.call(reason);
      },
    );
    if (t.mode != 'rules+llm') return null;
    if (analyzed(text)) return null; // otra consulta terminó mientras esperábamos
    llmStats!.usadas++;
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
