# Medir el modelo de lenguaje real (T06 con modelo) · guía y estado

**Estado (9 nov 2026): la maquinaria está lista y probada SIN clave; todavía no se ha llamado a la API real.** Todo lo que el proyecto dice del modelo se probó con un servidor falso. Esta guía es lo que falta para cambiar eso, con el gasto acotado.

## Qué se verificó ya (sin clave)

- **La petición del nodo coincide con la guía actual de la API** (comprobado contra la documentación, no de memoria): `POST /v1/messages`, cabeceras `x-api-key` y `anthropic-version: 2026-10-21`, salida estructurada `output_config.format` con `json_schema`, sin parámetros de muestreo (dan 400), lectura del **primer bloque `text`** (con pensamiento activo el primero puede ser `thinking`) y de `stop_reason`.
- **Lo que sólo la API real puede decir** y la medición va a contestar: (1) si acepta el esquema, (2) cuánto tarda, (3) si el plazo de **8 s** del nodo basta con modelos que siempre piensan —si no, *todas* las consultas caerían al respaldo sin que se vea—, (4) cuántos tokens y dólares cuesta cada reporte, (5) si las citas del modelo pasan el validador.
- El puerto ahora lee los **tokens** de cada respuesta y acepta `effort` (`output_config.effort`); la petición de triaje es pública (`buildTriageRequest`) para que el humo y la medición usen exactamente la del nodo.

## Cómo dar la clave (sin que pase por la conversación)

1. En la consola de la API (console.anthropic.com → *API keys*) crea una clave, p. ej. `sard-hackathon`, y comprueba que el saldo está en ese espacio de trabajo. Conviene ponerle un límite de gasto al espacio de trabajo (p. ej. 20 USD).
2. En **tu propia terminal** (no en la de Claude Code), para que la clave no entre en la conversación:
   ```bash
   read -s K; printf '%s' "$K" > ~/.sard-anthropic-key; chmod 600 ~/.sard-anthropic-key; unset K
   ```
   El archivo está fuera del repositorio. La clave **nunca** se imprime, ni se escribe en un informe (si el informe la contuviera, no se escribe) ni se sube.
3. Se lanza así (la clave sólo vive en el entorno de ese comando):
   ```bash
   ANTHROPIC_API_KEY=$(cat ~/.sard-anthropic-key) dart run packages/sim/bin/llm_smoke.dart
   ```

## Los pasos, de menos a más gasto

| Paso | Orden | Gasto | Qué responde |
|---|---|---|---|
| 0 | `dart run packages/sim/bin/t06_model.dart --plan` | 0 (no llama) | Cuántos reportes y el coste estimado antes de gastar |
| 1 | `llm_smoke.dart` | ≈ 0,05 USD | Tres llamadas con la petición del nodo y la respuesta CRUDA (`stop_reason`, bloques, `usage`, el JSON) y lo que el nodo haría con ella (validación de esquema y de citas, piso por reglas) |
| 2 | `t06_model.dart` con semillas **nuevas** (601–605), 750 reportes con texto | **4–20 USD estimados; tope duro de 10 USD por corrida** | Recall de P1 con reglas frente a reglas + modelo, **sobre los mismos reportes**, por subgrupo; fallos por causa; latencia (cuántas pasan de 8 s); gasto real |
| 3 (opcional) | Lo mismo con `--model claude-opus-5-5` | 8–40 USD estimados, mismo tope | Si el modelo más capaz cambia algo |

El presupuesto total que me propongo gastar es **como mucho unos 40 USD** de los 200 disponibles; ninguna orden pasa de su tope (las llamadas en vuelo cuentan como gasto reservado) y un modelo sin precio conocido no se mide. Los precios de la guía son los del 6 oct 2026: **hay que contrastarlos con la consola**.

## Reglas de la medición

- Semillas **nuevas** (601–605 no se han visto) y código **congelado** durante la corrida; las cifras que se reporten son las que salgan, también si son malas.
- Comparación **pareada**: reglas y reglas + modelo sobre los mismos reportes. Sólo se consultan los reportes **con texto**.
- El modelo **nunca baja** una urgencia (piso por reglas) y sube sólo con una señal nueva con cita verificada; los fallos se cuentan **por causa** (plazo, HTTP, negativa, salida inválida): un fallo del modelo no puede ser invisible.
- Se escribe un informe (`docs/resultados/t06-modelo.md`) y un CSV de datos crudos **sin el texto** de los reportes.

## Qué NO va a decir (se escribirá en el informe)

Datos **sintéticos** del mismo autor que las reglas; una **muestra**, no el conjunto entero; **una sola corrida** (estos modelos no permiten fijar el muestreo); mensaje al modelo **sin afinar**; y T13 (instrucciones maliciosas) sigue probándose con un servidor falso, salvo el caso suelto del humo.

## Pruebas de la maquinaria

`packages/sim/test/t06_model_test.dart` (17) y las del puerto en `packages/agents/test/llm_port_test.dart`: muestreo determinista, tope de gasto (también con concurrencia), coste por tokens, piso, fallos por causa, informe sin clave ni texto, y la ruta HTTP contra el servidor falso. 12 mutaciones deliberadas; 2 sobrevivieron al primer intento y se reforzaron.
