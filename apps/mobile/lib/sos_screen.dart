import 'package:flutter/material.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'theme.dart';

/// Banderas de situación que se pueden marcar: (clave, texto, bit).
const List<(String, String, int)> kFlagChips = [
  ('flag_atrapado', 'Atrapado', SituationFlags.atrapado),
  ('flag_herido', 'Herido', SituationFlags.herido),
  ('flag_incendio', 'Incendio', SituationFlags.incendio),
  ('flag_via_bloqueada', 'Vía bloqueada', SituationFlags.viaBloqueada),
  ('flag_sin_aire', 'Sin aire', SituationFlags.dificultadRespiratoria),
  ('flag_menores_mayores', 'Menores / mayores', SituationFlags.menoresMayores),
];

/// Un icono por situación: se reconoce de un vistazo sin leer, útil con miedo o prisa.
const Map<String, IconData> kFlagIcons = {
  'flag_atrapado': Icons.lock_person_outlined,
  'flag_herido': Icons.healing,
  'flag_incendio': Icons.local_fire_department_outlined,
  'flag_via_bloqueada': Icons.block,
  'flag_sin_aire': Icons.air,
  'flag_menores_mayores': Icons.family_restroom,
};

/// Alto de la zona de estado bajo el botón. Es el MISMO con la ayuda inicial, con «Guardado» y con
/// «Enviado», para que los indicadores de abajo no se muevan nunca cuando cambia el estado.
const double kStatusSlotHeight = 168;

const String kSosHint =
    'Toca una vez. Se guarda y sale solo, aunque no tengas señal.';
const String kDetailsTitle = 'Cuéntanos qué pasa (opcional)';

/// Botón SOS grande y seis indicadores de situación. Sin imágenes ni animaciones: cuestan batería.
class SosPanel extends StatelessWidget {
  const SosPanel({
    super.key,
    required this.selected,
    required this.onToggle,
    required this.onSos,
    this.sent = 0,
    this.showFlags = true,
    this.status,
  });

  /// Indicadores marcados que saldrán con el próximo SOS.
  final int selected;

  /// Indicadores que ya salieron con el aviso vivo: se ven marcados en verde y no se pueden quitar.
  final int sent;
  final void Function(int bit) onToggle;
  final VoidCallback onSos;

  /// En modo «sólo SOS» (batería muy baja) los indicadores se ocultan.
  final bool showFlags;

  /// Qué pasa con el último aviso, justo debajo del botón que se acaba de tocar. Si no hay,
  /// se muestra la ayuda de siempre.
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        SizedBox(
          width: 190,
          height: 190,
          child: ElevatedButton(
            key: const Key('sos_button'),
            onPressed: onSos,
            style: ElevatedButton.styleFrom(
              shape: const CircleBorder(),
              backgroundColor: SardColors.sos,
              foregroundColor: Colors.white,
              elevation: 0,
              side: const BorderSide(color: Color(0x55FFFFFF), width: 4),
            ),
            child: const Text(
              'SOS',
              semanticsLabel: 'Enviar SOS',
              style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900),
            ),
          ),
        ),
        const SizedBox(height: 14),
        status ??
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kStatusSlotHeight),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    kSosHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: SardColors.muted,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
        if (showFlags) ...[
          const SizedBox(height: 22),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                kDetailsTitle,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Cuadrícula fija de dos columnas: cada indicador mide siempre lo mismo, marcado o no,
          // para que NADA se mueva bajo el dedo (en una emergencia el pulso tiembla y los objetivos
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
                            child: _FlagTile(
                              chip: kFlagChips[k],
                              selected: selected,
                              sent: sent,
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

/// Un indicador de tamaño fijo. Tres estados que se distinguen por icono y color, no sólo por color:
/// sin marcar, marcado para el próximo SOS, y ya enviado con el aviso vivo.
class _FlagTile extends StatelessWidget {
  const _FlagTile({
    required this.chip,
    required this.selected,
    required this.sent,
    required this.onToggle,
  });

  final (String, String, int) chip;
  final int selected;
  final int sent;
  final void Function(int bit) onToggle;

  @override
  Widget build(BuildContext context) {
    final (key, label, bit) = chip;
    final isSent = sent & bit != 0;
    final isOn = isSent || selected & bit != 0;
    final accent = isSent ? SardColors.ok : SardColors.text;
    return SizedBox(
      key: Key(key),
      height: 64,
      width: double.infinity,
      child: Semantics(
        button: true,
        checked: isOn,
        label: isSent ? '$label, ya enviado' : label,
        excludeSemantics: true,
        onTap: isSent ? null : () => onToggle(bit),
        child: Material(
          color: isSent
              ? const Color(0xFF173A2B)
              : isOn
              ? SardColors.surfaceHigh
              : SardColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: isSent
                  ? SardColors.ok
                  : isOn
                  ? SardColors.text
                  : SardColors.border,
              width: 2,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: isSent ? null : () => onToggle(bit),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(kFlagIcons[key], size: 26, color: accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    isOn ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 22,
                    color: isSent
                        ? SardColors.ok
                        : (isOn ? SardColors.text : SardColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
