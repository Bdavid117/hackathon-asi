# T07 con el juez semántico REAL · agrupar reportes con otras palabras (Reto 4)

**Estado: medido contra la API real de Anthropic, UNA vez, con datos sintéticos.** Generado con `dart run packages/sim/bin/t07_modelo.dart`. La clave se leyó del entorno y no se escribió en ningún sitio.

## Qué se corrió

- Modelo **claude-sonnet-5-5**, effort **low**, confianza mínima 0.8, hasta 6 candidatos por reporte (los anteriores que pasan las reglas duras).
- Semillas **701, 702, 703, 704, 705** (nuevas): 5 conjuntos sintéticos de 24 sucesos y ~300 reportes (1650 en total, 900 con texto), más una corroboración de 5 fuentes y un rumor de 12 copias por semilla.
- **963 llamadas**, gasto **$5.66** (tope $9.00), 712 s.
- El tope de gasto se comprueba antes de cada llamada contando lo que cuestan las que están en vuelo; **no es estrictamente duro** (un piloto lo pasó por 0,0001 USD).
- Código: `8e10d47 (árbol limpio)`.

### Criterio de adopción (fijado antes de ver los datos)

Tercera revisión, antes de correr las semillas 701–705 (el piloto de la semilla 700 no entra en el resultado). **Para ofrecer la unión por modelo en el nodo como opción apagada por omisión** hace falta, con semillas nuevas y a la vez: (1) la falsa fusión de pares con el modelo es ≤ 1 % y no supera en más de 0,5 puntos a la de sólo reglas; (2) la precisión de las uniones que hace el modelo es ≥ 95 % (sin uniones no hay nada demostrado); (4) los fallos del modelo (plazo, HTTP, salida inválida) son ≤ 5 % de las llamadas y las llamadas de más de 8 s ≤ 5 % de las útiles. **Para recomendar activarla** además: (3) el recall de pares con el modelo sube al menos 5 puntos porcentuales y al menos el doble que el de sólo reglas; (5) en al menos el 80 % de las corroboraciones (5 fuentes con palabras propias) el modelo forma UN grupo con las 5 fuentes y más confianza que las reglas; (6) el rumor repetido no gana fuentes independientes por encima de las que tiene ni pasa de 0,8 de confianza. Sin (3), (5) y (6) el resultado es «opción disponible, sin ganancia demostrada». El veto (que el modelo corte una unión de las reglas) se adopta sólo si hay vetos y ≤ 10 % de ellos son dañinos (cortan pares del mismo suceso); si no, el nodo sólo une, no veta. Los veredictos `possible` no cambian nada (su confianza queda bajo el umbral): se informa su precisión y nada más.

## Resultado de pares (T07)

| | Sólo reglas | Reglas + modelo (con veto) | Reglas + modelo (sin veto) |
|---|---|---|---|
| Precisión de pares | 98.8 % | 97.8 % | 97.8 % |
| **Recall de pares** | 0.8 % | 4.4 % | 4.4 % |
| **Falsa fusión** (criterio ≤ 1 %) | 1.22 % | 2.21 % | 2.21 % |
| Grupos mezclados (más de un suceso real) | 1 | 6 | 6 |
| Grupos (para 150 sucesos reales) | 1591 | 1406 | 1406 |

Pares verdaderos: 9989; de ellos con texto en los dos reportes: 2763.
De esos 2763 pares con texto: **48.3 %** comparten la calle escrita y **65.7 %** alguna palabra de contenido. No es un techo (una paráfrasis no comparte palabras), pero dice cuánta evidencia hay en el texto: en este generador los gemelos adversariales usan la MISMA calle que su suceso base.

| Cobertura de pares verdaderos | Sólo reglas | + modelo (con veto) |
|---|---|---|
| Agrupa (`same`), todos los pares | 0.7 % | 2.8 % |
| Al menos sugiere (`same` + `possible`), todos | 21.5 % | 22.2 % |
| Agrupa, sólo pares con texto en los dos | 2.5 % | 10.3 % |
| Al menos sugiere, sólo pares con texto en los dos | 36.4 % | 38.9 % |

## Matriz del juez (veredicto × verdad)

Sobre los pares que el modelo juzgó (cada reporte contra sus candidatos), contra la verdad del generador.

| Veredicto | Mismo suceso (todos) | Distinto suceso (todos) | Mismo suceso (conf. ≥ 0.8) | Distinto suceso (conf. ≥ 0.8) |
|---|---|---|---|---|
| `same` | 293 | 5 | 257 | 5 |
| `possible` | 1749 | 397 | 0 | 0 |
| `different` | 184 | 2200 | 24 | 1742 |

Precisión de los `same`: 98.3 % (293 de 298).
Precisión de los `possible`: 81.5 % (1749 de 2146); la de las sugerencias por reglas fue 92 % (`b3.md`). Los `possible` no cambian nada hoy: su confianza queda bajo el umbral y sólo son información.
Precisión de los `different`: 92.3 % (2200 de 2384).

## Uniones del modelo y vetos

- **Uniones del modelo** (pares que las reglas no unían y el modelo sí, con confianza suficiente): **221**, de las cuales **216** eran del mismo suceso (precisión 97.7 %).
- **Vetos del modelo** (cortó una unión de las reglas): **0**, de los cuales **0** cortaron un par del mismo suceso.

## T08 con el juez (corroboración y rumor)

| Escenario | Reportes | Grupos (reglas → modelo) | Fuentes independientes del mayor grupo (reglas → modelo) | Confianza del mayor grupo (reglas → modelo) |
|---|---|---|---|---|
| corroboracion-701 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-701 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-702 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-702 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-703 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-703 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-704 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-704 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |
| corroboracion-705 | 5 | 5 → 2 | 1 → 4 | 0.60 → 0.97 |
| rumor-705 | 12 | 1 → 1 | 1 → 1 | 0.20 → 0.20 |

## Veredicto del criterio (aplicado mecánicamente)

| Criterio | Valor | ¿Cumple? |
|---|---|---|
| 1. falsa fusión ≤ 1 % y ≤ la de las reglas + 0,5 puntos | 2.21 % con el modelo, 1.22 % con las reglas | **no** |
| 2. precisión de las uniones del modelo ≥ 95 % | 97.7 % (216 de 221) | sí |
| 4. fallos ≤ 5 % de las llamadas y llamadas de más de 8 s ≤ 5 % de las útiles | 5 fallos de 963; 1 de 958 útiles pasan de 8 s | sí |
| 3. recall de pares: +5 puntos y al menos el doble | 0.81 % → 4.43 % (+3.62 puntos) | **no** |
| 5. corroboración: un grupo con las 5 fuentes y más confianza en ≥ 80 % de los escenarios | 0 de 5 | **no** |
| 6. rumor: no gana fuentes independientes ni pasa de 0,8 de confianza | 5 de 5 sin ganancia indebida | sí |

**NO se ofrece la unión por modelo: no cumple el nivel de seguridad (criterios sin cumplir: 1). El nodo NO veta: sólo une (no hubo vetos que midan si es seguro).**

## Latencia, coste y fallos

- Llamadas útiles: **958 de 963**; fallos: **5** (salida_invalida: 5).
- Latencia p50 / p95 / máx: 2.883 / 3.993 / 9.918 s; llamadas por encima de **8 s** (plazo del nodo): **1 de 958**.
- Tokens: 1283444 de entrada y 309685 de salida; **0.0059 USD por llamada** (precio de la guía del 6 oct 2026; la consola manda).

## Lo que esta prueba NO dice

- Datos **sintéticos**, escritos por la misma persona que las reglas y que el mensaje al modelo; **una sola corrida** (estos modelos no permiten fijar el muestreo); el mensaje **sin afinar**.
- Conjuntos pequeños (24 sucesos): la falsa fusión tiene un intervalo de confianza ancho; un par mal unido pesa mucho.
- La corroboración (5 fuentes) y el rumor usan **textos fijos** del generador: es un caso, no una distribución.
- El modelo sólo ve los 6 candidatos que elige el código: lo que quede fuera no se puede unir; el recall está acotado por esa elección.
- Sólo se juzgan reportes con texto; en la app el texto es **opcional** (hasta 140 bytes), así que el efecto en la operación depende de cuántos reportes reales lo traigan: aquí 55 % lo traen, un dato del generador y no de la vida real.
- El texto libre del ciudadano **sale hacia un tercero sin redactar** (ver PDF §8).
- Las variantes con y sin veto se miden las dos sobre los mismos datos; si se elige una después de verlas, esa elección es exploratoria (el criterio de arriba se fijó antes).
