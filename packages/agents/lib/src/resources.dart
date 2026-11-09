import 'dart:convert';

import 'geo.dart';

/// Tipos de recurso que el sistema conoce. Conjunto **cerrado**: ni un archivo de configuración ni un
/// modelo pueden inventar una categoría.
enum ResourceKind { ambulancia, bomberos, rescate, transito }

/// Un recurso declarado (sintético en esta versión): lo único que el agente 6 puede nombrar.
class Resource {
  const Resource({required this.id, required this.kind, required this.label, required this.lat, required this.lon, required this.available});

  final String id;
  final ResourceKind kind;
  final String label;
  final double lat;
  final double lon;
  final bool available;

  Map<String, Object?> toJson() => {'id': id, 'kind': kind.name, 'label': label, 'lat': lat, 'lon': lon, 'available': available};
}

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,24}$');

/// Lee el archivo de recursos (`{"resources": [...]}`) con validación **estricta**: tipo de recurso
/// conocido, identificadores únicos y acotados, coordenadas en rango, `available` booleano. Cualquier
/// defecto lanza [FormatException] con el motivo: el nodo no arranca con un archivo dudoso.
List<Resource> parseResources(String source) {
  final Object? root;
  try {
    root = jsonDecode(source);
  } on FormatException catch (e) {
    throw FormatException('el archivo de recursos no es JSON válido: ${e.message}');
  }
  if (root is! Map || root['resources'] is! List) {
    throw const FormatException('el archivo de recursos debe ser un objeto con la lista «resources»');
  }
  final out = <Resource>[];
  final seen = <String>{};
  var n = 0;
  for (final raw in root['resources'] as List) {
    n++;
    if (raw is! Map) throw FormatException('recurso #$n: debe ser un objeto');
    final id = raw['id'];
    if (id is! String || !_idPattern.hasMatch(id)) throw FormatException('recurso #$n: «id» inválido (1–24 letras, cifras, «-» o «_»)');
    if (!seen.add(id)) throw FormatException('recurso «$id»: identificador repetido');
    final kind = ResourceKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    if (kind == null) throw FormatException('recurso «$id»: tipo «${raw['kind']}» desconocido (${ResourceKind.values.map((k) => k.name).join(', ')})');
    final label = raw['label'];
    if (label is! String || label.trim().isEmpty || label.length > 80) throw FormatException('recurso «$id»: «label» debe ser texto de 1 a 80 caracteres');
    final lat = raw['lat'], lon = raw['lon'];
    if (lat is! num || lon is! num || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      throw FormatException('recurso «$id»: «lat» y «lon» deben ser números en rango');
    }
    final available = raw['available'];
    if (available is! bool) throw FormatException('recurso «$id»: «available» debe ser verdadero o falso');
    out.add(Resource(id: id, kind: kind, label: label, lat: lat.toDouble(), lon: lon.toDouble(), available: available));
  }
  return out;
}

/// El recurso **disponible** del tipo [kind] más cercano a (lat, lon), o `null` si no hay ninguno
/// disponible de ese tipo (nunca se sustituye por otro tipo). Un empate exacto se desempata por id,
/// así el resultado no depende del orden de la lista.
Resource? nearestAvailable(List<Resource> resources, ResourceKind kind, double lat, double lon) {
  Resource? best;
  var bestD = double.infinity;
  for (final r in resources) {
    if (r.kind != kind || !r.available) continue;
    final d = distanceMeters(lat, lon, r.lat, r.lon);
    if (d < bestD || (d == bestD && best != null && r.id.compareTo(best.id) < 0)) {
      best = r;
      bestD = d;
    }
  }
  return best;
}
