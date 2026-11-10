# T19 · tres nodos: relevo del modelo y convergencia

Fecha: 2026-11-10T01:48:40.553651 · commit `ac3c7ce` (árbol limpio) · semilla 43 · 90 reportes acusados (ráfaga de 30) · `--takeover 6`.

Tres nodos reales (procesos `dart run`) en malla completa a través de seis proxies con interruptor, cada uno con su modelo FALSO (A `ok`, B `cautious`, C `ok`). Se mide el relevo del trabajo del modelo con TRES nodos (T12 lo midió con dos), el aislamiento de uno de ellos y la convergencia de los tres al reunirse.

## Criterio (propio del diseño, no del enunciado; commiteado antes de ejecutar)

1. huellas de A, B y C idénticas en ≤ 90 s tras reiniciar C y restablecer los enlaces; 2. la ráfaga de 30 reportes con texto acaba con juicio del modelo en ≤ 60 s desde el `kill -9` de C aunque C fuera dueño de parte; 3. 0 reportes acusados perdidos; 4. las decisiones contradictorias se conservan y los tres nodos muestran «denegada» con discrepancia; 5. ningún nodo muere por su cuenta.

## Resultado

- ✓ huellas de A, B y C idénticas en 4,4 s tras reiniciar C y restablecer los enlaces (criterio 1: ≤ 90 s)
- ✓ relevo: 30 de 30 reportes de la ráfaga con juicio del modelo en 10,3 s tras matar a C (criterio 2: ≤ 60 s)
- ✓ cero reportes acusados perdidos: 90 acusados y la cola de cada nodo tiene 90 / 90 / 90 (criterio 3)
- ✓ las dos decisiones contradictorias se conservan y los TRES nodos muestran «denegada» con la discrepancia marcada (criterio 4)
- ✓ ningún proceso murió por su cuenta (sólo el kill -9 deliberado de C) (criterio 5)

**Veredicto: cumple los cinco criterios.**

## Lo que se mide sin criterio

- De los 30 reportes de la ráfaga, **13** eran de C por rendezvous (los que dependían del relevo). De ésos: **13** los juzgó A o B (relevo de verdad), **0** sólo los juzgó C antes de morir (replicado, no es relevo) y **0** no tienen juicio de ningún nodo.
- Tiempo hasta cubrir la ráfaga tras matar a C: **10,3 s**.
- Tiempo real hasta converger los tres: **4,4 s**.
- Juicios del modelo por nodo de origen: A=35, B=39, C=16. Reportes juzgados por MÁS DE UN nodo (cómputo duplicado): **0**; de ellos, con urgencia distinta: **0**.

## Dos corridas de la misma semilla (el informe de arriba es la segunda)

| | 1.ª corrida (`6505dc9`) | 2.ª corrida (`ac3c7ce`, ésta) |
|---|---|---|
| Criterios | los cinco | los cinco |
| Ráfaga cubierta tras matar a C | 8,1 s | 10,3 s |
| Convergencia de los tres al reunirse | 2,9 s | 4,4 s |
| Reportes con cómputo duplicado | **17** (7 con urgencia distinta) | **0** |
| Juicios por origen | A=45, B=46, C=16 | A=35, B=39, C=16 |
| De la ráfaga, de C por rendezvous | no se medía | 13 (los 13 los relevó A o B) |

**Lo que se puede decir y lo que no.** Las dos corridas cumplen los cinco criterios, así que el relevo y la convergencia se sostienen. Pero **el cómputo duplicado salió 17 en una y 0 en otra**, y los tiempos también varían: son cifras de una sola corrida cada una, no valores. No se sabe de qué depende: la 1.ª pudo coincidir con otra carga en la máquina y la 2.ª se hizo con la máquina en reposo, pero **no se controló ni se comprobó**. Por eso no se afirma ni que los duplicados sean frecuentes ni que sean raros, y las «7 con urgencia distinta» de la 1.ª son una observación, no una tasa. La 1.ª corrida no medía cuántos reportes eran de C (el relevo se daba por inferido del tiempo); la 2.ª sí: 13 de 30 eran de C y los 13 los juzgó A o B, ninguno sólo C antes de morir.

## Lo que esto NO demuestra

- Nodos y modelos locales y sintéticos. El relevo se mide con UNA muerte; el aislamiento de B es total (no parcial); sólo dos corridas de la semilla (ver arriba: no coinciden en el cómputo duplicado); criterios y montaje del mismo autor que el sistema.
- El orden de relevo con más de tres nodos no se midió.

## Cómo reproducirlo

```bash
dart run packages/sim/bin/t19_tres_nodos.dart --reports 90 --burst 30 --seed 43   # desde la raíz, con el árbol limpio y la máquina sin carga
```
