import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Peso de [nodeId] para [reportKey]: **SHA-256 de `nodo|reporte`** (UTF-8, concatenación literal), los
/// primeros 8 bytes en hexadecimal minúscula (equivale a un entero sin signo de 64 bits en orden big-endian,
/// así que comparar las cadenas compara los números). Está especificado así —y fijado con valores de
/// oro— para que cualquier nodo, en cualquier momento y lenguaje, calcule lo mismo; **no** se usa
/// `String.hashCode`, que no es estable entre ejecuciones ni plataformas. Un identificador de nodo no
/// debe contener «|».
String rendezvousWeight(String nodeId, String reportKey) =>
    sha256.convert(utf8.encode('$nodeId|$reportKey')).bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Los nodos en **orden de relevo** para [reportKey]: el dueño primero (mayor peso), luego quien lo
/// toma si el dueño no cumple, etc. Sin repetidos; un empate (prácticamente imposible) se rompe por el
/// identificador más pequeño. No depende del orden en que se den los nodos.
List<String> rendezvousOrder(String reportKey, Iterable<String> nodes) {
  final unique = {...nodes}.toList();
  final weights = {for (final n in unique) n: rendezvousWeight(n, reportKey)};
  unique.sort((a, b) {
    final c = weights[b]!.compareTo(weights[a]!);
    return c != 0 ? c : a.compareTo(b);
  });
  return unique;
}

/// El nodo **dueño** de [reportKey] entre los [liveNodes]: el de mayor peso (*rendezvous hashing*).
/// Quitar un nodo ajeno nunca cambia al dueño y quitar al dueño mueve **sólo** sus reportes (a diferencia
/// de un hash módulo n, que los movería casi todos). `null` si no hay ninguno vivo.
///
/// Sólo gobierna el trabajo **caro y repetible** (consulta al modelo, auditoría de vínculos): un nodo
/// que no es dueño igual recibe, guarda y acusa, y calcula las reglas; y si el dueño no produce el
/// evento esperado en un plazo, el siguiente lo toma. Una falsa alarma sólo duplica cómputo.
String? rendezvousOwner(String reportKey, Iterable<String> liveNodes) {
  final order = rendezvousOrder(reportKey, liveNodes);
  return order.isEmpty ? null : order.first;
}

/// Posición de [nodeId] en el relevo de [reportKey] (0 = dueño), o `null` si no está entre [nodes].
int? rendezvousRank(String reportKey, String nodeId, Iterable<String> nodes) {
  final i = rendezvousOrder(reportKey, nodes).indexOf(nodeId);
  return i < 0 ? null : i;
}
