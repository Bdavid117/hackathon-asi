import 'dart:convert';

import 'package:crypto/crypto.dart';

/// La **huella de las proyecciones**: un SHA-256 de lo que ve el coordinador, sin ninguna marca de
/// reloj ni identificador interno. Sirve para comprobar que (T10) dos nodos que trabajaron aislados
/// y se reconectaron muestran lo mismo y que (T15) dos ejecuciones con la misma semilla dan lo mismo.
///
/// Entra: cada reporte con su urgencia, señales, revisión, personas…; a qué **conjunto de reportes**
/// pertenece (no cómo se llama el grupo), sus fuentes, confianza redondeada e incertidumbre.
/// NO entra: cuándo llegó o se capturó, ni los nombres de grupo, ni el orden de la lista.
String projectionFingerprint(List<Map<String, Object?>> queue) {
  final membersOf = <Object?, List<String>>{};
  for (final i in queue) {
    (membersOf[i['group']] ??= []).add(i['reportKey']! as String);
  }
  for (final m in membersOf.values) {
    m.sort();
  }
  String list(Object? v) => (((v as List?)?.cast<String>() ?? const <String>[]).toList()..sort()).join(',');
  final rows = [
    for (final i in queue)
      [
        i['reportKey'],
        i['urgency'],
        i['rev'],
        i['flags'],
        i['lat'],
        i['lon'],
        i['text'],
        i['people'],
        list(i['signals']),
        i['groupUrgency'],
        i['sources'],
        ((i['confidence'] as num?)?.toDouble() ?? 0).toStringAsFixed(6),
        list(i['uncertainty']),
        i['escalate'],
        // el grupo, por su CONTENIDO: qué reportes lo forman
        membersOf[i['group']]!.join('+'),
      ].join('|'),
  ]..sort();
  return sha256.convert(utf8.encode(rows.join('\n'))).toString();
}
