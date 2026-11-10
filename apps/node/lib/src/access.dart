import 'dart:convert';

/// La clave del contexto de la petición donde el guardián deja el nombre de quien presentó su código.
const String kWhoContext = 'sard.who';

final RegExp _control = RegExp(r'[\x00-\x1f\x7f  ]');
final RegExp _blank = RegExp(r'\s');

/// Compara en tiempo constante respecto de la posición del primer desacuerdo: no revela con el tiempo cuántos caracteres acertó
/// quien adivina. (Que lo cumpla no se puede probar con una prueba ni con una mutación: se comprueba leyendo este código.)
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// `Authorization: Bearer <código>`: el esquema no distingue mayúsculas (RFC 7235), el código sí, y se compara ENTERO
/// (un prefijo, un sufijo o un espacio de más no sirven).
bool bearerMatches(String? header, String expected) {
  final presented = _presented(header);
  return presented != null && constantTimeEquals(utf8.encode(presented), utf8.encode(expected));
}

String? _presented(String? header) {
  if (header == null) return null;
  final m = RegExp(r'^bearer (.*)$', caseSensitive: false).firstMatch(header);
  return m?.group(1);
}

/// El nombre del dueño del código presentado, o `null` si no es el de nadie. Compara con TODOS los códigos, sin salir en el
/// primer acierto: el tiempo no depende de cuál de ellos era.
String? identifyBearer(String? header, Map<String, String> codes) {
  final presented = _presented(header);
  if (presented == null) return null;
  final bytes = utf8.encode(presented);
  String? who;
  for (final e in codes.entries) {
    if (constantTimeEquals(bytes, utf8.encode(e.value))) who = e.key;
  }
  return who;
}

/// Analiza `--coordinator-codes "Ana Gómez=codigo-1234,Luis Torres=otro-codigo"`: nombre → código.
///
/// Cada entrada es exactamente `nombre=código`. Los nombres siguen las reglas de «who» (1–80 caracteres, sin saltos de línea), son
/// únicos (sin distinguir mayúsculas ni espacios alrededor: dos «Ana» confundirían la auditoría) y los códigos tienen al menos 8
/// caracteres, sin espacios, y son distintos entre sí y del de la réplica. Un «,» o un segundo «=» no se pueden expresar y se rechazan
/// en vez de partirse mal. Los mensajes de error NO repiten ningún código.
Map<String, String> parseCoordinatorCodes(String raw, {String? peerToken}) {
  if (raw.trim().isEmpty) throw const FormatException('--coordinator-codes está vacío: usa «Nombre=código,Otro=código».');
  final byName = <String, String>{};
  final seenNames = <String>{};
  final seenCodes = <String>{};
  var n = 0;
  for (final entry in raw.split(',')) {
    n++;
    if (entry.trim().isEmpty) throw FormatException('--coordinator-codes: la entrada $n está vacía (¿una coma de más?).');
    final eq = entry.indexOf('=');
    if (eq < 0 || entry.indexOf('=', eq + 1) >= 0) throw FormatException('--coordinator-codes: la entrada $n debe ser «nombre=código» con un solo «=».');
    final name = entry.substring(0, eq).trim();
    final code = entry.substring(eq + 1);
    if (name.isEmpty || name.runes.length > 80 || _control.hasMatch(name)) {
      throw FormatException('--coordinator-codes: el nombre de la entrada $n debe tener de 1 a 80 caracteres, sin saltos de línea.');
    }
    if (code.length < 8) throw FormatException('--coordinator-codes: el código de «$name» debe tener al menos 8 caracteres.');
    if (_blank.hasMatch(code) || _control.hasMatch(code)) throw FormatException('--coordinator-codes: el código de «$name» no puede llevar espacios ni saltos de línea.');
    if (!seenNames.add(name.toLowerCase())) throw FormatException('--coordinator-codes: el nombre «$name» está repetido.');
    if (!seenCodes.add(code)) throw FormatException('--coordinator-codes: el código de «$name» es igual al de otro coordinador.');
    if (peerToken != null && code == peerToken) {
      throw FormatException('--coordinator-codes: el código de «$name» es igual al de la réplica: quien copia el log no debe poder aprobar.');
    }
    byName[name] = code;
  }
  return byName;
}

/// Ata el cuerpo de una petición a la identidad que presentó el código (`null` si no hay identidad: no se toca nada).
///
/// «who» puede faltar (o ser `null`): se rellena con el nombre del código. Si viene, tiene que ser ese mismo nombre (aun con
/// espacios alrededor); cualquier otra cosa devuelve un motivo y la petición se rechaza SIN registrar nada. Ignorarlo en
/// silencio dejaría que el tablero mostrara un nombre y el registro guardara otro.
({Object? body, String? mismatch}) bindIdentity(String? identity, Object? decoded) {
  if (identity == null || decoded is! Map) return (body: decoded, mismatch: null);
  final presented = decoded['who'];
  if (!decoded.containsKey('who') || presented == null) return (body: {...decoded, 'who': identity}, mismatch: null);
  if (presented is String && presented.trim() == identity) return (body: decoded, mismatch: null); // el validador recorta los espacios
  return (body: decoded, mismatch: 'el nombre («who») no coincide con el del código de acceso: se registra a nombre de quien lo presenta, o se omite');
}
