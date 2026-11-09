import 'event_log.dart';

/// Estado de los pares de este nodo, **en memoria**.
///
/// No se escribe un evento por latido (cada uno invalidaría la caché de la cola y haría crecer el log
/// sin límite) ni por cambio de estado: es información de operación, no un hecho del dominio. Por eso
/// un reinicio la olvida: tras reiniciar, cada par es «desconocido» hasta que se habla con él y el nodo
/// **no afirma «sincronizado» sin haberlo comprobado**.
///
/// «Vista parcial» = es posible que falten eventos que otros nodos ya tienen: algún par desconocido,
/// sin respuesta (más de 3 periodos sin verlo) o con eventos pendientes de traer.
class NodeHealth {
  NodeHealth({required this.nodeId, required List<Uri> peers, this.period = const Duration(seconds: 3), DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _startedAt = (clock ?? DateTime.now)(),
      _peers = {for (final p in peers) p.toString(): _Peer()};

  final String nodeId;

  /// Cada cuánto se sondea a los pares; «sin respuesta» = [kSilentPeriods] periodos sin verlos.
  final Duration period;
  static const int kSilentPeriods = 3;
  final DateTime Function() _clock;
  final DateTime _startedAt;
  final Map<String, _Peer> _peers;

  /// Un sondeo que funcionó: [missingBefore] eventos del par que este nodo no tenía al empezar y
  /// [missingAfter] los que siguen faltando al terminar (0 = al día).
  void recordContact(Uri peer, {required int missingBefore, required int missingAfter}) {
    final p = _peers[peer.toString()];
    if (p == null) return;
    p
      ..lastSeen = _clock()
      ..missing = missingAfter
      ..lastError = null;
    if (missingAfter == 0) p.lastSync = p.lastSeen;
  }

  /// Un sondeo que falló. No cambia el estado hasta pasar [kSilentPeriods] periodos.
  void recordFailure(Uri peer, String reason) {
    final p = _peers[peer.toString()];
    if (p != null) p.lastError = reason.length > 140 ? reason.substring(0, 140) : reason;
  }

  String _state(_Peer p, DateTime now) {
    final seen = p.lastSeen;
    if (seen == null) return 'desconocido';
    if (now.difference(seen) > period * kSilentPeriods) return 'sin_respuesta';
    return p.missing > 0 ? 'atrasado' : 'sincronizado';
  }

  /// El estado servido en `/api/nodes`.
  Map<String, Object?> snapshot(EventLog log) {
    final now = _clock();
    final peers = <Map<String, Object?>>[];
    final reasons = <String>{};
    for (final e in _peers.entries) {
      final p = e.value;
      final state = _state(p, now);
      peers.add({
        'url': e.key,
        'state': state,
        'lastSeenAgoMs': p.lastSeen == null ? null : now.difference(p.lastSeen!).inMilliseconds,
        'lastSyncAgoMs': p.lastSync == null ? null : now.difference(p.lastSync!).inMilliseconds,
        'missingEvents': p.lastSeen == null ? null : p.missing,
        'lastError': p.lastError,
      });
      switch (state) {
        case 'desconocido':
          reasons.add('par_desconocido');
        case 'sin_respuesta':
          reasons.add('par_sin_respuesta');
        case 'atrasado':
          reasons.add('faltan_eventos');
      }
    }
    return {
      'self': {'id': nodeId, 'events': log.count(), 'versionVector': log.versionVector(), 'uptimeMs': now.difference(_startedAt).inMilliseconds},
      'peers': peers,
      'periodMs': period.inMilliseconds,
      'partialView': reasons.isNotEmpty,
      'reasons': reasons.toList()..sort(),
    };
  }
}

class _Peer {
  DateTime? lastSeen;
  DateTime? lastSync;
  int missing = 0;
  String? lastError;
}
