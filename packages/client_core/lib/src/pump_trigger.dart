import 'dart:async';

/// Decide cuándo lanzar un envío: al volver la conectividad (liberando antes las esperas de
/// reintento, porque una señal nueva merece un intento inmediato) y con el temporizador
/// mientras haya red. Sin red no se gasta batería intentando.
///
/// Nunca solapa dos envíos. Los disparos que llegan demasiado seguidos ([minGap]) no se envían
/// en el acto —una red que parpadea no martillea al nodo— pero **tampoco se pierden**: se
/// repiten una sola vez al terminar el hueco (con la liberación de esperas si alguno la pedía).
/// Un reloj que retrocede (corrección de hora al volver la red) cuenta como hueco superado.
class PumpTrigger {
  PumpTrigger({
    required Future<int> Function() pump,
    required void Function() releaseBackoff,
    this.minGap = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  })  : _pump = pump,
        _releaseBackoff = releaseBackoff,
        _clock = clock ?? DateTime.now;

  final Future<int> Function() _pump;
  final void Function() _releaseBackoff;
  final Duration minGap;
  final DateTime Function() _clock;

  bool _online = true; // optimista hasta saber lo contrario
  DateTime? _lastRun;
  bool _running = false;
  bool _pending = false;
  bool _pendingRelease = false;
  Timer? _trailing;
  bool _trailingRelease = false;

  /// El sistema informa de un cambio de conectividad.
  Future<void> onConnectivity(bool online) async {
    _online = online;
    if (!online) return;
    await _run(release: true);
  }

  /// Un disparo periódico o de otro origen.
  Future<void> onEvent() async {
    if (!_online) return;
    await _run(release: false);
  }

  /// El ciudadano acaba de crear un reporte: se intenta enviar de inmediato aunque acabe de
  /// haber otro intento (el filtro anti-parpadeo no puede tragarse un SOS).
  Future<void> onNewReport() async {
    if (!_online) return;
    await _run(release: false, force: true);
  }

  /// Un envío a la vez. Lo que llega mientras hay uno en curso (un SOS, una reconexión) no se
  /// pierde: se anota y, al terminar el actual, se hace UNA ronda de seguimiento (liberando las
  /// esperas si alguno de los disparos lo pedía).
  Future<void> _run({required bool release, bool force = false}) async {
    if (_running) {
      _pending = true;
      _pendingRelease = _pendingRelease || release;
      return;
    }
    final now = _clock();
    final last = _lastRun;
    if (!force && last != null) {
      final elapsed = now.difference(last);
      // Un reloj que retrocede da una diferencia negativa: el hueco ya pasó, no «es muy reciente».
      if (!elapsed.isNegative && elapsed < minGap) {
        _scheduleTrailing(minGap - elapsed, release);
        return;
      }
    }
    _trailing?.cancel();
    _trailing = null;
    _trailingRelease = false;
    _running = true;
    _lastRun = now;
    try {
      var rel = release;
      while (true) {
        if (rel) _releaseBackoff();
        await _pump();
        if (!_pending) break;
        rel = _pendingRelease;
        _pending = false;
        _pendingRelease = false;
      }
    } finally {
      _running = false;
      _pending = false;
      _pendingRelease = false;
    }
  }

  /// Anota que hay que repetir el disparo descartado cuando termine el hueco anti-parpadeo.
  void _scheduleTrailing(Duration delay, bool release) {
    _trailingRelease = _trailingRelease || release;
    if (_trailing != null) return; // ya hay una repetición programada: se coalescen
    _trailing = Timer(delay, () {
      final rel = _trailingRelease;
      _trailing = null;
      _trailingRelease = false;
      unawaited(_run(release: rel, force: true));
    });
  }

  /// Cancela la repetición pendiente (al cerrar la app o en las pruebas).
  void dispose() {
    _trailing?.cancel();
    _trailing = null;
  }
}
