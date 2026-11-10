# Juez de vínculos · ronda 2: criterio escrito ANTES de gastar

Este archivo se commitea antes de cualquier llamada a la API de la ronda 2. Lo que sigue es lo que se hará, con qué criterio y por qué el criterio **no es el de la ronda 1**.

## Por qué hay una ronda 2

La ronda 1 ([`reto4-juez.md`](reto4-juez.md), [`t07-modelo.md`](t07-modelo.md)) no cumplió el criterio: la falsa fusión subió de 1,22 % a 2,21 %. Los cinco `same` equivocados eran gemelos adversariales del generador y **los cinco tenían confianza exactamente 0,80**, el umbral. La hipótesis, deducida de esos mismos datos, es que exigir 0,85 los habría dejado fuera. Probarla exige semillas nuevas y un criterio escrito antes.

## Análisis gratuito de los datos de la ronda 1 (no es un resultado)

Sobre `t07-modelo-datos.csv`, solo los conjuntos de semilla, uniones `same` por confianza mínima:

| Confianza mínima | Uniones buenas | Uniones malas |
|---|---|---|
| 0,80 (la de la ronda 1) | 257 | 5 |
| 0,82 | 144 | 0 |
| **0,85** | **143** | **0** |
| 0,90 | 63 | 0 |

Es una **hipótesis deducida de los MISMOS datos**, no una prueba: con 0,85 se habrían conservado el 56 % de las uniones buenas y ninguna mala. Dos consecuencias aritméticas:

1. el criterio viejo «recall de pares +5 puntos y el doble» es **inalcanzable** con 0,85: ≈ 3,6 puntos × 0,56 ≈ **+2 puntos**;
2. el criterio de «5 fuentes» depende de un texto que el juez calificó solo `possible` (0,6): subir el umbral no lo arregla.

## Por eso el criterio se reescribe, y se dice

**Se reescribió después de ver la ronda 1. Es evidencia más débil que la de la primera vez** y el informe de la ronda 2 tiene que decirlo. El texto exacto está en `kT07DecisionRuleV2` (`packages/sim/lib/src/t07_model.dart`) y lo aplica por código `decideT07V2`, con una prueba en la frontera de cada umbral:

1. falsa fusión de pares ≤ 1 % y ≤ la de reglas + 0,5 puntos;
2. precisión de las uniones ≥ 95 % **con al menos 100 uniones** (con menos: «no concluyente», no «cumple»);
3. recall de pares ≥ el de reglas + **1,5 puntos** (sustituye a «+5 y el doble»);
4. fallos ≤ 5 % y llamadas de más de 8 s ≤ 5 % de las útiles;
6. el rumor repetido no gana fuentes independientes ni pasa de 0,8 de confianza.

Se **retira** el criterio de las 5 fuentes (se informa como observación). El veto sigue apagado. **Si la falsa fusión vuelve a fallar, o el resultado es no concluyente, la pregunta se cierra: no hay tercera ronda.**

## Montaje

- Semillas **706–713** (8, nuevas), mismo tamaño por semilla que la ronda 1 (24 sucesos, 300 reportes, 6 adversariales) para poder comparar, `--min-confidence 0.85`, **mismo modelo, mismo esfuerzo y mismo mensaje** (no se toca nada de lo que ve el modelo), comparación pareada contra reglas solas sobre los mismos reportes. Una sola corrida; no se repite para mejorar la cifra.
- Plan (`--plan`, sin llamar a la API): **24 conjuntos, 1 586 consultas**, 5,6 candidatos de media. La estimación teórica es de 8,56 a 31,72 USD (entre consultas cortas y largas); lo **medido** en la ronda 1 fue 0,0059 USD por llamada, o sea ≈ **9,4 USD** esperados.

## Gasto

- Registro: [`gasto-api.json`](gasto-api.json), fuente de lo gastado según el propio programa; **la consola de Anthropic manda**. Al empezar: **11,56 USD** (dos partidas son estimaciones y están marcadas), pendiente de reconciliar con la consola.
- Tope total del usuario: **50 USD** (incluido lo ya gastado). Este plan se auto-limita: tope de la corrida **12 USD**, y el registro **se niega a lanzar** si lo gastado + el tope de la corrida pasa de **40 USD** (reserva de 10: el tope por corrida no es estrictamente duro). Si la corrida falla, se anota el tope entero como estimación conservadora.
- **No se gasta nada hasta que el usuario dé la cifra de la consola y su visto bueno a este criterio.**

## Cómo se lanzará

```bash
ANTHROPIC_API_KEY="$(cat ~/.sard-anthropic-key)" dart run packages/sim/bin/t07_modelo.dart \
  --seeds 706,707,708,709,710,711,712,713 --min-confidence 0.85 --criterion 2 --budget-usd 12 \
  --out docs/resultados/t07-ronda2.md
```

Con el árbol limpio y la máquina sin carga; el informe anota el commit.
