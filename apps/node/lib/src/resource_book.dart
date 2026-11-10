import 'package:sard_agents/sard_agents.dart';

import 'event_log.dart';

/// Tope del cuerpo de `POST /api/resources`.
const int kMaxResourceBytes = 4096;

/// Cuántas declaraciones puede reemplazar una sola.
const int kMaxSupersedes = 8;

final RegExp _controlChar = RegExp(r'[\u0000-\u001F\u007F]');

/// Una declaración de un recurso ya validada (`POST /api/resources`).
class ResourceDeclareRequest {
  const ResourceDeclareRequest({required this.resource, required this.who, this.supersedes = const []});

  final Resource resource;

  /// Quién declara (declarado, no autenticado salvo que el nodo identifique por código).
  final String who;

  /// Identificadores de las declaraciones de ESTA unidad que ésta reemplaza.
  final List<String> supersedes;
}

/// Validación **estricta** del cuerpo: los mismos rigores que el archivo de recursos (id, tipo, etiqueta, rango y
/// booleano), quién declara, y a lo sumo [kMaxSupersedes] reemplazos. Lanza [FormatException] diciendo qué campo está mal.
ResourceDeclareRequest parseResourceDeclaration(Object? json) {
  if (json is! Map) throw const FormatException('el cuerpo debe ser un objeto JSON');
  const fields = {'id', 'kind', 'label', 'lat', 'lon', 'available'};
  const allowed = {...fields, 'who', 'supersedes'};
  final extra = json.keys.where((k) => !allowed.contains(k)).toList();
  if (extra.isNotEmpty) throw FormatException('campos desconocidos: ${extra.join(', ')}');

  final who = json['who'];
  if (who is! String || who.trim().isEmpty || who.trim().runes.length > 80 || _controlChar.hasMatch(who.trim())) {
    throw const FormatException('who debe ser texto de 1 a 80 caracteres, sin saltos de línea');
  }

  final supersedes = <String>[];
  final raw = json['supersedes'] ?? const <Object?>[];
  if (raw is! List || raw.length > kMaxSupersedes) throw const FormatException('supersedes debe ser una lista de a lo sumo $kMaxSupersedes identificadores');
  for (final s in raw) {
    if (s is! String || s.isEmpty || s.length > 100) throw const FormatException('supersedes: cada elemento debe ser un identificador de 1 a 100 caracteres');
    supersedes.add(s);
  }

  final resource = resourceFromJson({for (final k in fields) k: json[k]}, where: 'declarado');
  return ResourceDeclareRequest(resource: resource, who: who.trim(), supersedes: supersedes);
}

/// Las declaraciones del log. Una mal formada (un evento replicado dañado) se IGNORA: no tumba al nodo ni a las demás.
List<ResourceDeclaration> readResourceDeclarations(Iterable<Event> events) {
  final out = <ResourceDeclaration>[];
  for (final e in events) {
    if (e.type != 'resource.declared') continue;
    try {
      final by = e.body['declared_by'];
      out.add(ResourceDeclaration(eventId: e.id, resource: resourceFromJson(e.body['resource']), supersedes: e.inputs, declaredBy: by is String ? by : null));
    } on FormatException {
      continue;
    }
  }
  return out;
}
