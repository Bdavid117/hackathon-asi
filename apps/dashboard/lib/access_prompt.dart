import 'package:flutter/material.dart';

import 'theme.dart';

/// Pantalla de acceso del tablero cuando el nodo exige código (`--coordinator-token`). No muestra ningún dato.
///
/// El código es compartido: abre la puerta, no dice QUIÉN es la persona (al aprobar se sigue pidiendo su nombre).
/// Se guarda sólo en memoria: al cerrar o recargar la pestaña hay que volver a escribirlo.
class AccessPrompt extends StatefulWidget {
  const AccessPrompt({super.key, required this.onSubmit, this.message});

  final void Function(String code) onSubmit;

  /// Por qué se vuelve a pedir (código equivocado, o el nodo cambió de código); `null` la primera vez.
  final String? message;

  @override
  State<AccessPrompt> createState() => _AccessPromptState();
}

class _AccessPromptState extends State<AccessPrompt> {
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    widget.onSubmit(code);
  }

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          key: const Key('access_prompt'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_outline, size: 40, color: DashColors.muted),
            const SizedBox(height: 16),
            const Text('Tablero protegido', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Escribe el código de acceso del coordinador para ver los incidentes.', textAlign: TextAlign.center, style: TextStyle(color: DashColors.muted, fontSize: 15, height: 1.35)),
            const SizedBox(height: 20),
            TextField(
              key: const Key('access_code'),
              controller: _code,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Código de acceso', border: OutlineInputBorder()),
            ),
            if (widget.message != null) ...[
              const SizedBox(height: 10),
              Text(widget.message!, key: const Key('access_error'), style: const TextStyle(color: DashColors.warn, fontSize: 14, height: 1.3)),
            ],
            const SizedBox(height: 16),
            FilledButton(key: const Key('access_enter'), onPressed: _submit, child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Entrar'))),
            const SizedBox(height: 16),
            const Text('El código sólo se recuerda mientras esta pestaña esté abierta. No dice quién eres: al decidir se sigue pidiendo tu nombre.', textAlign: TextAlign.center, style: TextStyle(color: DashColors.muted, fontSize: 12, height: 1.35)),
          ],
        ),
      ),
    ),
  );
}
