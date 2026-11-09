import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sard_protocol/sard_protocol.dart';

import 'byte_limit_formatter.dart';
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
const String kPeopleTitle = '¿Cuántas personas?';
const String kPhraseTitle = 'Una frase (opcional)';

/// Alto fijo de los rangos de personas y del cuadro de la frase: igual marcados o no, con o sin texto,
/// para que nada se mueva bajo el dedo.
const double kPeopleTileHeight = 60;
const double kPhraseFieldHeight = 76;
const double kPhraseRowHeight = 52;
const double kPhraseConfirmHeight = 24;

/// Los rangos que se pueden tocar: todos menos «No indicado», que es lo que lleva un SOS sin detalle.
final List<PeopleBucket> kPeopleChoices = [
  for (final b in PeopleBucket.values)
    if (b != PeopleBucket.unknown) b,
];

/// «1 persona», «2–5 personas»… o nada si no se indicó.
String? peopleSummary(PeopleBucket b) => switch (b) {
  PeopleBucket.unknown => null,
  PeopleBucket.one => '1 persona',
  _ => '${b.label} personas',
};

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
    this.people = 0,
    this.peopleSent = 0,
    this.onPeople,
    this.phrase,
    this.phraseLive = false,
    this.phraseConfirmation,
    this.onSendPhrase,
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

  /// Rango de personas marcado para el próximo SOS (código de `PeopleBucket`; 0 = ninguno) y el que ya
  /// salió con el aviso vivo.
  final int people;
  final int peopleSent;
  final void Function(int code)? onPeople;

  /// Cuadro de «Una frase»: su controlador, si hay un aviso vivo al que enviarla, la confirmación de la
  /// última enviada y qué hacer al enviar. Sin controlador no se ofrece.
  final TextEditingController? phrase;
  final bool phraseLive;
  final String? phraseConfirmation;
  final VoidCallback? onSendPhrase;

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
          if (onPeople != null) ...[
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  kPeopleTitle,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (var i = 0; i < kPeopleChoices.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _PeopleTile(
                        bucket: kPeopleChoices[i],
                        selected: people,
                        sent: peopleSent,
                        onPick: onPeople!,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (phrase != null) ...[
            const SizedBox(height: 18),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  kPhraseTitle,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _PhraseBox(
              controller: phrase!,
              live: phraseLive,
              confirmation: phraseLive ? phraseConfirmation : null,
              onSend: onSendPhrase,
            ),
          ],
        ],
      ],
    );
  }
}

/// Un rango de personas, de tamaño fijo. Mismos tres estados que los indicadores (sin marcar, marcado
/// para el próximo SOS, ya enviado) y también por icono, no sólo por color.
class _PeopleTile extends StatelessWidget {
  const _PeopleTile({
    required this.bucket,
    required this.selected,
    required this.sent,
    required this.onPick,
  });

  final PeopleBucket bucket;
  final int selected;
  final int sent;
  final void Function(int code) onPick;

  @override
  Widget build(BuildContext context) {
    final isSent = sent == bucket.code;
    final isOn = isSent || selected == bucket.code;
    final accent = isSent ? SardColors.ok : SardColors.text;
    final label = bucket.label;
    return SizedBox(
      key: Key('people_${bucket.code}'),
      height: kPeopleTileHeight,
      width: double.infinity,
      child: Semantics(
        button: true,
        checked: isOn,
        label: isSent ? '$label personas, ya enviado' : '$label personas',
        excludeSemantics: true,
        onTap: () => onPick(bucket.code),
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
            onTap: () => onPick(bucket.code),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isOn ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18,
                    color: isSent
                        ? SardColors.ok
                        : (isOn ? SardColors.text : SardColors.muted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      color: accent,
                    ),
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

/// El cuadro de «Una frase»: campo de dos líneas fijas, contador de bytes (o la razón por la que aún
/// no se puede enviar) y botón. Todo de alto fijo: escribir no mueve nada.
class _PhraseBox extends StatelessWidget {
  const _PhraseBox({
    required this.controller,
    required this.live,
    required this.confirmation,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool live;
  final String? confirmation;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: kPhraseFieldHeight,
            child: TextField(
              key: const Key('phrase_field'),
              controller: controller,
              minLines: 2,
              maxLines: 2,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                const Utf8ByteLimitFormatter(kMaxTextBytes),
              ],
              style: const TextStyle(fontSize: 16, height: 1.25),
              decoration: InputDecoration(
                hintText: 'Por ejemplo: mi mamá no puede salir del segundo piso',
                hintStyle: const TextStyle(color: SardColors.muted),
                filled: true,
                fillColor: SardColors.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: SardColors.border, width: 2),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: SardColors.text, width: 2),
                ),
              ),
            ),
          ),
          SizedBox(
            height: kPhraseRowHeight,
            child: Row(
              children: [
                Expanded(
                  key: const Key('phrase_counter'),
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => Text(
                      live
                          ? '${utf8Length(controller.text)}/$kMaxTextBytes'
                          : 'Se activa después de tocar SOS.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: SardColors.muted),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 168,
                  height: 48,
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => ElevatedButton(
                      key: const Key('send_phrase'),
                      onPressed: live && controller.text.trim().isNotEmpty ? onSend : null,
                      child: const Text(
                        'Enviar frase',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            key: const Key('phrase_sent'),
            height: kPhraseConfirmHeight,
            width: double.infinity,
            child: Text(
              confirmation == null ? '' : 'Frase enviada: «$confirmation»',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: SardColors.ok),
            ),
          ),
        ],
      ),
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
