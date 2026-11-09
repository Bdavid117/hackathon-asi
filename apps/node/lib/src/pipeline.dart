import 'dart:async';
import 'dart:collection';

import 'package:sard_agents/sard_agents.dart';

import 'device_budget.dart';
import 'event_log.dart';
import 'merged_reports.dart';
import 'ownership.dart';

/// Versión de las reglas de los agentes; queda escrita en cada evento que producen.
const String kAgentVersion = 'rules-2';

/// Cuántas veces se consultó al modelo, cuántas sirvió y por qué se cayó al respaldo en las demás.
class LlmStats {
  int consultas = 0;
  int usadas = 0;

  /// Consultas que NO se hicieron porque ya había el máximo en vuelo y la espera estaba llena: esos
  /// reportes se quedan con las reglas (más el juicio de otro nodo, si le toca).
  int omitidas = 0;
  final Map<String, int> fallos = {};

  Map<String, Object?> toJson() => {
    'consultas': consultas,
    'usadas': usadas,
    'omitidas': omitidas,
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
  PipelineRunner(this._log, {LlmPort? llm, this.onLlmFallback, DeviceBudget? budget, this.ownership, this.maxModelInFlight = 16, this.maxModelQueued = 1000})
    : _llm = llm,
      llmStats = llm == null ? null : LlmStats(),
      budget = budget ?? DeviceBudget();

  /// Presupuesto de trabajo caro por dispositivo (degrada, no rechaza).
  final DeviceBudget budget;

  /// Reparto del modelo entre nodos (*rendezvous*); `null` = este nodo lo hace todo (un nodo solo).
  final OwnershipPolicy? ownership;

  /// Tope de consultas al modelo **a la vez** y de consultas **en espera** de un hueco. Cada consulta
  /// abierta es un socket: con un modelo colgado y cientos de tramas por segundo, sin tope se agotan los
  /// descriptores de archivo (medido con el límite típico de 1 024: 2 726 de 5 000 tramas rechazadas y el
  /// nodo muerto). Lo que excede el tope no se consulta: se queda con las reglas y se cuenta en `omitidas`.
  final int maxModelInFlight;
  final int maxModelQueued;

  /// Estadísticas del modelo; `null` si no hay modelo configurado.
  final LlmStats? llmStats;

  /// Se llama con el motivo cada vez que el modelo falla y se usa el respaldo por reglas.
  final void Function(String reason)? onLlmFallback;

  final EventLog _log;
  final LlmPort? _llm;
  final Set<Future<void>> _jobs = {};

  /// Espera a que terminen las consultas al modelo que estén en curso (para pruebas y apagado).
  Future<void> get idle async {
    while (_jobs.isNotEmpty || _waiting.isNotEmpty || _delayed > 0) {
      if (_jobs.isNotEmpty) {
        await Future.wait(_jobs.toList());
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
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

    // Una ficha por trama NUEVA ya guardada. Si el dispositivo se pasó, la trama se guarda y se acusa
    // igual (las reglas ya corrieron); sólo se omite lo caro: la consulta al modelo.
    final withinBudget = budget.take(received.body['device_id'] as String? ?? received.reportKey ?? '?');

    // El modelo (si hay) se consulta DESPUÉS: el ACK y los eventos de reglas no esperan por él.
    if (_llm != null && withinBudget) _scheduleModel(received);
    return out;
  }

  /// Reportes cuya consulta al modelo está pendiente en este nodo («clave#rev»): evita consultar dos veces
  /// el mismo cuando llega por la trama y además por replicación.
  final Set<String> _pending = {};
  final Queue<(Event, String)> _waiting = Queue();
  int _inFlight = 0;
  int _delayed = 0;

  /// Programa la consulta al modelo de [received]: enseguida si este nodo es el dueño; si no, tras su
  /// plazo de relevo (y sólo si el evento del dueño no llegó replicado entretanto). Quien espera su turno
  /// de relevo **no ocupa un hueco** del tope: sólo cuenta cuando ya le toca.
  void _scheduleModel(Event received) {
    final key = received.reportKey;
    if (_llm == null || key == null) return;
    final id = '$key#${received.rev}';
    if (!_pending.add(id)) return;
    final wait = ownership?.delayFor(key) ?? Duration.zero;
    if (wait == Duration.zero) {
      _admit(received, id);
      return;
    }
    _delayed++;
    Future<void>.delayed(wait).then((_) {
      _delayed--;
      _admit(received, id);
    });
  }

  /// Admite una consulta: la lanza si hay hueco, la deja en espera si cabe, o la omite (y la cuenta).
  void _admit(Event received, String id) {
    if (_inFlight < maxModelInFlight) {
      _startModel(received, id);
    } else if (_waiting.length < maxModelQueued) {
      _waiting.add((received, id));
    } else {
      llmStats!.omitidas++;
      _pending.remove(id); // podrá reintentarse cuando haya hueco
    }
  }

  void _startModel(Event received, String id) {
    _inFlight++;
    late final Future<void> job;
    job = enrich(received).then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _jobs.remove(job);
      _inFlight--;
      _pending.remove(id);
      while (_inFlight < maxModelInFlight && _waiting.isNotEmpty) {
        final (e, nextId) = _waiting.removeFirst();
        _startModel(e, nextId);
      }
    });
    _jobs.add(job);
  }

  /// Un evento llegó por replicación. Si es un reporte recibido en OTRO nodo, este nodo (si es su dueño,
  /// o cuando le toque el relevo) consulta al modelo igual que si la trama hubiera llegado aquí. Las
  /// reglas y el ACK ya los hizo el nodo que recibió la trama: aquí sólo se reparte el trabajo caro.
  void onReplicated(Event event) {
    if (event.type == 'report.received') _scheduleModel(event);
  }

  /// Consulta al modelo de lenguaje sobre el texto vigente de un reporte y, si responde con un
  /// juicio válido, escribe **otro** `triage.assessed` con `mode: 'rules+llm'`, su evidencia citada
  /// y el texto que analizó. Devuelve `null` si no hay modelo, no hay texto, ya se analizó ese
  /// texto o el modelo falló: el triaje por reglas nunca depende de él.
  Future<Event?> enrich(Event received) async {
    final llm = _llm;
    final key = received.reportKey;
    if (llm == null || key == null) return null;
    // Sólo los eventos DE ESTE reporte (por el índice): el coste no crece con el tamaño del log.
    MergedReport? me() {
      final merged = mergeReports(_log.eventsFor(key, type: 'report.received'));
      return merged.isEmpty ? null : merged.first;
    }

    bool analyzed(String text) => _log.eventsFor(key, type: 'triage.assessed').any(
      (e) => e.body['mode'] == 'rules+llm' && e.body['analyzed_text'] == text,
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
