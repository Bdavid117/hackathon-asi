// T19 · tres nodos: relevo del modelo y convergencia (Reto 5).
//
//   dart run packages/sim/bin/t19_tres_nodos.dart [--reports 90] [--burst 30] [--seed 43] [--isolated-seconds 30]
//        [--port-a 8111] [--port-b 8112] [--port-c 8113] [--takeover 6] [--out docs/resultados/t19-tres-nodos.md]
//
// Qué mide. Tres nodos REALES (A, B, C), cada uno con SU modelo falso (A `ok`, B `cautious`, C `ok`) y en MALLA COMPLETA a través de
// seis proxies con interruptor (cada nodo tiene a los otros dos como pares). T12 midió el relevo del trabajo del modelo con DOS nodos
// («con más nodos el orden sigue el mismo hash, pero no se midió»): esto lo mide con tres.
//   Fase 1 · malla sana: entran reportes por los tres y se replican.
//   Fase 2 · RELEVO: una ráfaga de reportes con texto entra por A y se mata a C con `kill -9` AL INSTANTE (C era dueño de parte de
//            ellos por rendezvous): A y B deben acabar juzgándolos todos, tomando el relevo.
//   Fase 3 · se AÍSLA B (vivo, sin enlace con A; C sigue muerto): cada lado recibe reportes, dos coordinadores deciden a la vez y se
//            contradicen (Ana en A concede, Luis en B deniega).
//   Fase 4 · se reinicia C con su mismo disco y se restablecen TODOS los enlaces: se mide hasta que los tres nodos muestran lo mismo.
//
// CRITERIO (propio del diseño, NO del enunciado; escrito y commiteado ANTES de ejecutar; semilla 43, 90 reportes, ráfaga de 30):
//   (1) tras reiniciar C y restablecer los enlaces, las huellas de proyección de A, B y C coinciden en ≤ 90 s;
//   (2) RELEVO: los 30 reportes de la ráfaga acaban con juicio del modelo (de cualquier nodo) en ≤ 60 s desde el kill -9 de C, aunque
//       C fuera dueño de parte de ellos;
//   (3) 0 reportes acusados se pierden: todos están en la cola de los tres nodos al final;
//   (4) las dos decisiones contradictorias se conservan y los TRES nodos muestran «denegada» con la discrepancia marcada;
//   (5) ningún proceso muere por su cuenta (sólo el kill -9 deliberado de C).
// SE MIDEN Y SE INFORMAN, SIN CRITERIO: tiempo hasta cubrir la ráfaga, juicios duplicados (reportes juzgados por más de un nodo) y
// cuántos de ellos difieren en la urgencia, reparto del trabajo entre los nodos y tiempo real hasta converger.
//
// Límites que el informe debe decir, pase o no pase: nodos y modelos locales y sintéticos; el relevo se mide con una sola muerte; el
// aislamiento de B es total (no parcial); una sola corrida por semilla; criterios y montaje del mismo autor que el sistema.
import 'dart:io';

Future<void> main(List<String> args) async {
  stderr.writeln('T19: criterio fijado; el recorrido se implementa en el siguiente commit.');
  exit(2);
}
