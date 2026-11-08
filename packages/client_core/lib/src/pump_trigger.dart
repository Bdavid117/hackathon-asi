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

  Future<void> _run({required bool release}) async {
    if (_running) return;
    final now = _clock();
    final last = _lastRun;
    if (last != null && now.difference(last) < minGap) return;
    _running = true;
    _lastRun = now;
    try {
      if (release) _releaseBackoff();
      await _pump();
    } finally {
      _running = false;
    }
  }
}
