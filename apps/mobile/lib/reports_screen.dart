import 'package:flutter/material.dart';
import 'package:sard_client_core/sard_client_core.dart';

import 'state_labels.dart';

/// Lista de lo enviado, con el estado de entrega en lenguaje llano. Nada se borra.
class ReportsList extends StatelessWidget {
  const ReportsList({super.key, required this.entries});

  final List<OutboxEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('Aún no has enviado ningún reporte.'));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        return ListTile(
          key: Key('report_${e.frameSeq}'),
          title: Text(
            e.rev == 0 ? 'SOS #${e.frameSeq}' : 'Detalle #${e.frameSeq}',
          ),
          subtitle: Text(stateLabel(e)),
        );
      },
    );
  }
}
