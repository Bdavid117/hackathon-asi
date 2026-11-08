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
  const SosPanel({
    super.key,
    required this.selected,
    required this.onToggle,
    required this.onSos,
    this.showFlags = true,
  });

  /// Máscara de bits de las banderas marcadas.
  final int selected;
  final void Function(int bit) onToggle;
  final VoidCallback onSos;

  /// En modo «sólo SOS» (batería muy baja) los indicadores se ocultan.
  final bool showFlags;

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
            child: const Text(
              'SOS',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Un toque: guarda y pone en cola',
          style: TextStyle(fontSize: 12),
        ),
        if (showFlags) ...[
          const SizedBox(height: 8),
          // Cuadrícula fija de dos columnas: cada indicador mide siempre lo mismo, marcado o no, para
          // que NADA se mueva bajo el dedo (en una emergencia el pulso tiembla y los objetivos
          // que se reacomodan hacen marcar el que no era).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < kFlagChips.length; i += 2)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        for (
                          var k = i;
                          k < i + 2 && k < kFlagChips.length;
                          k++
                        ) ...[
                          if (k > i) const SizedBox(width: 8),
                          Expanded(
                            child: _FlagChip(
                              chip: kFlagChips[k],
                              selected: selected,
                              onToggle: onToggle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Un indicador de situación de tamaño fijo. El icono de casilla está siempre presente (no sólo
/// al marcar), de modo que el estado se distingue sin depender del color y el chip no cambia de ancho.
class _FlagChip extends StatelessWidget {
  const _FlagChip({
    required this.chip,
    required this.selected,
    required this.onToggle,
  });

  final (String, String, int) chip;
  final int selected;
  final void Function(int bit) onToggle;

  @override
  Widget build(BuildContext context) {
    final (key, label, bit) = chip;
    final on = selected & bit != 0;
    return SizedBox(
      height: 52,
      width: double.infinity,
      child: FilterChip(
        key: Key(key),
        showCheckmark: false,
        avatar: Icon(
          on ? Icons.check_box : Icons.check_box_outline_blank,
          size: 20,
        ),
        label: SizedBox(
          width: double.infinity,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        selected: on,
        onSelected: (_) => onToggle(bit),
      ),
    );
  }
}
