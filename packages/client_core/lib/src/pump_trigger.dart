/// Decide cuándo lanzar un envío: al volver la conectividad (liberando antes las esperas de
/// reintento, porque una señal nueva merece un intento inmediato) y con el temporizador
/// mientras haya red. Sin red no se gasta batería intentando.
///
/// Nunca solapa dos envíos y descarta los disparos que lleguen demasiado seguidos
/// ([minGap]), de modo que una red que parpadea no martillea al nodo.
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
    if (!force && last != null && now.difference(last) < minGap) return;
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
}
