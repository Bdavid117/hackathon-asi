import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';
import 'theme.dart';

/// Por dónde le llegó el informe al despachador (los códigos que el nodo acepta en `medium`).
const List<(String, String)> _media = [('radio', 'Radio'), ('telefono', 'Teléfono'), ('presencial', 'En persona')];

/// Las banderas que se pueden marcar: los mismos códigos que el triaje cita como evidencia.
const List<String> _flagCodes = ['atrapado', 'herido', 'incendio', 'dificultad_respiratoria', 'via_bloqueada', 'estructura_inestable', 'menores_mayores', 'medicacion'];

/// Los cinco rangos de personas (el código es el de `PeopleBucket`; 0 = no indicado).
const List<(int, String)> _people = [(1, '1'), (2, '2–5'), (3, '6–20'), (4, '21–100'), (5, 'Más de 100')];

const int _maxText = 500;
const int _maxWho = 80;

/// Un identificador nuevo para un informe (lo genera el tablero: el nodo lo usa para no duplicar un reintento).
String _newId() {
  final r = Random.secure();
  return 'inf-${[for (var i = 0; i < 12; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
}

/// «Registrar informe»: lo que un despachador oyó por radio, por teléfono o en persona.
///
/// Es información de **segunda mano**: queda registrada sin ubicación (el sistema no la inventa), pasa por el mismo
/// triaje que los avisos de la app y no despacha nada. Cierra con `true` cuando el nodo la aceptó; si el nodo no
/// responde o la rechaza, el cuadro sigue abierto y el informe **no** se da por registrado. Reintentar con lo mismo
/// reusa el identificador (el nodo no duplica); si se cambia algo, el identificador es otro.
class DispatchDialog extends StatefulWidget {
  const DispatchDialog({super.key, required this.api, required this.who, this.identity});

  final DashboardApi api;

  /// El nombre de quien registra, compartido con las aprobaciones: se recuerda aunque el informe no llegue.
  final ValueNotifier<String> who;

  /// Si el código de acceso identifica a la persona, su nombre: se fija y no se puede cambiar (el nodo rechazaría otro).
  final String? identity;

  @override
  State<DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends State<DispatchDialog> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _origin = TextEditingController();
  final TextEditingController _lat = TextEditingController();
  final TextEditingController _lon = TextEditingController();
  late final TextEditingController _who = TextEditingController(text: widget.identity ?? widget.who.value);
  String _medium = 'radio';
  final Set<String> _flags = {};
  int _peopleCode = 0;
  bool _sending = false;
  bool _textMissing = false;
  bool _whoMissing = false;
  String? _locError;
  String? _error;

  /// El identificador del intento en curso y la «firma» del contenido con que se generó.
  String? _id;
  String? _signature;

  @override
  void dispose() {
    _text.dispose();
    _origin.dispose();
    _lat.dispose();
    _lon.dispose();
    _who.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _text.text.trim();
    final who = _who.text.trim();
    final origin = _origin.text.trim();
    final textMissing = text.isEmpty;
    final whoMissing = who.isEmpty || who.length > _maxWho;
    // Ubicación opcional: las dos o ninguna, numérica y en rango (se acepta la coma decimal de quien escribe en español).
    final latText = _lat.text.trim(), lonText = _lon.text.trim();
    double? lat, lon;
    String? locError;
    if (latText.isNotEmpty || lonText.isNotEmpty) {
      if (latText.isEmpty || lonText.isEmpty) {
        locError = 'Escribe las dos (latitud y longitud) o ninguna: una ubicación a medias no se completa.';
      } else {
        lat = double.tryParse(latText.replaceAll(',', '.'));
        lon = double.tryParse(lonText.replaceAll(',', '.'));
        if (lat == null || lon == null || !lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
          locError = 'La latitud va de -90 a 90 y la longitud de -180 a 180 (p. ej. 5.0689 y -75.5174).';
          lat = lon = null;
        }
      }
    }
    if (textMissing || whoMissing || locError != null) {
      setState(() {
        _textMissing = textMissing;
        _whoMissing = whoMissing;
        _locError = locError;
      });
      return;
    }
    widget.who.value = who; // se recuerda aunque el informe no llegue a registrarse
    final flags = _flags.toList()..sort();
    // Mismo contenido = mismo id (un reintento no duplica); contenido distinto = id nuevo (no choca con un 409).
    final signature = jsonEncode([text, _medium, origin, who, flags, _peopleCode, lat, lon]);
    if (_id == null || _signature != signature) {
      _id = _newId();
      _signature = signature;
    }
    setState(() {
      _sending = true;
      _textMissing = false;
      _whoMissing = false;
      _locError = null;
      _error = null;
    });
    try {
      await widget.api.dispatch(id: _id!, text: text, medium: _medium, who: who, origin: origin.isEmpty ? null : origin, flags: flags, people: _peopleCode, lat: lat, lon: lon);
      if (mounted) Navigator.of(context).pop<bool>(true);
    } on ApiException catch (e) {
      if (e.status == 409) _id = null; // el id ya se usó con otro contenido: el próximo intento lleva uno nuevo
      if (mounted) setState(() => _error = 'El nodo no aceptó el informe (${e.status}): ${e.message}. NO quedó registrado.');
    } on AccessDenied {
      if (mounted) setState(() => _error = 'El nodo no acepta el código de acceso. El informe NO quedó registrado: cierra este cuadro y escribe el código de nuevo.');
    } on Object catch (e) {
      final network = e is TimeoutException || e is SocketException || e.toString().contains('ClientException');
      if (mounted) {
        setState(() => _error = network
            ? 'No se pudo contactar al nodo. El informe NO quedó registrado: inténtalo de nuevo (se reintenta con el mismo identificador, no se duplica).'
            : 'No se pudo registrar el informe ($e). NO quedó registrado.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Los chips seleccionados en el verde del tablero (el de Material es turquesa y no es de esta paleta).
  static final ChipThemeData _chips = ChipThemeData(
    selectedColor: DashColors.ok.withValues(alpha: 0.28),
    checkmarkColor: DashColors.ok,
    side: const BorderSide(color: DashColors.border),
    labelStyle: const TextStyle(color: DashColors.text),
  );

  @override
  Widget build(BuildContext context) {
    return Theme(data: Theme.of(context).copyWith(chipTheme: _chips), child: _dialog());
  }

  Widget _dialog() {
    return AlertDialog(
      key: const Key('dispatch_dialog'),
      title: const Text('Registrar informe'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Información de segunda mano: queda registrada sin ubicación y pasa por el mismo triaje que los avisos de la app. No despacha nada. La hora que queda es la de registro, no la de cuando se oyó.',
                style: TextStyle(fontSize: 13, height: 1.3, color: DashColors.muted),
              ),
              const SizedBox(height: 14),
              const Text('Por dónde llegó', style: TextStyle(fontSize: 13, color: DashColors.muted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (code, label) in _media)
                    ChoiceChip(key: Key('medium_$code'), label: Text(label), selected: _medium == code, onSelected: _sending ? null : (_) => setState(() => _medium = code)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('dispatch_text'),
                controller: _text,
                enabled: !_sending,
                maxLength: _maxText,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(labelText: 'Qué se oyó', errorText: _textMissing ? 'Escribe lo que se oyó para poder registrarlo.' : null),
              ),
              if (_textMissing) const SizedBox(key: Key('dispatch_text_error'), height: 0),
              const SizedBox(height: 6),
              TextField(
                key: const Key('dispatch_origin'),
                controller: _origin,
                enabled: !_sending,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '¿De quién viene? (opcional)', hintText: 'Estación, radioaficionado, vecino…'),
              ),
              const SizedBox(height: 12),
              // La ubicación es opcional y escrita a mano: con ella el agente 6 ya puede recomendar, pero sigue pidiendo
              // una segunda fuente y aprobación humana. Sin ella, el informe se registra igual y dice que falta el dónde.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: TextField(key: const Key('dispatch_lat'), controller: _lat, enabled: !_sending, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitud (opcional)', hintText: '5.0689'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(key: const Key('dispatch_lon'), controller: _lon, enabled: !_sending, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitud (opcional)', hintText: '-75.5174'))),
                ],
              ),
              const Padding(padding: EdgeInsets.only(top: 4), child: Text('Si la sabes. Se registra como ubicación escrita a mano (±3 km de incertidumbre): no es un GPS.', style: TextStyle(fontSize: 12, color: DashColors.muted))),
              if (_locError != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_locError!, key: const Key('dispatch_loc_error'), style: const TextStyle(color: DashColors.danger, fontSize: 13))),
              const SizedBox(height: 6),
              const Text('Qué indica (opcional)', style: TextStyle(fontSize: 13, color: DashColors.muted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final code in _flagCodes)
                    FilterChip(
                      key: Key('flag_$code'),
                      label: Text(signalLabel(code)),
                      selected: _flags.contains(code),
                      onSelected: _sending ? null : (on) => setState(() => on ? _flags.add(code) : _flags.remove(code)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('¿Cuántas personas? (opcional)', style: TextStyle(fontSize: 13, color: DashColors.muted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (code, label) in _people)
                    ChoiceChip(key: Key('people_$code'), label: Text(label), selected: _peopleCode == code, onSelected: _sending ? null : (on) => setState(() => _peopleCode = on ? code : 0)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('dispatch_who'),
                controller: _who,
                enabled: !_sending,
                readOnly: widget.identity != null,
                maxLength: _maxWho,
                decoration: InputDecoration(
                  labelText: 'Tu nombre',
                  helper: widget.identity == null ? null : const Text('Identificado por tu código de acceso', key: Key('dispatch_who_identified')),
                  errorText: _whoMissing ? 'Escribe tu nombre para registrar el informe.' : null,
                ),
              ),
              if (_whoMissing) const SizedBox(key: Key('dispatch_who_error'), height: 0),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, key: const Key('dispatch_error'), style: const TextStyle(color: DashColors.danger, fontSize: 14, height: 1.3)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(key: const Key('cancel_dispatch'), onPressed: _sending ? null : () => Navigator.of(context).pop<bool>(false), child: const Text('Cancelar')),
        FilledButton(
          key: const Key('send_dispatch'),
          onPressed: _sending ? null : _send,
          style: FilledButton.styleFrom(backgroundColor: DashColors.ok, foregroundColor: DashColors.bg),
          child: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Registrar informe'),
        ),
      ],
    );
  }
}
