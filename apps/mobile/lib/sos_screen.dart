import 'package:flutter/material.dart';
import 'package:sard_protocol/sard_protocol.dart';

/// Banderas de situación que se pueden marcar antes del SOS: (clave, texto, bit).
const List<(String, String, int)> kFlagChips = [
  ('flag_atrapado', 'Atrapado', SituationFlags.atrapado),
  ('flag_herido', 'Herido', SituationFlags.herido),
  ('flag_incendio', 'Incendio', SituationFlags.incendio),
  ('flag_via_bloqueada', 'Vía bloqueada', SituationFlags.viaBloqueada),
  ('flag_sin_aire', 'Sin aire', SituationFlags.dificultadRespiratoria),
  ('flag_menores_mayores', 'Menores / mayores', SituationFlags.menoresMayores),
];

/// Botón SOS grande y seis indicadores de situación. Sin imágenes ni animaciones.
class SosPanel extends StatelessWidget {
  const SosPanel({super.key, required this.selected, required this.onToggle, required this.onSos});

  /// Máscara de bits de las banderas marcadas.
  final int selected;
  final void Function(int bit) onToggle;
  final VoidCallback onSos;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        SizedBox(
          width: 150,
          height: 150,
          child: ElevatedButton(
            key: const Key('sos_button'),
            onPressed: onSos,
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              backgroundColor: const Color(0xFFC0392B),
              foregroundColor: Colors.white,
            ),
            child: const Text('SOS', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 6),
        const Text('Un toque: guarda y pone en cola', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            for (final (key, label, bit) in kFlagChips)
              FilterChip(
                key: Key(key),
                label: Text(label),
                selected: selected & bit != 0,
                onSelected: (_) => onToggle(bit),
              ),
          ],
        ),
      ],
    );
  }
}
