# T06 con el modelo de lenguaje REAL · `claude-sonnet-5-5` (effort `low`)

Mismo triaje, **mismos 750 reportes**, dos formas: sólo reglas y reglas + modelo (`triageWithModel`: el modelo nunca baja lo que dicen las reglas; sube sólo con una señal nueva de cita verificada). Semillas 601, 602, 603, 604, 605 del generador sintético (150 reportes con texto por semilla, repartidos por todo el conjunto).

## Resumen

| | Sólo reglas | Reglas + modelo |
|---|---|---|
| **recall de P1** | 85.4 % | **96.0 %** |
| recall de P1 contando «revisión humana» como acierto | 89.4 % | 100.0 % |
| precisión de P1 | 100.0 % | 95.0 % |
| reportes no P1 clasificados P1 (sobre-triaje) | 0 | 10 |
| exactitud global | 81.3 % | 82.4 % |

El modelo cambió la urgencia de **52** de 750 reportes (siempre a más urgente: el piso por reglas impide bajarla). Respondió algo utilizable en **749** de 750.

## Por subgrupo (reportes cuya verdad es P1)

| Subgrupo | Reportes P1 | Recall reglas | Recall reglas + modelo |
|---|---|---|---|
| banderas_coherentes | 75 | 100.0 % | 100.0 % |
| gemelo_p1 | 37 | 97.3 % | 100.0 % |
| parcial_con_texto | 65 | 73.8 % | 92.3 % |
| sin_banderas_con_texto | 21 | 47.6 % | 85.7 % |

## Por etiqueta (reportes cuya verdad es P1)

| Etiqueta | Reportes P1 | Recall reglas | Recall reglas + modelo |
|---|---|---|---|
| con_faltas | 25 | 80.0 % | 100.0 % |
| con_texto | 198 | 85.4 % | 96.0 % |
| gemelo | 37 | 97.3 % | 100.0 % |
| parafraseado | 113 | 76.1 % | 92.9 % |
| reloj_desfasado | 7 | 100.0 % | 100.0 % |
| repetido | 13 | 76.9 % | 100.0 % |
| sin_ubicacion | 22 | 90.9 % | 100.0 % |
| ubicacion_imprecisa | 11 | 90.9 % | 100.0 % |

## Fallos del modelo (se cae al respaldo de reglas), por causa

| Causa | Reportes |
|---|---|
| `salida_invalida` | 1 |

## Latencia y plazo del nodo

Llamadas con respuesta utilizable: p50 **1952 ms**, p95 **4446 ms**, máximo 5727 ms. **0 de 749 pasaron de 8 s**, que es el plazo con el que el nodo consulta al modelo: lo que pase de ahí cae al respaldo de reglas y no se ve en la cola. Plazo de esta medición: 90 s.

## Gasto

| | |
|---|---|
| Llamadas hechas | 750 (sin hacer por el tope: 0) |
| Tokens de entrada / salida | 639151 / 49476 (la salida incluye el razonamiento) |
| Gasto | **$1.7731** de un tope de $10.00 |
| Por reporte | $0.00236 |
| Duración | 402 s con concurrencia 4 |

## Lo que esta medición NO dice

- Los datos son **sintéticos** y los generó la misma persona que escribió las reglas: no mide el mundo real.
- Es una **muestra** (750 reportes con texto), no el conjunto entero, y **una sola corrida**: estos modelos no permiten fijar el muestreo, así que otra corrida puede dar otras cifras.
- Sólo se consultan los reportes **con texto**; los que no lo traen se quedan con reglas, así que el recall de todo el sistema es distinto del de esta muestra.
- El mensaje al modelo es el del proyecto, **sin afinar**. Los precios son los de la guía de la API del 6 oct 2026 y hay que contrastarlos con la consola.
- El comportamiento ante un reporte con instrucciones maliciosas se prueba aparte (T13, con un servidor falso); aquí no.

Reproducir (la clave sólo por entorno; ver `packages/sim/bin/t06_model.dart`): `ANTHROPIC_API_KEY=… dart run packages/sim/bin/t06_model.dart --seeds 601,602,603,604,605 --per-seed 150 --model claude-sonnet-5-5 --effort low --budget-usd 10.0`.
