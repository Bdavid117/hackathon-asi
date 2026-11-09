import 'dart:async';

import 'package:flutter/material.dart';

/// Lo que sirvió el nodo: los reportes y si es una vista vieja (con su antigüedad).
class QueueSnapshot {
  const QueueSnapshot(this.items, {this.stale = false, this.ageMs = 0});
  final List<Map<String, Object?>> items;

  /// El log del nodo cambió después de calcular esto y el nodo sirvió igualmente la versión anterior.
  final bool stale;
  final int ageMs;
}

/// Lista priorizada del coordinador. Consulta al nodo cada [every] y conserva la última
/// vista si el nodo deja de responder (avisa en vez de borrar).
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.fetch, this.every = const Duration(seconds: 2)});

  final Future<QueueSnapshot> Function() fetch;

  /// Periodo de consulta; `null` la desactiva (pruebas).
  final Duration? every;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  List<Map<String, Object?>> _items = const [];
  bool _offline = false;
  bool _stale = false;
  int _ageMs = 0;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    final every = widget.every;
    if (every != null) _timer = Timer.periodic(every, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final snap = await widget.fetch();
      if (mounted) {
        setState(() {
          _items = snap.items;
          _stale = snap.stale;
          _ageMs = snap.ageMs;
          _offline = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _offline = true);
    } finally {
      _loading = false;
    }
  }

  static Color _color(String urgency) => switch (urgency) {
        'P1' => const Color(0xFFC0392B),
        'P2' => const Color(0xFFE0B040),
        'P3' => const Color(0xFF22C5D3),
        _ => const Color(0xFF6B7690),
      };

  @override
  Widget build(BuildContext context) {
    final n = _items.length;
    return Scaffold(
      appBar: AppBar(title: const Text('SARD · Tablero del coordinador')),
      body: Column(
        children: [
          if (_offline)
            Container(
              width: double.infinity,
              color: const Color(0xFFFBF3DC),
              padding: const EdgeInsets.all(8),
              child: const Text('Sin conexión con el nodo: se muestra la última vista.', style: TextStyle(color: Colors.black87)),
            ),
          if (_stale)
            Container(
              key: const Key('stale_banner'),
              width: double.infinity,
              color: const Color(0xFFFBF3DC),
              padding: const EdgeInsets.all(8),
              child: Text(
                'Vista de hace ${(_ageMs / 1000).round()} s: el nodo está recalculando y puede faltar algún reporte reciente.',
                style: const TextStyle(color: Colors.black87),
              ),
            ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('Sin reportes todavía'))
                : ListView.builder(
                    itemCount: n,
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      final urgency = it['urgency']! as String;
                      final signals = (it['signals'] as List?)?.cast<String>() ?? const <String>[];
                      final text = it['text'] as String?;
                      return ListTile(
                        key: Key('item_${it['reportKey']}'),
                        leading: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: _color(urgency), borderRadius: BorderRadius.circular(6)),
                          child: Text(urgency, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                        ),
                        title: Text(text ?? (signals.isEmpty ? 'Sin detalle' : signals.join(' · '))),
                        subtitle: Text([
                          if (text != null && signals.isNotEmpty) signals.join(' · '),
                          if (it['lat'] == null) 'sin ubicación' else 'con ubicación',
                        ].join(' · ')),
                      );
                    },
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.black12,
            child: Text(n == 1 ? '1 reporte' : '$n reportes'),
          ),
        ],
      ),
    );
  }
}
