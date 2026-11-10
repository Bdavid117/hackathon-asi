# Reto 4 con juez semántico (modelo de lenguaje) · medido en dos rondas, **no adoptado**

**Estado (9 nov 2026):** se construyó un juez que le pide al modelo real decidir si dos reportes cuentan el mismo suceso con otras palabras, y se midió una vez con semillas nuevas (701–705) contra la API real. **Aplicado el criterio fijado de antemano, el resultado es negativo: no se ofrece como opción en el nodo.** Gasto del Reto 4: ≈ 6,2 USD (piloto 0,55 + corrida 5,66). Los números completos están en [`t07-modelo.md`](t07-modelo.md) (generado) y [`t07-modelo-datos.csv`](t07-modelo-datos.csv) (una fila por par juzgado, sin texto).

## Qué se construyó

- **`packages/agents/lib/src/link_judge.dart`** (puro, sin red): elige hasta 6 candidatos anteriores que pasan las reglas duras, arma la petición (cada texto como dato delimitado; las etiquetas del mensaje se neutralizan), valida la respuesta **entera** (esquema cerrado, un juicio por candidato, confianza en [0, 1], cada cita debe ser un fragmento literal de su texto) o la descarta, y aplica los juicios con una función pura: el resultado no depende del orden de los juicios ni del nodo que los emitió (replicable). **El modelo propone, el código dispone:** un par fuera de la ventana de 3 h, de tipo incompatible o localizado en los dos y más lejos que σ₁+σ₂ no se une nunca, diga lo que diga el modelo.
- **`packages/sim/lib/src/t07_model.dart`** + `bin/t07_modelo.dart`: la medición (plan sin gasto, tope de gasto, tres variantes sobre los mismos reportes: sólo reglas, con veto y sin veto) y el criterio aplicado por código (`decideT07`).
- 64 pruebas del juez y 54 de la medición; mutaciones deliberadas (49 y 54) hasta que todas murieron. **No está conectado al nodo** (ver «Estado en el código»).

## Protocolo (para que se pueda comprobar que no se midió a posteriori)

1. El criterio se escribió y se commiteó **antes** de gastar (`6ed2fe5`), se revisó dos veces antes de la corrida y se congeló en `8e10d47` (árbol limpio; el informe anota ese hash).
2. Un piloto con la semilla **700** (fuera del resultado) sirvió sólo para ver que la API acepta la petición y cuánto cuesta. Dos revisiones salieron de él, ambas sobre el criterio y no sobre los resultados: «el doble de recall» era trivial con un 0,3 % de base, y el piloto no había llegado a juzgar ningún escenario de T08 (la cola iba en orden y el tope cortó antes).
3. **El mensaje al modelo no se tocó tras ningún piloto.** Los textos de T08 son fijos (los mismos en todas las semillas): afinar contra ellos habría contaminado la medición.
4. Una sola corrida: 963 consultas, 5 `salida_invalida` (0,5 %), sin repetir para mejorar la cifra.

## Resultado

| | Sólo reglas | Reglas + modelo |
|---|---|---|
| Recall de pares | 0,81 % | **4,43 %** (+3,6 puntos) |
| Precisión de pares | 98,8 % | 97,8 % |
| **Falsa fusión** (criterio ≤ 1 %) | **1,22 %** | **2,21 %** |
| Grupos mezclados | 1 | 6 |
| Grupos (150 sucesos reales) | 1 591 | 1 406 |
| Pares con texto en los dos: agrupa / al menos sugiere | 2,5 % / 36,4 % | 10,3 % / 38,9 % |

- **Uniones del modelo:** 221, de las cuales 216 acertadas (**97,7 %**). **Vetos:** 0.
- **Matriz del juez:** `same` 293 aciertos y 5 errores; `possible` 1 749 del mismo suceso y 397 de otro (precisión 81,5 %, peor que las sugerencias por reglas, 92 %); `different` 2 200 aciertos y 184 errores. Los `possible` no cambian nada (su confianza queda bajo 0,8).
- **T08, corroboración (5 fuentes con palabras propias):** reglas 5 grupos → modelo **2 grupos, el mayor con 4 de las 5 fuentes, confianza 0,60 → 0,97**. Se repitió igual en las 5 semillas, pero son **los mismos cinco textos**: es un caso, no cinco. La quinta fuente («colapso… frente a la gasolinera») quedó aparte: aporta un detalle que ninguna otra menciona y el juez le puso `possible` 0,6.
- **T08, rumor (12 copias):** 1 fuente → 1 fuente, confianza 0,20 → 0,20 (el juez no fabrica independencia).
- **Fiabilidad:** p50 / p95 / máx 2,9 / 4,0 / 9,9 s; 1 de 958 llamadas útiles pasó de los 8 s del nodo. 0,0059 USD por consulta.

## Veredicto del criterio (aplicado por código, sin margen de interpretación)

| Criterio | Valor | ¿Cumple? |
|---|---|---|
| 1. falsa fusión ≤ 1 % y ≤ la de las reglas + 0,5 puntos | 2,21 % (reglas 1,22 %) | **no** |
| 2. precisión de las uniones ≥ 95 % | 97,7 % | sí |
| 4. fallos ≤ 5 % y llamadas > 8 s ≤ 5 % | 0,5 % y 0,1 % | sí |
| 3. recall de pares +5 puntos y el doble | +3,6 puntos | **no** |
| 5. corroboración: un grupo con las 5 fuentes (≥ 80 % de escenarios) | 0 de 5 (4 de 5 fuentes) | **no** |
| 6. el rumor no gana credibilidad | 5 de 5 | sí |

**No se ofrece la unión por modelo, y el nodo no veta.** Dos matices honestos: (a) con estas semillas las **reglas solas** ya pasan del 1 % (1,22 %; en `b3.md` iba de 0 a 2,86 % según la semilla): con 24 sucesos por conjunto el criterio de falsa fusión es muy ruidoso; (b) el criterio 5 exige las 5 fuentes y el modelo llegó a 4: se midió tal como se fijó, sin aflojarlo.

## Por qué falló (explicación a posteriori, de los mismos datos)

- Los 5 `same` equivocados son **gemelos adversariales** del generador (misma calle, mismo vocabulario, casi a la vez; p. ej. «mi hijo está herido, se ahoga, carrera 43 con calle 15» frente a «…dificultad para respirar, carrera 43 con calle 15»). Por construcción, el texto no los distingue.
- **Los cinco tienen confianza exactamente 0,80**, el umbral. Entre los `same`: a 0,80 hay 113 aciertos y 5 errores; de 0,82 en adelante, 143 aciertos y **0** errores.
- Cinco uniones malas bastan: 0 → 5 grupos mezclados nuevos (de 2 a 5 reportes) y la falsa fusión de pares casi se duplica. Es la misma fragilidad de siempre: un vínculo falso fusiona varios pares.
- Que el juez dude («possible», 0,3–0,6) en los textos que sólo dicen la calle es **correcto**, no un fallo: ahí no hay información. El techo del recall lo pone lo que el texto dice (sólo el 48 % de los pares verdaderos con texto comparten la calle escrita y el 66 % alguna palabra de contenido).

## Ronda 2 (10 nov 2026): 8 semillas nuevas y confianza mínima 0,85 · **tampoco se adopta**

**Qué se hizo.** La ronda 1 dejó una hipótesis, deducida de sus propios datos: los cinco `same` equivocados tenían confianza exactamente 0,80, así que exigir 0,85 los habría dejado fuera (143 uniones buenas y 0 malas de las 257 y 5). Se probó con semillas **706–713**, mismo tamaño por semilla, mismo modelo, mismo esfuerzo y **el mismo mensaje**, con el criterio v2 de [`t07-ronda2-criterio.md`](t07-ronda2-criterio.md), commiteado antes de gastar (`cb425ae`). **Ese criterio se reescribió tras ver la ronda 1** (el «+5 puntos y el doble» era inalcanzable por aritmética con 0,85; el de «5 fuentes» dependía de un texto que el juez calificó `possible`): es **evidencia más débil que la de la primera vez**. Código medido: `8243b0f`, árbol limpio. Informe generado: [`t07-ronda2.md`](t07-ronda2.md) y [`t07-ronda2-datos.csv`](t07-ronda2-datos.csv).

**Gasto:** 1 586 llamadas, **9,54 USD** (0,0060 por llamada; el tope de la corrida era 12 y el registro [`gasto-api.json`](gasto-api.json) suma 21,16 USD en total según el propio programa). La consola de Anthropic no se ha conciliado todavía.

| | Sólo reglas | Reglas + modelo |
|---|---|---|
| Recall de pares | 0,48 % | **1,99 %** (+1,51 puntos) |
| Precisión de pares | 100,0 % | 99,1 % |
| **Falsa fusión** | **0,00 %** | **0,92 %** |
| Grupos mezclados | 0 | 3 |
| Uniones del modelo | — | 178, **175 acertadas (98,3 %)** |
| Corroboración de 5 fuentes (observación) | 1 fuente | 3–4 fuentes en el mayor grupo, 8 de 8; confianza 0,60 → 0,94–0,97; **ninguna reúne las 5** |

| Criterio v2 | Valor | ¿Cumple? |
|---|---|---|
| 1. falsa fusión ≤ 1 % **y** ≤ la de las reglas + 0,5 puntos | 0,92 % con el modelo, 0,00 % con las reglas | **no** |
| 2. precisión de las uniones ≥ 95 % con al menos 100 uniones | 98,3 % (175 de 178) | sí |
| 3. recall de pares +1,5 puntos | +1,51 puntos | sí (por 0,01) |
| 4. fallos ≤ 5 % y llamadas de más de 8 s ≤ 5 % | 8 de 1 586; 6 de 1 578 útiles | sí |
| 6. el rumor no gana fuentes ni pasa de 0,8 | 8 de 8 | sí |

**Veredicto aplicado por código: NO se adopta (falla el criterio 1). La pregunta se cierra: no hay tercera ronda.** El nodo sigue sin usar el juez y `link_judge` queda como componente medido dos veces y no adoptado.

**Lectura honesta:**

- La falsa fusión con el modelo (0,92 %) quedó **bajo el 1 % absoluto**; falla sólo la cláusula relativa («≤ la de las reglas + 0,5 puntos») porque las reglas dieron 0,00 %, sin ningún grupo mezclado. Con 24 sucesos por conjunto ese 0,00 % es en parte suerte de muestreo (en la ronda 1 las reglas dieron 1,22 % y en `b3.md` iban de 0 a 2,86 % según la semilla), pero el criterio estaba fijado así y **no se reinterpreta después de verlo**.
- **La hipótesis «0,85 lo arregla» no se confirmó.** Los 3 `same` equivocados con confianza ≥ 0,85 tienen **exactamente 0,85**, el umbral: el mismo patrón que en la ronda 1 (los 5 de 0,80). Subir el umbral desplazó el problema al siguiente valor que el modelo emite. Que 0,88 lo arreglaría sería otra hipótesis post hoc sobre los mismos datos, y probarla sería una tercera ronda, que el criterio cerró.
- **La ganancia es real pero pequeña:** recall de pares 0,48 → 1,99 % (sobre los pares con texto en los dos reportes, 1,6 → 5,3 %). Cumple el +1,5 puntos por una centésima.
- **La corroboración mejora** (de 1 fuente independiente a 3–4 en 8 de 8 escenarios, confianza hasta 0,97) pero no llega a reunir las 5, como en la ronda 1; su criterio se retiró, y se informa como observación.
- Fiabilidad: 7 salidas inválidas y 1 plazo agotado de 1 586 llamadas; 6 de 1 578 útiles pasaron de los 8 s del nodo.

**Lo que NO dice:** datos sintéticos escritos por quien escribió las reglas y el mensaje; una sola corrida (estos modelos no permiten fijar el muestreo); conjuntos de 24 sucesos con un intervalo de falsa fusión ancho; un criterio reescrito tras ver la ronda 1.

## Lo que NO sabemos (y no se debe afirmar)

- **Que un umbral de 0,85 lo arreglaría.** *(Probado en la ronda 2 con semillas nuevas: no se confirmó; ver arriba.)*
- Si con texto real, no generado por quien escribió las reglas y el mensaje, los gemelos se confunden más o menos.
- Con 24 sucesos por conjunto, el intervalo de la falsa fusión es ancho; una segunda corrida podría dar otras cifras (estos modelos no permiten fijar el muestreo).
- El texto libre del ciudadano sale hacia un tercero sin redactar (PDF §8); en la app el texto es opcional (≤ 140 bytes), así que el efecto real depende de cuántos reportes lo traigan (en el generador, el 55 %).

## Estado en el código

`link_judge` y la medición quedan en el repositorio como componente **medido y no adoptado**: no hay ninguna llamada desde el nodo, ni un flag. Si se integra más adelante, hay que (1) excluir los informes del despachador (`source_class: 'radio'`): su texto hoy no va al modelo y es una decisión de privacidad ya tomada; (2) escribir el juicio como un evento replicable (si se calculara al leer, dos nodos mostrarían grupos distintos y se rompería la huella de T15); (3) conservar el veto apagado.

## Cómo repetirlo

```bash
dart run packages/sim/bin/t07_modelo.dart --plan --seeds 706,707,708,709,710              # no llama a la API
ANTHROPIC_API_KEY="$(cat ~/.sard-anthropic-key)" dart run packages/sim/bin/t07_modelo.dart --seeds 706,707,708,709,710 --budget-usd 9
```

Desde la raíz del repositorio y con el árbol limpio (el informe anota el commit). Semillas **nuevas**, código y criterio congelados antes de correr. El tope de gasto no es estrictamente duro (un piloto lo pasó por 0,0001 USD).
