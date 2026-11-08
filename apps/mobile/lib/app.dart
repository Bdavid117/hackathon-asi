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
  });

  final Outbox outbox;

  /// Si se da, se intenta enviar de inmediato al crear un reporte.
  final SendScheduler? scheduler;

  /// Cada cuánto se relee la bandeja para reflejar los ACK; `null` lo desactiva.
  final Duration? refreshEvery;
  final DateTime Function()? clock;

  @override
  State<SardApp> createState() => _SardAppState();
}

class _SardAppState extends State<SardApp> {
  int _selected = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final every = widget.refreshEvery;
    if (every != null) _timer = Timer.periodic(every, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle(int bit) => setState(() => _selected ^= bit);

  void _sos() {
    final now = (widget.clock ?? DateTime.now)();
    widget.outbox.enqueueSos(
      // B1: sin GPS ni lectura real de batería (llegan en B2); incidentType 1 = SOS genérico.
      NewReport(
        incidentType: 1,
        flags: _selected,
        peopleBucket: 0,
        batteryQ: 15,
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
              SosPanel(selected: _selected, onToggle: _toggle, onSos: _sos),
              const Divider(),
              Expanded(child: ReportsList(entries: widget.outbox.all().reversed.toList())),
            ],
          ),
        ),
      ),
    );
  }
}
