import 'package:sard_client_core/sard_client_core.dart';

/// Texto que ve el ciudadano para una trama de la bandeja (PDF §5.4).
String stateLabel(OutboxEntry e) => switch (e.state) {
  OutboxState.queued =>
    e.attempts == 0 ? 'Guardado en tu teléfono' : 'Esperando señal',
  OutboxState.sending => 'Enviando…',
  OutboxState.sent => 'Enviado a un nodo',
  OutboxState.confirmed => 'Recibido por SARD',
  OutboxState.expired => 'Se enviará cuando haya señal',
};
