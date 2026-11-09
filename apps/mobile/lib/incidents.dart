import 'package:sard_client_core/sard_client_core.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'sos_screen.dart';

/// Lo que la persona entiende como «un aviso»: un SOS y todas sus revisiones (la ubicación que
/// llega después, indicadores añadidos). La bandeja guarda una fila por trama; aquí se pliegan.
class Incident {
  Incident({
    required this.reportKey,
    required this.sos,
    required this.latest,
    required this.frame,
    required this.updatePending,
  });

  final String reportKey;

  /// La trama del SOS (revisión 0): su estado es el estado del aviso.
  final OutboxEntry sos;

  /// La última revisión: lo más reciente que se ha dicho.
  final OutboxEntry latest;

  /// Contenido de la última revisión (indicadores, ubicación).
  final ReportFrame frame;

  /// Hay una actualización posterior (ubicación, detalle) que todavía no salió.
  final bool updatePending;

  DateTime get at => sos.createdAt;
  int get flags => frame.flags;
  bool get hasLocation => frame.locQuality.hasCoordinates;

  /// Indicadores en el orden en que se muestran en pantalla.
  List<String> get flagLabels => [
    for (final (_, label, bit) in kFlagChips)
      if (flags & bit != 0) label,
  ];
}

/// Pliega las tramas en avisos, el más reciente primero. [decode] lee lo que lleva una trama
/// (normalmente `Outbox.reportOf`).
List<Incident> groupIncidents(
  List<OutboxEntry> entries,
  ReportFrame Function(OutboxEntry) decode,
) {
  final byKey = <String, List<OutboxEntry>>{};
  for (final e in entries) {
    byKey.putIfAbsent(e.reportKey, () => []).add(e);
  }
  final out = <Incident>[];
  for (final group in byKey.values) {
    group.sort((a, b) => a.rev.compareTo(b.rev));
    final sos = group.first;
    final latest = group.last;
    out.add(
      Incident(
        reportKey: sos.reportKey,
        sos: sos,
        latest: latest,
        frame: decode(latest),
        updatePending: group
            .skip(1)
            .any(
              (e) =>
                  e.state != OutboxState.sent &&
                  e.state != OutboxState.confirmed,
            ),
      ),
    );
  }
  out.sort((a, b) => b.sos.frameSeq.compareTo(a.sos.frameSeq));
  return out;
}
