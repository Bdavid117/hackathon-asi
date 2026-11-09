import 'package:flutter/material.dart';
import 'package:sard_client_core/sard_client_core.dart';

import 'incidents.dart';
import 'sos_screen.dart' show kStatusSlotHeight;
import 'state_labels.dart';
import 'theme.dart';

/// «hace 3 min», o la hora si pasó más de una hora. Un reloj que retrocede no da tiempos negativos.
String agoLabel(DateTime now, DateTime at) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return 'ahora mismo';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  return clockLabel(at);
}

/// «18:07».
String clockLabel(DateTime at) {
  final l = at.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Qué hacer (o no hacer) según el estado, en una frase.
String stateHelp(OutboxEntry e) => switch (e.state) {
  OutboxState.queued || OutboxState.expired =>
    'Sale solo en cuanto haya señal. No hace falta volver a tocar.',
  OutboxState.sending => 'Un momento…',
  OutboxState.sent => 'Un nodo de SARD ya tiene tu aviso.',
  OutboxState.confirmed => 'SARD ya tiene tu aviso.',
};

(IconData, Color) _look(OutboxState s) => switch (s) {
  OutboxState.queued ||
  OutboxState.expired => (Icons.schedule, SardColors.wait),
  OutboxState.sending => (Icons.sync, SardColors.wait),
  OutboxState.sent => (Icons.check_circle, SardColors.ok),
  OutboxState.confirmed => (Icons.verified, SardColors.ok),
};

/// Un aviso: el SOS y todo lo que se le fue añadiendo, con su estado en lenguaje llano.
/// [hero] es el aviso en curso, grande, justo debajo del botón.
class IncidentCard extends StatelessWidget {
  const IncidentCard({
    super.key,
    required this.incident,
    required this.now,
    this.hero = false,
    this.statusKey,
  });

  final Incident incident;
  final DateTime now;
  final bool hero;
  final Key? statusKey;

  Widget _location() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        incident.hasLocation ? Icons.location_on : Icons.location_off_outlined,
        size: 18,
        color: SardColors.muted,
      ),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          incident.hasLocation ? 'Con ubicación' : 'Sin ubicación todavía',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, color: SardColors.muted),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final e = incident.sos;
    final (icon, color) = _look(e.state);
    final statusText = Text(
      stateLabel(e),
      key: statusKey,
      style: TextStyle(
        fontSize: hero ? 22 : 16,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    );

    if (!hero) {
      return Container(
        key: Key('report_${e.frameSeq}'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: SardColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SOS de las ${clockLabel(incident.at)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  statusText,
                  if (incident.flagLabels.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      incident.flagLabels.join(', '),
                      style: const TextStyle(
                        fontSize: 14,
                        color: SardColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              incident.hasLocation
                  ? Icons.location_on
                  : Icons.location_off_outlined,
              size: 20,
              color: SardColors.muted,
              semanticLabel: incident.hasLocation
                  ? 'Con ubicación'
                  : 'Sin ubicación',
            ),
          ],
        ),
      );
    }

    final pending =
        incident.updatePending &&
        (e.state == OutboxState.sent || e.state == OutboxState.confirmed);
    return Container(
      key: Key('report_${e.frameSeq}'),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minHeight: kStatusSlotHeight),
      decoration: BoxDecoration(
        color: SardColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 38, color: color),
          const SizedBox(width: 14),
          // Tres zonas de alto fijo: el contenido cambia (estado, ubicación, actualización pendiente)
          // pero la tarjeta mide siempre lo mismo y no empuja los indicadores de debajo.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // El titular se ajusta al ancho en una sola línea: nunca se parte en dos.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 30),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: statusText,
                  ),
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 64),
                  child: Text(
                    pending
                        ? 'Falta enviar tu última actualización.'
                        : stateHelp(e),
                    key: pending ? const Key('update_pending') : null,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, height: 1.3),
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 22),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          agoLabel(now, incident.at),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: SardColors.muted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Flexible(child: _location()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
