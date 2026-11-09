import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'incidents.dart';
import 'reports_screen.dart';
import 'sos_screen.dart';
import 'theme.dart';

/// La app ciudadana: SOS en un toque y estado de entrega.
class SardApp extends StatefulWidget {
  const SardApp({
    super.key,
    required this.outbox,
    this.scheduler,
    this.refreshEvery = const Duration(seconds: 1),
    this.clock,
    this.battery,
    this.location,
    this.onNewReport,
    this.online,
  });

  final Outbox outbox;

  /// Si se da, se intenta enviar de inmediato al crear un reporte.
  final SendScheduler? scheduler;

  /// Cada cuánto se relee la bandeja para reflejar los ACK; `null` lo desactiva.
  final Duration? refreshEvery;
  final DateTime Function()? clock;

  /// Porcentaje de batería (0..100) o `null` si no se conoce. Si falla o no se da, la app
  /// se comporta en modo normal y marca la batería con el valor «desconocido» de la trama.
  final Future<int?> Function()? battery;

  /// Fuente de ubicación. Sin ella (o sin permiso) los reportes salen con ubicación «ninguna».
  final LocationProvider? location;

  /// Cómo pedir el envío tras crear un reporte. En la app real pasa por [PumpTrigger] (no intenta
  /// enviar sin red y nunca descarta un SOS por el filtro anti-parpadeo). Si no se da, se usa
  /// el `scheduler` directamente.
  final Future<void> Function()? onNewReport;

  /// ¿Hay red? Si es `false` se avisa con claridad que el SOS se guarda y saldrá solo.
  /// Sin este dato (`null`) no se muestra ningún aviso de señal.
  final ValueListenable<bool>? online;

  @override
  State<SardApp> createState() => _SardAppState();
}

class _SardAppState extends State<SardApp> {
  int _selected = 0;
  int? _percent;
  LocationFix? _cachedFix;
  // El «reporte vivo»: el último SOS y sus banderas. Dentro de [sosDebounce] los toques siguientes
  // lo completan en vez de crear otro reporte.
  String? _liveKey;
  int _liveFlags = 0;
  DateTime? _liveAt;
  bool _saveError = false;

  /// Pánico: toques repetidos en menos de este plazo son el mismo SOS, no uno por toque.
  static const Duration sosDebounce = Duration(seconds: 2);

  /// Mientras el aviso está vivo (10 min desde el SOS o su última actualización) los indicadores
  /// que se marcan salen enseguida como una actualización de ese mismo aviso: primero se toca SOS
  /// —lo urgente, de un toque— y después se cuenta qué pasa, sin prisa.
  static const Duration detailWindow = Duration(minutes: 10);
  Timer? _timer;
  Timer? _batteryTimer;

  PowerMode get _mode => powerModeFor(_percent);

  @override
  void initState() {
    super.initState();
    _applyTimers();
    unawaited(_readBattery());
    unawaited(_readLocationCache());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _batteryTimer?.cancel();
    super.dispose();
  }

  /// En modo ahorro la lista se refresca cinco veces más despacio.
  void _applyTimers() {
    _timer?.cancel();
    _batteryTimer?.cancel();
    final every = widget.refreshEvery;
    if (every == null) return;
    _timer = Timer.periodic(
      _mode == PowerMode.normal ? every : every * 5,
      (_) => setState(() {}),
    );
    _batteryTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_readBattery()),
    );
  }

  /// Memoriza la última posición conocida para poder usarla al instante al tocar SOS.
  Future<void> _readLocationCache() async {
    final p = widget.location;
    if (p == null) return;
    try {
      _cachedFix = await p.lastKnown();
    } on Object {
      _cachedFix = null; // sin permiso o GPS apagado: el SOS sale sin ubicación
    }
  }

  Future<void> _readBattery() async {
    final read = widget.battery;
    if (read == null) return;
    int? p;
    try {
      p = await read();
    } on Object {
      p = null; // sin dato: modo normal
    }
    if (!mounted || p == _percent) return;
    final before = _mode;
    setState(() => _percent = p);
    if (_mode != before) _applyTimers();
  }

  /// ¿Hay un aviso vivo al que añadir detalles? Un reloj que retrocede no cuenta como «vivo».
  bool _isDetailLive(DateTime now) {
    final at = _liveAt;
    if (_liveKey == null || at == null) return false;
    final elapsed = now.difference(at);
    return !elapsed.isNegative && elapsed < detailWindow;
  }

  void _haptic(Future<void> Function() f) =>
      unawaited(f().catchError((Object _) {}));

  void _toggle(int bit) {
    final now = (widget.clock ?? DateTime.now)();
    if (_isDetailLive(now)) {
      if (_liveFlags & bit != 0) return; // ya salió con el aviso: no se quita
      final union = _liveFlags | bit;
      try {
        widget.outbox.enqueueRevision(
          _liveKey!,
          _report(flags: union, fix: _usableFix(now)),
          now: now,
        );
      } on Object {
        _saveFailed();
        return;
      }
      _haptic(HapticFeedback.selectionClick);
      _liveFlags = union;
      _liveAt = now;
      setState(() => _saveError = false);
      _requestSend();
      return;
    }
    _haptic(HapticFeedback.selectionClick);
    setState(() => _selected ^= bit);
  }

  NewReport _report({required int flags, LocationFix? fix}) {
    final q = fix == null
        ? LocQuality.none
        : locQualityFromAccuracy(fix.accuracyMeters);
    return NewReport(
      incidentType: 1, // SOS genérico
      flags: flags,
      peopleBucket: 0,
      batteryQ: batteryQFromPercent(_percent),
      locQuality: q,
      lat: q.hasCoordinates ? fix!.lat : null,
      lon: q.hasCoordinates ? fix!.lon : null,
    );
  }

  /// Guarda el SOS al instante. Usa la posición conocida sólo si es reciente y utilizable;
  /// si no, el reporte sale sin ubicación y se pide una lectura nueva en segundo plano que,
  /// si llega, se envía como **revisión del mismo reporte** (nunca como un reporte nuevo).
  /// La posición conocida, si es reciente y tiene precisión utilizable.
  LocationFix? _usableFix(DateTime now) {
    final cached = _cachedFix;
    if (cached != null &&
        cached.isFresh(now) &&
        locQualityFromAccuracy(cached.accuracyMeters).hasCoordinates) {
      return cached;
    }
    return null;
  }

  /// ¿Estamos dentro de la ventana del reporte vivo? Un reloj que retrocede (corrección de hora
  /// al volver la red) da un tiempo transcurrido negativo y NO cuenta como «dentro»: un SOS no
  /// puede quedar silenciado por un cambio de hora.
  bool _isLive(DateTime now) {
    final at = _liveAt;
    if (_liveKey == null || at == null) return false;
    final elapsed = now.difference(at);
    return !elapsed.isNegative && elapsed < sosDebounce;
  }

  void _saveFailed() {
    if (mounted) setState(() => _saveError = true);
  }

  /// Guarda el SOS al instante. Usa la posición conocida sólo si es reciente y utilizable;
  /// si no, el reporte sale sin ubicación y se pide una lectura nueva en segundo plano que,
  /// si llega, se envía como **revisión del mismo reporte** (nunca como un reporte nuevo).
  ///
  /// Toques repetidos en menos de [sosDebounce] son el mismo SOS: si traen banderas nuevas se
  /// envían como revisión del mismo reporte con la **unión** de banderas; si no, no hacen nada.
  /// Si guardar falla, se avisa y el reintento inmediato no se descarta.
  void _sos() {
    _haptic(HapticFeedback.heavyImpact);
    final now = (widget.clock ?? DateTime.now)();
    final flags = _selected;

    if (_isLive(now)) {
      final union = _liveFlags | flags;
      if (union == _liveFlags) return; // el mismo SOS: nada que añadir
      try {
        widget.outbox.enqueueRevision(
          _liveKey!,
          _report(flags: union, fix: _usableFix(now)),
          now: now,
        );
      } on Object {
        _saveFailed();
        return;
      }
      _liveFlags = union;
      _liveAt = now;
      setState(() {
        _selected = 0;
        _saveError = false;
      });
      _requestSend();
      return;
    }

    final report = _report(flags: flags, fix: _usableFix(now));
    final OutboxEntry entry;
    try {
      entry = widget.outbox.enqueueSos(report, now: now);
    } on Object {
      _saveFailed(); // no se fija _liveAt: el siguiente toque es un reintento real
      return;
    }
    _liveKey = entry.reportKey;
    _liveFlags = flags;
    _liveAt = now;
    setState(() {
      _selected = 0;
      _saveError = false;
    });
    _requestSend();
    if (!report.locQuality.hasCoordinates && widget.location != null) {
      unawaited(_refineLocation(entry.reportKey));
    }
  }

  Future<void> _refineLocation(String reportKey) async {
    LocationFix? fix;
    try {
      fix = await widget.location!.fresh(timeout: const Duration(seconds: 8));
    } on Object {
      fix = null;
    }
    if (fix == null ||
        !locQualityFromAccuracy(fix.accuracyMeters).hasCoordinates) {
      return;
    }
    _cachedFix = fix;
    try {
      // Las banderas vigentes (si entretanto se añadieron otras, la revisión las lleva).
      final flags = reportKey == _liveKey ? _liveFlags : 0;
      widget.outbox.enqueueRevision(
        reportKey,
        _report(flags: flags, fix: fix),
        now: (widget.clock ?? DateTime.now)(),
      );
    } on Object {
      return; // la bandeja pudo cerrarse mientras tanto
    }
    if (mounted) setState(() {});
    _requestSend();
  }

  void _requestSend() {
    final send =
        widget.onNewReport ??
        (widget.scheduler == null ? null : () => widget.scheduler!.pump());
    if (send != null) unawaited(send());
  }

  /// ¿El último aviso merece ir grande debajo del botón? Sí si aún no salió, si es reciente,
  /// o siempre en «sólo SOS» (no hay lista).
  bool _isHero(Incident inc, DateTime now) {
    if (_mode == PowerMode.sosOnly) return true;
    final unsent =
        inc.sos.state != OutboxState.sent &&
        inc.sos.state != OutboxState.confirmed;
    if (unsent) return true;
    final d = now.difference(inc.at);
    return d.isNegative || d < detailWindow;
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.clock ?? DateTime.now)();
    final incidents = groupIncidents(
      widget.outbox.all(),
      widget.outbox.reportOf,
    );
    final hero = incidents.isNotEmpty && _isHero(incidents.first, now)
        ? incidents.first
        : null;
    final history = [
      for (final inc in incidents)
        if (inc != hero) inc,
    ];
    final showHistory = _mode != PowerMode.sosOnly && history.isNotEmpty;
    return MaterialApp(
      title: 'SARD',
      debugShowCheckedModeBanner: false,
      theme: sardTheme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('SARD')),
        body: SafeArea(
          child: Column(
            children: [
              if (_saveError)
                const _Banner(
                  key: Key('save_error'),
                  color: Color(0xFFB03024),
                  icon: Icons.error_outline,
                  text: 'No se pudo guardar el reporte. Vuelve a tocar SOS.',
                ),
              if (widget.online != null)
                ValueListenableBuilder<bool>(
                  valueListenable: widget.online!,
                  builder: (context, isOnline, _) => isOnline
                      ? const SizedBox.shrink()
                      : const _Banner(
                          key: Key('offline_banner'),
                          color: Color(0xFF6B4E00),
                          icon:
                              Icons.signal_cellular_connected_no_internet_0_bar,
                          text:
                              'Sin señal. Tu SOS se guarda y saldrá solo cuando vuelva.',
                        ),
                ),
              if (_mode != PowerMode.normal)
                _Banner(
                  key: const Key('power_banner'),
                  color: const Color(0xFF6B4E00),
                  icon: Icons.battery_alert,
                  text: _mode == PowerMode.saver
                      ? 'Modo ahorro de batería'
                      : 'Sólo SOS: batería muy baja',
                ),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: SosPanel(
                        selected: _selected,
                        sent: _isDetailLive(now) ? _liveFlags : 0,
                        onToggle: _toggle,
                        onSos: _sos,
                        showFlags: _mode != PowerMode.sosOnly,
                        status: hero == null
                            ? null
                            : IncidentCard(
                                incident: hero,
                                now: now,
                                hero: true,
                                statusKey: const Key('last_status'),
                              ),
                      ),
                    ),
                    if (showHistory) ...[
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
                          child: Text(
                            'Tus avisos',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      SliverList.builder(
                        itemCount: history.length,
                        itemBuilder: (context, i) =>
                            IncidentCard(incident: history[i], now: now),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Franja de aviso a todo el ancho: icono + frase. Nunca depende sólo del color.
class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
