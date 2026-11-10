// T18 · partición larga REAL con dos nodos (Reto 5).
//
//   dart run packages/sim/bin/t18_particion_larga.dart [--partition-seconds 600] [--reports 90] [--seed 42]
//        [--port-a 8101] [--port-b 8102] [--takeover 6] [--out docs/resultados/t18-particion-larga.md]
//
// Qué mide. Dos nodos REALES (procesos) con el modelo falso encendido, cada uno con SU modelo y los dos configurados como pares del otro
// a través de un proxy con interruptor (`PartitionProxy`). Se corta el enlace de verdad: el replicador de cada nodo sigue intentando y
// recibe errores de conexión. (La demostración `demo.dart` arranca los nodos SIN pares: ahí 600 s sólo esperan y no ejercitan nada.)
//   Fase 1 · con el enlace sano entran reportes por los dos nodos y se replican.
//   Fase 2 · se CORTA el enlace durante `--partition-seconds` (por omisión 600 = 10 min): cada lado recibe reportes que el otro no ve,
//            dos coordinadores deciden a la vez y se contradicen (uno en cada lado) y a mitad del corte se mata a B con `kill -9` y
//            se reinicia con su mismo disco.
//   Fase 3 · se RESTABLECE el enlace y se mide hasta cuándo las proyecciones de los dos nodos son idénticas.
// Los dos modelos falsos contestan DISTINTO a propósito (A `ok` sube a P1 lo que dice «encerrados»; B `cautious` nunca sube nada): si
// durante el corte cada lado fue dueño de todo y tras reconectar los dos juzgan el mismo reporte, los juicios duplicados difieren y
// los nodos deben converger igual (esa es la parte donde podría haber un defecto real).
//
// CRITERIO (propio del diseño, NO del enunciado; escrito y commiteado ANTES de ejecutar; semilla 42, 90 reportes, 600 s):
//   (1) tras restablecer el enlace, las huellas de proyección de A y B (cola + incidentes, como T10/T15) coinciden en ≤ 60 s;
//   (2) 0 reportes acusados se pierden: todos los acusados están en la cola de los dos nodos tras converger;
//   (3) las dos decisiones contradictorias tomadas cada una en su lado se conservan las dos y tras converger ambos nodos muestran
//       «denegada» con la discrepancia marcada;
//   (4) ningún proceso de nodo muere por su cuenta durante el corte (sólo el kill -9 deliberado de B);
//   (5) el replicador de cada nodo registró errores de conexión durante el corte (prueba de que el corte fue real y no «sin pares»).
// SE MIDEN Y SE INFORMAN, SIN CRITERIO: juicios del modelo duplicados (reportes con juicio de los dos nodos), cuántos de ellos difieren
// en la urgencia, tiempo real hasta converger, y lo que cada nodo ve del otro en /api/nodes durante el corte.
//
// Límites que el informe debe decir, pase o no pase: nodos y modelos locales y sintéticos (no hay red ni modelo reales); un corte total
// y simétrico (no hay cortes parciales ni asimétricos); un solo `kill -9`; una sola corrida por semilla; los criterios y el montaje
// son del mismo autor que el sistema.
import 'dart:io';

Future<void> main(List<String> args) async {
  stderr.writeln('T18: criterio fijado; el recorrido se implementa en el siguiente commit.');
  exit(2);
}
