import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'reports_screen.dart';
import 'sos_screen.dart';
import 'state_labels.dart';

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

  void _toggle(int bit) => setState(() => _selected ^= bit);

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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SARD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('SARD')),
        body: SafeArea(
          child: Column(
            children: [
              if (_saveError)
                Container(
                  key: const Key('save_error'),
                  width: double.infinity,
                  color: const Color(0xFFC0392B),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 12,
                  ),
                  child: const Text(
                    'No se pudo guardar el reporte. Vuelve a tocar SOS.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (_mode != PowerMode.normal)
                Container(
                  key: const Key('power_banner'),
                  width: double.infinity,
                  color: const Color(0xFF8A6508),
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 12,
                  ),
                  child: Text(
                    _mode == PowerMode.saver
                        ? 'Modo ahorro de batería'
                        : 'Sólo SOS: batería muy baja',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              SosPanel(
                selected: _selected,
                onToggle: _toggle,
                onSos: _sos,
                showFlags: _mode != PowerMode.sosOnly,
              ),
              if (_mode != PowerMode.sosOnly) ...[
                const Divider(),
                Expanded(
                  child: ReportsList(
                    entries: widget.outbox.all().reversed.toList(),
                  ),
                ),
              ] else if (widget.outbox.all().isNotEmpty)
                // Sin lista (batería muy baja) la pantalla igualmente confirma el estado del último reporte.
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    stateLabel(widget.outbox.all().last),
                    key: const Key('last_status'),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
