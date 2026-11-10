# T07 con el juez semántico REAL · agrupar reportes con otras palabras (Reto 4)

**Estado: medido contra la API real de Anthropic, UNA vez, con datos sintéticos.** Generado con `dart run packages/sim/bin/t07_modelo.dart`. La clave se leyó del entorno y no se escribió en ningún sitio.

## Qué se corrió

- Modelo **claude-sonnet-5-5**, effort **low**, confianza mínima 0.85, hasta 6 candidatos por reporte (los anteriores que pasan las reglas duras).
- Semillas **706, 707, 708, 709, 710, 711, 712, 713** (nuevas): 8 conjuntos sintéticos de 24 sucesos y ~300 reportes (2640 en total, 1485 con texto), más una corroboración de 5 fuentes y un rumor de 12 copias por semilla.
- **1586 llamadas**, gasto **$9.54** (tope $12.00), 1226 s.
- El tope de gasto se comprueba antes de cada llamada contando lo que cuestan las que están en vuelo; **no es estrictamente duro** (un piloto lo pasó por 0,0001 USD).
- Código: `8243b0f (árbol limpio)`.

### Criterio de adopción de la ronda 2 (REESCRITO tras ver la ronda 1: evidencia más débil)

Criterio de la ronda 2, REESCRITO tras ver los datos de la ronda 1 (evidencia más débil que la de la primera vez), escrito y commiteado antes de gastar. Semillas nuevas 706–713, mismo tamaño por semilla que la ronda 1, `--min-confidence 0.85`, mismo modelo, mismo esfuerzo y mismo mensaje (no se toca), comparación pareada contra reglas solas sobre los mismos reportes. **Se adopta la unión por modelo como opción apagada por omisión** sólo si se cumplen TODOS: (1) la falsa fusión de pares es ≤ 1 % y no supera en más de 0,5 puntos a la de sólo reglas; (2) la precisión de las uniones del modelo es ≥ 95 % con al menos 100 uniones hechas (con menos, el resultado es «no concluyente», no «cumple»); (3) el recall de pares sube al menos 1,5 puntos sobre el de sólo reglas (sustituye a «+5 puntos y el doble»); (4) los fallos del modelo son ≤ 5 % de las llamadas y las llamadas de más de 8 s ≤ 5 % de las útiles; (6) el rumor repetido no gana fuentes independientes por encima de las que tiene ni pasa de 0,8 de confianza. Se RETIRA el criterio de las 5 fuentes (5): se informa como observación, no como criterio. El veto sigue apagado. Si el criterio (1) vuelve a fallar, o el resultado es no concluyente, la pregunta se cierra: no se hace una tercera ronda.

## Resultado de pares (T07)

| | Sólo reglas | Reglas + modelo (con veto) | Reglas + modelo (sin veto) |
|---|---|---|---|
| Precisión de pares | 100.0 % | 99.1 % | 99.1 % |
| **Recall de pares** | 0.5 % | 2.0 % | 2.0 % |
| **Falsa fusión** (criterio ≤ 1 %) | 0.00 % | 0.92 % | 0.92 % |
| Grupos mezclados (más de un suceso real) | 0 | 3 | 3 |
| Grupos (para 240 sucesos reales) | 2572 | 2412 | 2412 |

Pares verdaderos: 16188; de ellos con texto en los dos reportes: 4815.
De esos 4815 pares con texto: **43.0 %** comparten la calle escrita y **62.0 %** alguna palabra de contenido. No es un techo (una paráfrasis no comparte palabras), pero dice cuánta evidencia hay en el texto: en este generador los gemelos adversariales usan la MISMA calle que su suceso base.

| Cobertura de pares verdaderos | Sólo reglas | + modelo (con veto) |
|---|---|---|
| Agrupa (`same`), todos los pares | 0.5 % | 1.6 % |
| Al menos sugiere (`same` + `possible`), todos | 20.4 % | 20.7 % |
| Agrupa, sólo pares con texto en los dos | 1.6 % | 5.3 % |
| Al menos sugiere, sólo pares con texto en los dos | 32.9 % | 33.8 % |

## Matriz del juez (veredicto × verdad)

Sobre los pares que el modelo juzgó (cada reporte contra sus candidatos), contra la verdad del generador.

| Veredicto | Mismo suceso (todos) | Distinto suceso (todos) | Mismo suceso (conf. ≥ 0.85) | Distinto suceso (conf. ≥ 0.85) |
|---|---|---|---|---|
| `same` | 488 | 6 | 222 | 3 |
| `possible` | 2899 | 822 | 0 | 0 |
| `different` | 291 | 3785 | 3 | 2386 |

Precisión de los `same`: 98.8 % (488 de 494).
Precisión de los `possible`: 77.9 % (2899 de 3721); la de las sugerencias por reglas fue 92 % (`b3.md`). Los `possible` no cambian nada hoy: su confianza queda bajo el umbral y sólo son información.
Precisión de los `different`: 92.9 % (3785 de 4076).

## Uniones del modelo y vetos

- **Uniones del modelo** (pares que las reglas no unían y el modelo sí, con confianza suficiente): **178**, de las cuales **175** eran del mismo suceso (precisión 98.3 %).
- **Vetos del modelo** (cortó una unión de las reglas): **0**, de los cuales **0** cortaron un par del mismo suceso.

## T08 con el juez (corroboración y rumor)

| Escenario | Reportes | Grupos (reglas → modelo) | Fuentes independientes del mayor grupo (reglas → modelo) | Confianza del mayor grupo (reglas → modelo) |
|---|---|---|---|---|
| corroboracion-706 | 5 | 5 → 3 | 1 → 3 | 0.60 → 0.94 |
| rumor-706 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-707 | 5 | 5 → 3 | 1 → 3 | 0.60 → 0.94 |
| rumor-707 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-708 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-708 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-709 | 5 | 5 → 3 | 1 → 3 | 0.60 → 0.94 |
| rumor-709 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-710 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-710 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-711 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-711 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-712 | 5 | 5 → 3 | 1 → 3 | 0.60 → 0.94 |
| rumor-712 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-713 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-713 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |

## Veredicto del criterio (aplicado mecánicamente)

| Criterio | Valor | ¿Cumple? |
|---|---|---|
| 1. falsa fusión ≤ 1 % y ≤ la de las reglas + 0,5 puntos | 0.92 % con el modelo, 0.00 % con las reglas | **no** |
| 2. precisión de las uniones del modelo ≥ 95 % con al menos 100 uniones | 98.3 % (175 de 178) | sí |
| 4. fallos ≤ 5 % de las llamadas y llamadas de más de 8 s ≤ 5 % de las útiles | 8 fallos de 1586; 6 de 1578 útiles pasan de 8 s | sí |
| 3. recall de pares: al menos +1,5 puntos sobre las reglas | 0.48 % → 1.99 % (+1.51 puntos) | sí |
| 6. rumor: no gana fuentes independientes ni pasa de 0,8 de confianza | 8 de 8 sin ganancia indebida | sí |

**NO se adopta la unión por modelo: criterios sin cumplir: 1. La pregunta se cierra: no se hace una tercera ronda.**

La corroboración de 5 fuentes (T08) se informa arriba como observación: su criterio se retiró (criterio retirado en la ronda 2).

## Latencia, coste y fallos

- Llamadas útiles: **1578 de 1586**; fallos: **8** (salida_invalida: 7, plazo_agotado: 1).
- Latencia p50 / p95 / máx: 2.868 / 3.88 / 67.001 s; llamadas por encima de **8 s** (plazo del nodo): **6 de 1578**.
- Tokens: 2136280 de entrada y 526828 de salida; **0.0060 USD por llamada** (precio de la guía del 6 oct 2026; la consola manda).

## Lo que esta prueba NO dice

- Datos **sintéticos**, escritos por la misma persona que las reglas y que el mensaje al modelo; **una sola corrida** (estos modelos no permiten fijar el muestreo); el mensaje **sin afinar**.
- Conjuntos pequeños (24 sucesos): la falsa fusión tiene un intervalo de confianza ancho; un par mal unido pesa mucho.
- La corroboración (5 fuentes) y el rumor usan **textos fijos** del generador: es un caso, no una distribución.
- El modelo sólo ve los 6 candidatos que elige el código: lo que quede fuera no se puede unir; el recall está acotado por esa elección.
- Sólo se juzgan reportes con texto; en la app el texto es **opcional** (hasta 140 bytes), así que el efecto en la operación depende de cuántos reportes reales lo traigan: aquí 56 % lo traen, un dato del generador y no de la vida real.
- El texto libre del ciudadano **sale hacia un tercero sin redactar** (ver PDF §8).
- Las variantes con y sin veto se miden las dos sobre los mismos datos; si se elige una después de verlas, esa elección es exploratoria (el criterio de arriba se fijó antes).
