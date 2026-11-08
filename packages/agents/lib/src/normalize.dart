/// Normaliza el cuerpo de un `report.received`: copia los campos tal cual y añade
/// `missing`, la lista de lo que el reporte no trae (`ubicacion`, `texto`).
///
/// No inventa ni completa ningún dato.
Map<String, Object?> normalize(Map<String, Object?> receivedBody) {
  final missing = <String>[];
  if (receivedBody['lat'] == null || receivedBody['lon'] == null) missing.add('ubicacion');
  if (receivedBody['text'] == null) missing.add('texto');
  return {...receivedBody, 'missing': missing};
}
