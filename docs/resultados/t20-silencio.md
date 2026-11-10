# T20 · La capa «Silencio»: ¿cuántas zonas marcadas son de verdad un apagón?

Fecha: 2026-11-10T02:37:38.302393 · 20 semillas (de la 100) × 60 zonas = 1200 zonas, de ellas 382 con apagón · datos SINTÉTICOS de un modelo propio.

**Qué se mide.** El detector real de zonas en silencio (ventana de actividad 6 h, de silencio 30 min) frente a una verdad definida **aparte**: cada zona reporta como un proceso de Poisson de tasa λ (log-uniforme entre 0,3 y 12 reportes/h), y el 30 % sufre un **apagón** en un minuto al azar tras el cual su tasa cae al 5 % (el enunciado habla de «el 95 % de los teléfonos apagados»). La verdad no usa las ventanas del detector, así que **la medición puede salir mal**.

**Qué NO es.** No mide si la capa ayuda a decidir (no hubo coordinadores), ni con reportes reales: las llegadas de verdad vienen en ráfagas y no son un proceso de Poisson, y la tasa residual del 5 % es una elección. Mide cuánto confunde el detector un **rato de calma** con un **apagón** en un modelo sencillo.

## Resultado general (ventana de 30 min)

| | Zonas |
|---|---|
| Marcadas en silencio | 621 |
| …de ellas, un apagón de verdad (aciertos) | 303 |
| …de ellas, una zona que sólo estaba callada (falsas alarmas) | 318 |
| Apagones visibles que NO se marcaron | 37 |
| Apagones **invisibles** (ni un reporte en 6 h: el detector no puede verlos) | 42 |
| **Precisión** (de las marcadas, cuántas eran un apagón) | **48,8 %** (por semilla: 37,5 % a 63,0 %) |
| **Exhaustividad** (de los apagones visibles, cuántos se marcaron) | **89,1 %** |

## Por cuánto habla la zona (precisión y falsas alarmas)

| Zona | Marcadas | Precisión | Zonas normales marcadas (falsa alarma) |
|---|---|---|---|
| λ < 1 reporte/h | 273 | 29,3 % | 78,5 % (193 de 246) |
| 1 ≤ λ < 4 | 257 | 54,9 % | 36,6 % (116 de 317) |
| λ ≥ 4 reportes/h | 91 | 90,1 % | 3,7 % (9 de 245) |

## Por cuánto lleva apagada (exhaustividad)

| Apagón | Visibles | Marcadas | Exhaustividad |
|---|---|---|---|
| apagada hace menos de 30 min | 31 | 20 | 64,5 % |
| apagada hace 30–60 min | 22 | 21 | 95,5 % |
| apagada hace 1–3 h | 124 | 117 | 94,4 % |
| apagada hace 3 h o más | 163 | 145 | 89,0 % |

## La ventana de silencio es un compromiso, no una verdad

| Ventana de silencio | Marcadas | Precisión | Exhaustividad |
|---|---|---|---|
| 15 min | 768 | 42,4 % | 95,9 % |
| 30 min (la elegida) | 621 | 48,8 % | 89,1 % |
| 60 min | 458 | 59,4 % | 80,0 % |
| 120 min | 276 | 71,0 % | 57,6 % |

## Las hipótesis, escritas antes de correr

| | Hipótesis | Resultado |
|---|---|---|
| H1 | Precisión global < 80 % con 30 min | ✓ se cumple (48,8 %) |
| H2 | Precisión < 50 % en zonas con λ < 1/h | ✓ se cumple (29,3 %) |
| H3 | Exhaustividad ≥ 80 % en apagones de ≥ 60 min con λ ≥ 4/h | ✓ se cumple (81,3 %) |
| H4 | Los apagones de < 30 min casi no se marcan (< 10 %) | ✗ NO se cumple (64,5 %) |
| H5 | Más ventana ⇒ más precisión y menos exhaustividad (monótono) | ✓ se cumple |

## Diagnóstico de H4 (añadido DESPUÉS de ver que no se cumplía)

H4 esperaba que un apagón de menos de 30 min casi no se marcara. Se marcó el 64,5 %: no porque el detector «vea» el apagón, sino porque esas zonas **ya estaban calladas** (su último reporte era anterior). Según cuánto hablaba la zona antes de apagarse:

| Apagón de menos de 30 min en una zona con… | Visibles | Marcadas | % marcadas |
|---|---|---|---|
| λ < 1 reporte/h | 9 | 8 | 88,9 % |
| 1 ≤ λ < 4 | 16 | 9 | 56,3 % |
| λ ≥ 4 reportes/h | 6 | 3 | 50,0 % |

Es decir: la «detección» de un apagón reciente es en buena parte **coincidencia con una zona que ya callaba**, no un aviso del apagón; y la capa necesita al menos lo que dura su ventana para poder decir algo de un apagón nuevo. **Muestra pequeña** (31 apagones recientes visibles en total): léase como indicio, no como cifra.

## Qué dice esto del producto

La capa **no distingue un apagón de un rato de calma**: la precisión depende de cuánto hable la zona (arriba). Por eso el rótulo empieza por «el silencio no es seguridad» y cada zona dice cuántos reportes tuvo: una marca sobre una zona poco habladora es una **pregunta** para el coordinador, no una conclusión. Y una zona sin marca puede ser un apagón que el detector no ve (los invisibles, los recientes y los que conservan el 5 % que todavía reporta).

## Límites

- Un modelo sencillo del mismo autor (Poisson; apagón con tasa residual fija); lo real viene en ráfagas y con otras correlaciones espaciales.
- Una zona = una celda, sin cruce de fronteras de celda; una sola familia de semillas; los umbrales de las hipótesis son míos.
- No mide utilidad para el coordinador ni el coste de una falsa alarma frente a un apagón perdido.

## Cómo se reproduce

```
cd apps/node && dart run tool/t20_silencio.dart --seeds 20 --zones 60 --first-seed 100 --out ../../docs/resultados/t20-silencio.md
```
