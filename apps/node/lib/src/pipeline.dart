import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';

/// Ejecuta los agentes de reglas sobre un `report.received` y deja su rastro en el log:
/// `report.normalized` (agente 1) y `triage.assessed` (agente 2), cada uno apuntando
/// a su entrada. Sólo se invoca para tramas recién guardadas en **este** nodo; los eventos
/// derivados llegan a los demás por replicación.
class PipelineRunner {
  PipelineRunner(this._log);

  final EventLog _log;

  List<Event> run(Event received) {
    final normalized = _log.append(
      'report.normalized',
      normalize(received.body),
      reportKey: received.reportKey,
      rev: received.rev,
      inputs: [received.id],
    );
    final t = triage(received.body['flags']! as int, text: received.body['text'] as String?);
    final triaged = _log.append(
      'triage.assessed',
      {'urgency': t.urgency.name.toUpperCase(), 'signals': t.signals, 'mode': t.mode},
      reportKey: received.reportKey,
      rev: received.rev,
      inputs: [normalized.id],
    );
    return [normalized, triaged];
  }
}
