import 'resources.dart';

// Los recursos declarados DURANTE la operación (una ambulancia que queda sin gasolina, una unidad nueva que llega).
//
// Cada declaración es un evento inmutable que se replica entre nodos. Un nodo aislado puede declarar una cosa y otro
// otra DISTINTA sobre la misma unidad, y ninguno ve lo del otro hasta que se reconectan. Por eso la fusión NO usa «gana la
// última por reloj» (los relojes pueden estar desfasados: el inyector de fallos lo hace a propósito): usa el mismo patrón
// que las aprobaciones.
//
//  · Cada declaración nombra las que REEMPLAZA (`supersedes`). Una declaración vigente es la que ninguna otra reemplaza.
//  · Si queda UNA vigente, esa manda. Si quedan varias y dicen LO MISMO, no hay conflicto.
//  · Si quedan varias y DISCREPAN (dos nodos aislados dijeron cosas distintas), hay conflicto y, por seguridad, la unidad se
//    trata como NO DISPONIBLE hasta que una persona la resuelva con una declaración que reemplace a ambas. Nunca se ofrece una
//    unidad con la que alguien discrepa.
//  · El resultado no depende del orden en que llegan los eventos.

/// Una declaración de un recurso, tal como quedó en el log.
class ResourceDeclaration {
  const ResourceDeclaration({required this.eventId, required this.resource, this.supersedes = const [], this.declaredBy});

  /// El identificador del evento (único y el mismo en todos los nodos).
  final String eventId;
  final Resource resource;

  /// Identificadores de las declaraciones de ESTA unidad que ésta reemplaza.
  final List<String> supersedes;

  /// Quien la declaró (declarado, no autenticado salvo que el nodo identifique por código).
  final String? declaredBy;
}

/// Lo que de verdad se usa de una unidad: el recurso vigente y si hay un conflicto sin resolver.
class EffectiveResource {
  const EffectiveResource({required this.resource, required this.conflict, required this.declarationIds, this.declaredBy});

  final Resource resource;
  final bool conflict;

  /// Las declaraciones vigentes (hay que reemplazarlas TODAS para resolver un conflicto). Vacío = la de arranque.
  final List<String> declarationIds;
  final String? declaredBy;

  Map<String, Object?> toJson() => {...resource.toJson(), 'conflict': conflict, 'declarationIds': declarationIds, 'declaredBy': ?declaredBy};
}

bool _sameContent(Resource a, Resource b) => a.kind == b.kind && a.label == b.label && a.lat == b.lat && a.lon == b.lon && a.available == b.available;

/// Fusiona los recursos de arranque ([base]) con las [declarations] del log. Ordenado por identificador.
List<EffectiveResource> mergeResources(List<Resource> base, List<ResourceDeclaration> declarations) {
  final byId = <String, List<ResourceDeclaration>>{};
  for (final d in declarations) {
    (byId[d.resource.id] ??= []).add(d);
  }
  final baseById = {for (final r in base) r.id: r};
  final ids = {...baseById.keys, ...byId.keys}.toList()..sort();
  final out = <EffectiveResource>[];
  for (final id in ids) {
    final decls = byId[id];
    if (decls == null || decls.isEmpty) {
      out.add(EffectiveResource(resource: baseById[id]!, conflict: false, declarationIds: const []));
      continue;
    }
    // Sólo cuentan los reemplazos de ESTA unidad: se parte de sus propias declaraciones, así que nombrar la de otra no afecta.
    final superseded = {
      for (final d in decls)
        for (final s in d.supersedes)
          if (s != d.eventId) s,
    };
    var current = [for (final d in decls) if (!superseded.contains(d.eventId)) d];
    if (current.isEmpty) current = [...decls]; // un ciclo imposible con ids únicos; por si acaso, nada se pierde
    current.sort((a, b) => a.eventId.compareTo(b.eventId));
    final first = current.first;
    final agree = current.every((d) => _sameContent(d.resource, first.resource));
    final r = first.resource;
    out.add(
      EffectiveResource(
        resource: agree ? r : Resource(id: r.id, kind: r.kind, label: r.label, lat: r.lat, lon: r.lon, available: false),
        conflict: !agree,
        declarationIds: [for (final d in current) d.eventId],
        declaredBy: first.declaredBy,
      ),
    );
  }
  return out;
}
