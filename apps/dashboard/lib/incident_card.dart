import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

/// Una pastilla de texto (nunca sólo color).
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = DashColors.muted, this.filled = false, this.icon});

  final String text;
  final Color color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: filled ? DashColors.bg : color), const SizedBox(width: 4)],
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: filled ? DashColors.bg : color))),
        ],
      ),
    );
  }
}

/// La insignia de urgencia: texto P1–P4 sobre su color.
class UrgencyBadge extends StatelessWidget {
  const UrgencyBadge(this.urgency, {super.key, this.large = false});

  final String urgency;
  final bool large;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: large ? 12 : 9, vertical: large ? 6 : 4),
    decoration: BoxDecoration(color: DashColors.urgency(urgency), borderRadius: BorderRadius.circular(8)),
    child: Text(urgency, style: TextStyle(fontSize: large ? 18 : 15, fontWeight: FontWeight.w900, color: DashColors.onUrgency(urgency))),
  );
}

String headlineOf(IncidentRow r) => r.bareSos ? 'SOS sin detalle' : (r.signals.isEmpty ? 'Sin indicadores' : r.signals.map(signalLabel).join(' · '));

String countsLine(IncidentRow r) => [
  r.size == 1 ? '1 reporte' : '${r.size} reportes',
  if (r.people != 0) '${r.peopleLabel} personas',
  r.sources == 1 ? '1 fuente' : '${r.sources} fuentes',
].join(' · ');

String recommendationChip(IncidentRow r) => switch (r.recommendation.state) {
  'propuesta' => r.recommendation.actions.map(actionLabel).join(' + '),
  'informacion_requerida' => 'Falta información',
  _ => 'Propuesta descartada',
};

/// La tarjeta de un incidente en la lista: urgencia, qué pasa, cuántos reportes, por qué dudar y en
/// qué punto está la decisión.
class IncidentCard extends StatelessWidget {
  const IncidentCard({super.key, required this.row, required this.now, required this.selected, required this.onTap});

  final IncidentRow row;
  final DateTime now;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final urgency = DashColors.urgency(row.urgency);
    final proposed = row.recommendation.state == 'propuesta';
    final approval = row.approval;
    final showApproval = proposed || approval.status != 'pendiente';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: selected ? DashColors.surfaceHigh : DashColors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('incident_${row.id}'),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: urgency, width: 6)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (selected) SizedBox(key: Key('selected_${row.id}'), width: 0, height: 0),
                UrgencyBadge(row.urgency),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(headlineOf(row), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(countsLine(row), style: const TextStyle(fontSize: 13, color: DashColors.muted)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (row.needsReview) const Pill('Revisar', color: DashColors.warn, filled: true),
                          if (row.highUncertainty) const Pill('Incertidumbre alta', color: DashColors.warn, icon: Icons.help_outline),
                          if (!row.hasLocation) const Pill('Sin ubicación', color: DashColors.muted, icon: Icons.location_off_outlined),
                          Pill(recommendationChip(row), color: proposed ? DashColors.text : DashColors.muted),
                          if (showApproval) _approvalPill(approval),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(ageLabel(row.firstAt, now), style: const TextStyle(fontSize: 12, color: DashColors.muted)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _approvalPill(ApprovalBrief a) {
    if (a.discrepancy) return const Pill('Decisiones contradictorias', color: DashColors.danger, filled: true, icon: Icons.warning_amber_rounded);
    return switch (a.status) {
      'aprobada' => const Pill('Aprobada', color: DashColors.ok, icon: Icons.check_circle_outline),
      'denegada' => const Pill('Rechazada', color: DashColors.danger, icon: Icons.block),
      'caduca' => const Pill('Caducada', color: DashColors.warn, icon: Icons.history),
      _ => const Pill('Pendiente de decisión', color: DashColors.muted),
    };
  }
}
