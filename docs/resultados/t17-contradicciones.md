# T17 · contradicciones entre reportes (sin modelo)

Semillas 801, 802, 803, 804, 805 (nuevas: no se usaron para calibrar nada). Grupos = los sucesos reales del generador con ≥ 2 reportes.

| Semilla | Grupos | Naturales con contradicción (falsos +) | Inyectadas | Detectadas | Señuelos | Señuelos detectados (falsos +) |
|---|---|---|---|---|---|---|
| 801 | 100 | 0 | 20 | 20 | 60 | 0 |
| 802 | 100 | 0 | 17 | 17 | 57 | 0 |
| 803 | 100 | 0 | 16 | 16 | 55 | 0 |
| 804 | 100 | 0 | 20 | 20 | 47 | 0 |
| 805 | 100 | 0 | 24 | 24 | 48 | 0 |
| **Total** | **500** | **0** | **97** | **97** | **267** | **0** |

| Criterio (fijado antes de medir) | Resultado | ¿Cumple? |
|---|---|---|
| (1) recall sobre las inyectadas ≥ 95 % | 100,00 % | sí |
| (2) falsos positivos sobre los grupos naturales ≤ 1 % | 0,00 % | sí |
| (3) falsos positivos sobre los señuelos ≤ 1 % | 0,00 % | sí |

**Veredicto aplicado por código: cumple los tres criterios.**

Omitidos por no poder montar el caso: 136 grupos sin ninguna señal negable afirmada (inyección) y 0 sin ninguna señal libre (señuelo).

---

## Lectura (escrita a mano; regenerar la tabla con el script no la borra si se vuelve a pegar)

**Los tres criterios, fijados antes de medir (commit `d948518`), se cumplen. Es un resultado modesto y hay que leerlo así:**

- **El 100 % de recall es en buena parte por construcción.** La inyección usa exactamente las frases que el léxico ya sabe negar («sin heridos», «no hay atrapados», «sin fuego»): demuestra que el cableado funciona de punta a punta, **no** que se detecten negaciones con otras palabras («no hay nadie lastimado», «todos están bien»). El recall sobre lenguaje natural real es **desconocido** y probablemente bastante menor, porque el léxico es de un primer corte y no es exhaustivo.
- **Lo que sí dice algo es la otra mitad:** **0 falsos positivos** en 500 grupos naturales y en 267 **señuelos adversariales** (negar una señal que nadie afirma). La regla es estrecha a propósito: sólo salta cuando un reporte niega algo que OTRO afirma, siempre entre reportes distintos.
- **No se midió la clase «personas»** (el generador no trae cantidades de personas): sólo tiene sus pruebas unitarias (24 en `contradictions_test.dart`, 14 de 15 mutaciones detectadas y 1 equivalente).
- **No se sabe cuántos grupos reales la dispararían en la práctica.** Se usaron los grupos de la verdad de referencia, no los que arma el nodo, que casi no fusiona (0,43 % de los pares): con ese agrupamiento habrá pocos grupos de varios reportes y, por tanto, pocas contradicciones que mostrar.
- Datos sintéticos del mismo autor que las reglas; una sola corrida.
- Si el criterio hubiera fallado, la función no se habría ofrecido como «contradicciones evaluadas»; como cumple, el nodo la sirve y el tablero lo dice con **lo que se evalúa** (negación explícita y cantidad de personas) y **lo que no** (las de sentido).

**Qué hace y qué no hace la función en el nodo:** señala las contradicciones y las conserva a la vista para que decida una persona; **no** cambia la urgencia, ni «a revisar», ni la incertidumbre alta, y no fusiona ni separa incidentes (probado en `incident_contradictions_test.dart`).

## Cómo reproducirlo

```bash
dart run packages/sim/bin/t17_contradicciones.dart --out docs/resultados/t17-contradicciones.md
(cd packages/agents && dart test test/contradictions_test.dart)
(cd apps/node && dart test test/incident_contradictions_test.dart)
```
