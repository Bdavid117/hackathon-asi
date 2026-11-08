import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'reports_screen.dart';
import 'sos_screen.dart';

/// La app ciudadana: SOS en un toque y estado de entrega.
class SardApp extends StatefulWidget {
  const SardApp({
    super.key,
    required this.outbox,
    this.scheduler,
    this.refreshEvery = const Duration(seconds: 1),
    this.clock,
    this.battery,
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

  @override
  State<SardApp> createState() => _SardAppState();
}

class _SardAppState extends State<SardApp> {
  int _selected = 0;
  int? _percent;
  Timer? _timer;
  Timer? _batteryTimer;

  PowerMode get _mode => powerModeFor(_percent);

  @override
  void initState() {
    super.initState();
    _applyTimers();
    unawaited(_readBattery());
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

  void _sos() {
    final now = (widget.clock ?? DateTime.now)();
    widget.outbox.enqueueSos(
      // incidentType 1 = SOS genérico; la ubicación llega en la Tarea 23.
      NewReport(
        incidentType: 1,
        flags: _selected,
        peopleBucket: 0,
        batteryQ: batteryQFromPercent(_percent),
        locQuality: LocQuality.none,
      ),
      now: now,
    );
    setState(() => _selected = 0);
    final s = widget.scheduler;
    if (s != null) unawaited(s.pump());
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
              ],
            ],
          ),
        ),
      ),
    );
  }
}
