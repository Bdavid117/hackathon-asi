import 'package:sard_agents/sard_agents.dart';

/// Quién hace el trabajo **caro y repetible** de cada reporte (consultar al modelo, auditar vínculos),
/// por *rendezvous hashing* sobre los nodos vivos.
///
///  · El **dueño** (mayor peso) lo hace enseguida; el siguiente en el relevo espera [takeoverAfter], el
///    tercero el doble, y así: si el dueño cae o no cumple, otro lo toma.
///  · **No** gobierna lo esencial: cada nodo sigue recibiendo, guardando, acusando y calculando las reglas
///    por su cuenta (es autosuficiente), así que perder al dueño nunca deja a nadie sin respuesta.
///  · Una **falsa alarma** (el dueño vivía pero tardó) sólo duplica cómputo: los resultados son
///    idempotentes (un juicio por texto analizado; una marca por lote auditado).
///  · Cada nodo decide con **su** vista de quién está vivo; si discrepan, el peor caso es cómputo repetido
///    o un relevo más lento, nunca trabajo perdido.
class OwnershipPolicy {
  OwnershipPolicy({required this.selfId, required Set<String> Function() liveNodes, this.takeoverAfter = const Duration(seconds: 10)}) : _live = liveNodes;

  final String selfId;
  final Duration takeoverAfter;
  final Set<String> Function() _live;

  /// Cuánto debe esperar este nodo antes de hacer el trabajo de [reportKey]: cero si es el dueño (o
  /// está solo), `posición × takeoverAfter` si no.
  Duration delayFor(String reportKey) {
    final rank = rendezvousRank(reportKey, selfId, {..._live(), selfId}) ?? 0;
    return takeoverAfter * rank;
  }

  /// ¿Es este nodo el dueño de [reportKey] según los nodos vivos que ve?
  bool isOwner(String reportKey) => delayFor(reportKey) == Duration.zero;

  /// ¿Le toca ya a este nodo el trabajo de un reporte recibido en [receivedAt]? Sí si es el dueño o si
  /// ya pasó su plazo de relevo.
  bool due(String reportKey, DateTime receivedAt, DateTime now) => now.difference(receivedAt) >= delayFor(reportKey);
}
