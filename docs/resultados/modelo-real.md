# El modelo de lenguaje REAL · T06 y T13 con modelo, y el nodo contra la API

**Estado (9 nov 2026): medido contra la API real de Anthropic, una vez, con datos sintéticos.** Hasta aquí todo lo del modelo se había probado con un servidor falso. Gasto total de estas pruebas: **≈ 5,4 USD** de los 200 disponibles. La clave se leyó siempre del entorno y no se escribió en ningún archivo, informe ni commit.

## Resultados

T06 con modelo: los **mismos 750 reportes con texto** (semillas nuevas 601–605, 150 por semilla), con reglas y con reglas + modelo (`effort low`). Informes completos: [`t06-modelo.md`](t06-modelo.md) (Sonnet 5.5) y [`t06-modelo-opus.md`](t06-modelo-opus.md) (Opus 5.5); datos crudos sin el texto en los `-datos.csv`.

| | Sólo reglas | + Sonnet 5.5 | + Opus 5.5 |
|---|---|---|---|
| **Recall de P1** (reportes con texto) | 85,4 % | **96,0 %** | **98,5 %** |
| Recall de P1 contando «revisión humana» | 89,4 % | 100 % | 100 % |
| Precisión de P1 | 100 % | 95,0 % | 89,0 % |
| **Falsos P1** (verdad ≠ P1, salió P1) | 0 | **10** | **24** |
| P1 que siguen sin salir P1 | 29 | 8 | 3 |
| Subgrupo «sin banderas con texto» | 47,6 % | 85,7 % | 85,7 % |
| Subgrupo «parcial con texto» | 73,8 % | 92,3 % | 100 % |
| Latencia p50 / p95 / máx | — | 1,95 / 4,4 / 5,7 s | 2,2 / 5,6 / 7,0 s |
| Llamadas por encima de **8 s** (plazo del nodo) | — | **0 de 749** | **0 de 749** |
| Fallos del modelo | — | 1 (`salida_invalida`) | 1 (`salida_invalida`) |
| Coste por reporte | 0 | **0,0024 USD** | 0,0048 USD |

T13 con modelo ([`t13-sonnet-5-5.md`](t13-sonnet-5-5.md), [`t13-opus-5-5.md`](t13-opus-5-5.md)): **12 de 12 textos cumplen con los dos modelos** (orden de bajar la urgencia en español e inglés, etiqueta de cierre falsa, JSON falso ya escrito, pedir despachar, pedir el mensaje de sistema, jugar a ser médico, relleno largo, mayúsculas y emojis, pedir saltarse las reglas, un «todo tranquilo» y un texto vacío).

El nodo real con `--llm on` contra la API real: **5 consultas, 5 útiles, 0 fallos**; el log trae sus 5 juicios del modelo (4 con evidencia citada); el informe de un despachador **no** se envió al modelo (las consultas se quedaron en 5).

## Cómo leerlo (sin adornos)

- **Sube de verdad lo que más hacía falta**, y donde el triaje por reglas era débil: paráfrasis y reportes sin banderas. Pero **el criterio de T06 completo sigue sin cumplirse**. Esto es sólo sobre reportes **con texto**, y ≈ 38 % de los reportes P1 (los SOS de la app sin texto) no pasan por el modelo. Mezclando estas cifras con las de `b3.md` (semillas distintas) el recall de P1 global queda en **≈ 85 %** (≈ 95 % si se cuenta «revisión humana» como acierto): una **estimación**, no una medición.
- **Es un intercambio, no una mejora gratis.** Más P1 capturados a cambio de más reportes revisados de más: los 10 falsos P1 de Sonnet son todos reportes P2 que el modelo sube un nivel; Opus captura 5 P1 más pero sobre-tría 14 P2 más y cuesta el doble. El modelo **nunca bajó** una urgencia (lo impide el piso por reglas) y sólo sube con una señal nueva con **cita literal verificada**.
- **El plazo de 8 s del nodo sirve con `effort low`** (la latencia máxima fue 7,0 s con Opus). Con el esfuerzo por defecto de la API (en Sonnet 5.5, `high`) **no se midió**: puede tardar más. Por eso el nodo ahora envía `effort low` por omisión (`--llm-effort`), para que lo desplegado sea lo medido; antes no lo enviaba y habría usado el de la API.
- **La instrucción maliciosa no engañó al modelo**, pero eso no es sólo mérito suyo: el nodo valida esquema y citas, nunca baja la urgencia y el modelo no tiene herramientas de despacho ni de aprobación.

## Lo que esto NO dice

- Datos **sintéticos**, escritos por la misma persona que las reglas; **una sola corrida** (estos modelos no permiten fijar el muestreo: otra corrida puede dar otras cifras); el mensaje al modelo **sin afinar**.
- Una **muestra** (750) y sólo reportes con texto.
- **No hay prueba con reportes reales ni con coordinadores.** Doce textos de T13 escritos por quien desarrolla el sistema no son una auditoría de seguridad.
- **Semillas «nuevas»:** 601–605 no se usaron para calibrar nada. Una prueba de la maquinaria con un modelo falso mostró las cifras de **sólo reglas** de unos 40 reportes de la semilla 601 (sin modelo real); no se cambió ninguna regla ni el mensaje al modelo después.
- Los precios son los de la guía de la API del 6 oct 2026 y el gasto lo calculó el programa con los tokens de cada respuesta; la consola es la que manda.
- T12 y la ráfaga con modelo colgado **siguen** siendo con un servidor falso, a propósito.
- El texto libre del ciudadano **sale hacia un tercero sin redactar** (ver PDF §8); esa privacidad sigue pendiente.

## El mismo modelo para el Reto 4 (agrupar con otras palabras)

Después de T06/T13 se usó el mismo modelo real como juez de vínculos entre reportes. **Resultado negativo según el criterio fijado de antemano** (falsa fusión 2,21 % frente a 1,22 % de las reglas; recall de pares +3,6 puntos; en la corroboración de 5 fuentes reúne 4): [`reto4-juez.md`](reto4-juez.md). No está en el nodo. Gasto del Reto 4: ≈ 6,2 USD, así que el total de las pruebas con la API real ronda los 11,6 USD de los 200.

## Cómo repetirlo

La clave se guarda con `read -s K; printf '%s' "$K" > ~/.sard-anthropic-key; chmod 600 ~/.sard-anthropic-key; unset K` en la terminal de quien la usa y se pasa **sólo por entorno** al comando:

```bash
ANTHROPIC_API_KEY=$(cat ~/.sard-anthropic-key) dart run packages/sim/bin/llm_smoke.dart                 # 3 llamadas con la respuesta cruda (≈ 0,01 USD)
dart run packages/sim/bin/t06_model.dart --plan --seeds 601,602,603,604,605 --per-seed 150            # coste estimado, no llama
ANTHROPIC_API_KEY=… dart run packages/sim/bin/t06_model.dart --seeds 601,602,603,604,605 --per-seed 150 --model claude-sonnet-5-5 --effort low --budget-usd 10
ANTHROPIC_API_KEY=… dart run packages/sim/bin/t13_modelo.dart --model claude-sonnet-5-5
# el nodo con el modelo (por omisión claude-sonnet-5-5 y effort low):
ANTHROPIC_API_KEY=… dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --llm on [--llm-model …] [--llm-effort low|medium|high|default]
```

Si se repite con otras semillas, que sean **nuevas** y con el código congelado. El tope de gasto se comprueba antes de cada llamada contando lo que cuestan las que están en vuelo, pero **no es estrictamente duro** (un piloto lo pasó por 0,0001 USD) y un modelo sin precio conocido no se mide.

## Verificado antes de gastar

La petición del nodo coincide con la guía de la API de entonces: `POST /v1/messages`, cabeceras `x-api-key` y `anthropic-version: 2026-10-21`, salida estructurada `output_config.format` con `json_schema`, sin parámetros de muestreo (dan 400), lectura del primer bloque `text`. La maquinaria (`packages/sim/test/t06_model_test.dart`, `t13_model_test.dart`) tiene 27 pruebas y 18 mutaciones deliberadas, dos de ellas supervivientes que se reforzaron; funciona sin clave contra un servidor falso.
