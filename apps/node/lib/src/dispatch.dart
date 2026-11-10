import 'package:sard_protocol/sard_protocol.dart';

import 'event_log.dart';

/// Tope del cuerpo de `POST /api/dispatch`. 500 caracteres escapados como `\uXXXX\uXXXX` (un emoji) son 6 000 bytes.
const int kMaxDispatchBytes = 8192;

/// Caracteres (no bytes) del texto de un informe.
const int kMaxDispatchText = 500;

/// Por dónde le llegó el informe al despachador. Sólo es una etiqueta para quien lee: los tres son información
/// **de segunda mano** y comparten la clase de fuente `radio` (credibilidad base supuesta de 0,2, sin calibrar).
enum DispatchMedium {
  radio('Radio'),
  telefono('Teléfono'),
  presencial('En persona');

  const DispatchMedium(this.label);
  final String label;
}

/// Las banderas por nombre: los mismos códigos que el triaje cita como evidencia (`flags.atrapado`…).
const Map<String, int> _flagByName = {
  'atrapado': SituationFlags.atrapado,
  'herido': SituationFlags.herido,
  'incendio': SituationFlags.incendio,
  'dificultad_respiratoria': SituationFlags.dificultadRespiratoria,
  'via_bloqueada': SituationFlags.viaBloqueada,
  'estructura_inestable': SituationFlags.estructuraInestable,
  'menores_mayores': SituationFlags.menoresMayores,
  'medicacion': SituationFlags.medicacion,
};

final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

/// Controles C0 y DEL, **salvo** salto de línea, retorno y tabulador (que en el texto se vuelven un espacio).
final RegExp _controlExceptWhitespace = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]');
final RegExp _anyControl = RegExp(r'[\u0000-\u001F\u007F]');
final RegExp _whitespaceControl = RegExp(r'[\n\r\t]');

/// Un informe de despachador ya validado.
class DispatchRequest {
  const DispatchRequest({
    required this.id,
    required this.text,
    required this.medium,
    required this.who,
    this.origin,
    this.flags = 0,
    this.people = 0,
    this.lat,
    this.lon,
  });

  /// Lo genera el cliente: un reintento con el mismo id no duplica el informe.
  final String id;
  final String text;
  final DispatchMedium medium;

  /// Quién REGISTRA el informe (declarado, no autenticado).
  final String who;

  /// De quién viene la información (estación, radioaficionado, vecino…), si se sabe. Decide la independencia de
  /// las fuentes: mismo origen = misma fuente.
  final String? origin;

  /// Bits de `SituationFlags`: lo que quien registra marca además del texto.
  final int flags;

  /// Código de `PeopleBucket` (0 = no indicado).
  final int people;

  /// Dónde está, si quien registra lo sabe. Van las dos o ninguna: una ubicación a medias no se completa. Se escribe con
  /// la calidad «manual» (la tecleó una persona; no es un GPS) y sin inventar nada más.
  final double? lat;
  final double? lon;
}

/// Validación **estricta** del cuerpo. Lanza [FormatException] diciendo qué campo está mal.
DispatchRequest parseDispatchRequest(Object? json) {
  if (json is! Map) throw const FormatException('el cuerpo debe ser un objeto JSON');
  const allowed = {'id', 'text', 'medium', 'origin', 'who', 'flags', 'people', 'lat', 'lon'};
  final extra = json.keys.where((k) => !allowed.contains(k)).toList();
  if (extra.isNotEmpty) throw FormatException('campos desconocidos: ${extra.join(', ')}');

  final id = json['id'];
  if (id is! String || !_id.hasMatch(id)) throw const FormatException('id debe ser texto de 8 a 64 caracteres (letras, cifras, guion y guion bajo)');

  final rawText = json['text'];
  if (rawText is! String) throw const FormatException('text debe ser texto');
  final text = rawText.replaceAll(_whitespaceControl, ' ').trim();
  if (text.isEmpty) throw const FormatException('text no puede estar vacío');
  if (text.runes.length > kMaxDispatchText) throw const FormatException('text admite hasta $kMaxDispatchText caracteres');
  if (_controlExceptWhitespace.hasMatch(text)) throw const FormatException('text no puede llevar caracteres de control');

  final mediumName = json['medium'];
  final medium = DispatchMedium.values.where((m) => m.name == mediumName).firstOrNull;
  if (medium == null) throw const FormatException('medium debe ser «radio», «telefono» o «presencial»');

  final who = json['who'];
  if (who is! String || who.trim().isEmpty || who.trim().runes.length > 80 || _anyControl.hasMatch(who.trim())) {
    throw const FormatException('who debe ser texto de 1 a 80 caracteres, sin saltos de línea');
  }

  String? origin;
  final rawOrigin = json['origin'];
  if (rawOrigin != null) {
    if (rawOrigin is! String || rawOrigin.trim().runes.length > 80 || _anyControl.hasMatch(rawOrigin.trim())) {
      throw const FormatException('origin debe ser texto de hasta 80 caracteres, sin saltos de línea');
    }
    origin = rawOrigin.trim().isEmpty ? null : rawOrigin.trim();
  }

  var flags = 0;
  final rawFlags = json['flags'] ?? const <Object?>[];
  if (rawFlags is! List) throw const FormatException('flags debe ser una lista de nombres');
  for (final f in rawFlags) {
    final bit = f is String ? _flagByName[f] : null;
    if (bit == null) throw FormatException('flags: «$f» no es una bandera conocida (${_flagByName.keys.join(', ')})');
    flags |= bit;
  }

  final people = json['people'] ?? 0;
  if (people is! int || people < 0 || people >= PeopleBucket.values.length) {
    throw FormatException('people debe ser un entero de 0 a ${PeopleBucket.values.length - 1}');
  }

  double? lat, lon;
  final hasLat = json.containsKey('lat'), hasLon = json.containsKey('lon');
  if (hasLat != hasLon) throw FormatException('lat y lon van juntas: falta ${hasLat ? 'lon' : 'lat'}');
  if (hasLat) {
    lat = _coordinate(json['lat'], 'lat', 90);
    lon = _coordinate(json['lon'], 'lon', 180);
  }

  return DispatchRequest(id: id, text: text, medium: medium, who: who.trim(), origin: origin, flags: flags, people: people, lat: lat, lon: lon);
}

double _coordinate(Object? v, String name, int limit) {
  if (v is! num || !v.isFinite || v < -limit || v > limit) throw FormatException('$name debe ser un número entre -$limit y $limit');
  return v.toDouble();
}

/// El mismo `id` ya se usó con OTRO contenido. No se descarta en silencio: el cliente debe generar un id nuevo.
class DispatchConflict implements Exception {
  const DispatchConflict(this.id);
  final String id;

  @override
  String toString() => 'el id «$id» ya se usó con otro contenido; genera un id nuevo para este informe';
}

class DispatchResult {
  const DispatchResult(this.event, {required this.duplicate});

  /// El `report.received` escrito (o el que ya existía, si es un reintento).
  final Event event;
  final bool duplicate;
}

/// Registra informes de despachador como `report.received`: pasan por los mismos agentes que los de la app, se
/// replican como cualquier evento y sólo llevan ubicación si quien los registra la dio (el agente 1 no la inventa).
class Dispatch {
  Dispatch(this._log, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final EventLog _log;
  final DateTime Function() _clock;

  static const String kChannel = 'dispatcher';

  DispatchResult register(DispatchRequest r) {
    final key = 'desp-${r.id}';
    final existing = _log.find('report.received', key, 0);
    if (existing != null) {
      if (_sameContent(existing.body, r)) return DispatchResult(existing, duplicate: true);
      throw DispatchConflict(r.id);
    }
    final nowMs = _clock().millisecondsSinceEpoch;
    final event = _log.append(
      'report.received',
      {
        // Las claves de una trama, con nulos en las que sólo existen en una trama: ningún lector tropieza.
        'device_id': deviceFor(r.origin),
        'frame_seq': null,
        'ref_seq': null,
        'prio_hint': prioHintFromFlags(r.flags),
        'incident_type': 1, // SOS genérico, como la app
        'flags': r.flags,
        'people_bucket': r.people,
        // Con ubicación: la escribió una persona («manual»), no un GPS. Sin ella, nada: el agente 1 no la inventa.
        'loc_quality': r.lat == null ? 0 : LocQuality.manual.index,
        'lat': r.lat,
        'lon': r.lon,
        'captured_at': nowMs ~/ 1000, // la hora del NODO al registrar, no la de cuando se oyó
        'battery_q': null,
        'text': r.text,
        'received_at': nowMs,
        'channel': kChannel,
        // Lo propio de este canal.
        'source_class': 'radio',
        'medium': r.medium.name,
        'origin': r.origin,
        'registered_by': r.who,
      },
      reportKey: key,
      rev: 0,
    );
    return DispatchResult(event, duplicate: false);
  }

  /// El «dispositivo» detrás del informe: el ORIGEN declarado, no quien lo teclea. El agente 3 cuenta fuentes
  /// independientes por dispositivo, así que dos informes del mismo origen son una sola fuente y dos orígenes
  /// distintos son dos. Sin origen, todos los informes sin origen comparten uno (se subestima la independencia, no
  /// se amplifica un rumor). Sólo letras, cifras y guiones: un origen no puede colar signos en el identificador.
  static String deviceFor(String? origin) {
    final slug = (origin ?? '')
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^\p{L}\p{N}-]', unicode: true), '');
    final cut = String.fromCharCodes(slug.runes.take(60));
    return cut.isEmpty ? 'radio:sin-origen' : 'radio:$cut';
  }

  static bool _sameContent(Map<String, Object?> b, DispatchRequest r) =>
      b['text'] == r.text &&
      b['medium'] == r.medium.name &&
      b['origin'] == r.origin &&
      b['registered_by'] == r.who &&
      b['flags'] == r.flags &&
      b['people_bucket'] == r.people &&
      b['lat'] == r.lat &&
      b['lon'] == r.lon;
}
