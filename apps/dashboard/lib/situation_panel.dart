import 'package:flutter/material.dart';

import 'models.dart';
import 'theme.dart';

/// Lo que se ve a la derecha mientras NO hay un incidente elegido (en pantalla ancha): la situación del propio tablero, con lo que ya
/// sabe sin pedir nada más: cómo está la red de nodos, qué unidades hay y los tres principios con los que se lee.
///
/// Dice lo que se sabe y nada más: sin pares configurados lo dice («trabaja solo»); si no pudo leer los nodos no afirma nada de la red;
/// sin unidades declaradas no dice «ninguna» (puede ser un nodo anterior que no las sirve); y no inventa horas ni causas.
class SituationPanel extends StatelessWidget {
  const SituationPanel({super.key, required this.nodes, required this.nodesUnknown, required this.resources});

  final NodesStatus? nodes;

  /// No se pudo leer el estado de los nodos.
  final bool nodesUnknown;
  final List<ResourceUnit> resources;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Situación', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('Elige un incidente para ver por qué tiene esa prioridad y qué se recomienda.', key: Key('situation_hint'), style: TextStyle(fontSize: 14, color: DashColors.muted, height: 1.3)),
              const SizedBox(height: 16),
              _NodesCard(nodes: nodes, unknown: nodesUnknown),
              if (resources.isNotEmpty) ...[const SizedBox(height: 12), _ResourcesCard(resources: resources)],
              const SizedBox(height: 12),
              const _Principles(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.cardKey});

  final String title;
  final Widget child;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) => Container(
    key: cardKey,
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: DashColors.surface, borderRadius: BorderRadius.circular(12)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 10), child],
    ),
  );
}

Color _stateColor(String s) => switch (s) {
  'sincronizado' => DashColors.ok,
  'atrasado' => DashColors.warn,
  _ => DashColors.danger,
};

class _NodesCard extends StatelessWidget {
  const _NodesCard({required this.nodes, required this.unknown});

  final NodesStatus? nodes;
  final bool unknown;

  /// «hace 2 s» (sin hora, nada: un par sin contacto todavía no tiene un «hace 0 s»).
  static String _ago(int? ms) => ms == null ? '' : ' · hace ${ms < 1000 ? 'menos de 1' : (ms / 1000).round()} s';

  @override
  Widget build(BuildContext context) {
    final n = nodes;
    final Widget body;
    if (n == null) {
      body = unknown
          ? const Row(
              key: Key('situation_nodes_unknown'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.device_hub, size: 18, color: DashColors.warn),
                SizedBox(width: 8),
                Expanded(child: Text('No se pudo leer el estado de los nodos: no se puede afirmar que la vista esté completa.', style: TextStyle(fontSize: 14, color: DashColors.warn, height: 1.3))),
              ],
            )
          : const SizedBox.shrink();
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.circle, size: 10, color: DashColors.ok),
            const SizedBox(width: 8),
            Expanded(child: Text('Nodo ${n.selfId} (este) · ${n.events} eventos', key: const Key('situation_self'), style: const TextStyle(fontSize: 14))),
          ]),
          if (n.peers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Sin pares configurados: este nodo trabaja solo. Si cae, nadie más tiene sus reportes (los pares se configuran con --peers).',
                key: Key('situation_alone'),
                style: TextStyle(fontSize: 13, color: DashColors.warn, height: 1.3),
              ),
            ),
          for (var i = 0; i < n.peers.length; i++) _peer(i, n.peers[i]),
          if (n.partialView)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text.rich(
                TextSpan(children: [const TextSpan(text: 'Vista parcial. ', style: TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: n.reasons.map(partialReasonLabel).join(' '))]),
                key: const Key('situation_partial'),
                style: const TextStyle(fontSize: 13, color: DashColors.warn, height: 1.3),
              ),
            ),
        ],
      );
    }
    return _Card(cardKey: const Key('situation_nodes'), title: 'Red de nodos', child: body);
  }

  Widget _peer(int i, PeerInfo p) {
    final name = peerName(p.url);
    final missing = (p.missingEvents ?? 0) > 0 ? ' · faltan ${p.missingEvents} eventos' : '';
    final raw = p.lastError ?? '';
    final error = raw.isEmpty ? '' : ' · ${peerErrorSummary(raw)}';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 4), child: Icon(Icons.circle, key: Key('situation_peer_dot_$i'), size: 10, color: _stateColor(p.state))),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              key: Key('situation_peer_error_$i'),
              message: raw,
              triggerMode: TooltipTriggerMode.tap,
              child: Text('$name: ${peerStateLabel(p.state)}${_ago(p.lastSeenAgoMs)}$missing$error', key: Key('situation_peer_$i'), style: const TextStyle(fontSize: 14, height: 1.3)),
            ),
          ),
        ],
      ),
    );
  }
}

/// El error de un par en palabras: lo que el nodo manda es el texto de una excepción (con puertos efímeros y rutas), que no le dice nada a quien
/// coordina. Las causas conocidas se dicen en español; lo demás se recorta. El texto completo se conserva aparte (tooltip): nada se esconde.
String peerErrorSummary(String raw) {
  final r = raw.trim();
  if (r.isEmpty) return '';
  final l = r.toLowerCase();
  if (l.contains('connection refused')) return 'conexión rechazada';
  if (l.contains('timeoutexception') || l.contains('timed out')) return 'sin respuesta a tiempo';
  if (l.contains('no route to host') || l.contains('network is unreachable')) return 'sin ruta hasta el nodo';
  if (l.contains('connection reset')) return 'conexión cortada';
  return r.length > 60 ? '${r.substring(0, 60)}…' : r;
}

class _ResourcesCard extends StatelessWidget {
  const _ResourcesCard({required this.resources});

  final List<ResourceUnit> resources;

  @override
  Widget build(BuildContext context) {
    final conflict = resources.where((u) => u.conflict).length;
    // Una unidad en conflicto NO se ofrece (el nodo no la propone): no cuenta como disponible ni como no disponible.
    final available = resources.where((u) => u.available && !u.conflict).length;
    final unavailable = resources.where((u) => !u.available && !u.conflict).length;
    final n = resources.length;
    return _Card(
      title: 'Recursos',
      child: Text(
        '$n ${n == 1 ? 'unidad' : 'unidades'} · $available ${available == 1 ? 'disponible' : 'disponibles'} · $unavailable ${unavailable == 1 ? 'no disponible' : 'no disponibles'} · $conflict en conflicto',
        key: const Key('situation_resources'),
        style: TextStyle(fontSize: 14, height: 1.3, color: conflict > 0 ? DashColors.danger : DashColors.text),
      ),
    );
  }
}

class _Principles extends StatelessWidget {
  const _Principles();

  static const List<String> lines = [
    'Nada se ejecuta solo: toda recomendación es una propuesta que espera la aprobación de una persona.',
    'La vista corta no esconde nada: los contadores dicen cuántos incidentes quedan fuera de ella.',
    'El silencio no es seguridad: una zona de la que no llegan reportes no es una zona a salvo.',
  ];

  @override
  Widget build(BuildContext context) => _Card(
    title: 'Cómo leer este tablero',
    child: Column(
      key: const Key('situation_principles'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 5, color: DashColors.muted)),
              const SizedBox(width: 8),
              Expanded(child: Text(l, style: const TextStyle(fontSize: 14, height: 1.35, color: DashColors.muted))),
            ]),
          ),
      ],
    ),
  );
}
