import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

const List<String> _agentOrder = ['1 · Recepción', '2 · Triaje', '3 · Correlación', '6 · Coordinación', 'Persona'];

String _clock(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

/// La «Historia» de un incidente: qué hizo cada agente y quién decidió qué.
///
/// Plegada por omisión y de altura constante cuando está plegada (no empuja nada: sólo una cabecera con el conteo). Dice lo que NO
/// sabe: los pasos DERIVADOS se calculan al leer y no tienen hora; los agentes 4 y 5 no dejan eventos por incidente; la auditoría
/// no registra qué se aprobó (sólo el identificador de la versión).
class IncidentHistoryPanel extends StatefulWidget {
  const IncidentHistoryPanel({super.key, required this.history});

  final HistoryInfo history;

  @override
  State<IncidentHistoryPanel> createState() => _IncidentHistoryPanelState();
}

class _IncidentHistoryPanelState extends State<IncidentHistoryPanel> {
  bool _open = false;
  bool _audit = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.history;
    final count = h.stepsTotal > h.steps.length ? '${h.steps.length} de ${h.stepsTotal} pasos (los más recientes)' : '${h.stepsTotal} ${h.stepsTotal == 1 ? 'paso' : 'pasos'}';
    return Container(
      key: const Key('history_panel'),
      width: double.infinity,
      decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const Key('history_toggle'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Text('Historia', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(width: 12),
                  // Una sola línea SIEMPRE (se encoge, no se parte): la cabecera plegada mide lo mismo con 3 pasos que con 1 500.
                  Expanded(child: Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown, child: Text(count, key: const Key('history_count'), maxLines: 1, style: const TextStyle(fontSize: 12, color: DashColors.muted))))),
                  const SizedBox(width: 8),
                  Icon(_open ? Icons.expand_less : Icons.expand_more, color: DashColors.muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(key: const Key('history_tab_agents'), label: const Text('Agentes'), selected: !_audit, onSelected: (_) => setState(() => _audit = false)),
                      ChoiceChip(key: const Key('history_tab_audit'), label: const Text('Decisiones'), selected: _audit, onSelected: (_) => setState(() => _audit = true)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_audit) _AuditTab(h) else _AgentsTab(h),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AgentsTab extends StatelessWidget {
  const _AgentsTab(this.h);
  final HistoryInfo h;

  @override
  Widget build(BuildContext context) {
    final byAgent = <String, List<(int, HistoryStepInfo)>>{};
    for (var i = 0; i < h.steps.length; i++) {
      (byAgent[h.steps[i].agent] ??= []).add((i, h.steps[i]));
    }
    final agents = [..._agentOrder.where(byAgent.containsKey), ...byAgent.keys.where((a) => !_agentOrder.contains(a))];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (h.steps.any((s) => s.derived))
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Lo «derivado» se calcula al leer, a partir de estos eventos: no tiene hora propia.', key: Key('history_derived_note'), style: TextStyle(fontSize: 12, color: DashColors.muted, height: 1.3)),
          ),
        for (final a in agents) ...[
          Padding(padding: const EdgeInsets.only(top: 6, bottom: 2), child: Text(a, key: const Key('history_agent_title'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashColors.ok))),
          for (final (i, s) in byAgent[a]!) _StepRow(index: i, step: s),
        ],
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('Los agentes 4 (comunicación, en el teléfono) y 5 (resiliencia, estado de los nodos) no dejan eventos por incidente: no hay fila para ellos.', key: Key('history_no_rows_note'), style: TextStyle(fontSize: 12, color: DashColors.muted, height: 1.3)),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.step});
  final int index;
  final HistoryStepInfo step;

  @override
  Widget build(BuildContext context) {
    final meta = step.derived ? 'derivado de estos eventos' : '${step.nodeId == null ? 'nodo ?' : 'nodo ${step.nodeId}'}${step.atMs == null ? '' : ' · ${_clock(step.atMs!)}'}';
    return Semantics(
      container: true,
      label: '${step.agent}, $meta: ${step.summary}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            key: Key('history_step_$index'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.summary, key: Key('history_step_text_$index'), style: const TextStyle(fontSize: 14, height: 1.25)),
              Text(meta, key: Key('history_step_meta_$index'), style: const TextStyle(fontSize: 12, color: DashColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditTab extends StatelessWidget {
  const _AuditTab(this.h);
  final HistoryInfo h;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (h.audit.isEmpty) const Text('Todavía nadie ha decidido sobre este incidente.', key: Key('history_audit_empty'), style: TextStyle(fontSize: 14)),
        if (h.auditTotal > h.audit.length)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('${h.audit.length} de ${h.auditTotal} decisiones (las más recientes)', key: const Key('history_audit_count'), style: const TextStyle(fontSize: 12, color: DashColors.muted))),
        for (var i = 0; i < h.audit.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '${h.audit[i].who} ${h.audit[i].granted ? 'aprobó' : 'rechazó'} · ${_clock(h.audit[i].atMs)} · ${h.audit[i].status}'
              '${h.audit[i].supersedes.isEmpty ? '' : ' · sustituye a ${h.audit[i].supersedes.join(', ')}'}'
              '${h.audit[i].note == null ? '' : ' · «${h.audit[i].note}»'}',
              key: Key('history_audit_$i'),
              style: const TextStyle(fontSize: 14, height: 1.25),
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('El registro sólo guarda el identificador de la versión de la recomendación: aquí no se puede ver qué se aprobó.', key: Key('history_audit_note'), style: TextStyle(fontSize: 12, color: DashColors.muted, height: 1.3)),
        ),
      ],
    );
  }
}
