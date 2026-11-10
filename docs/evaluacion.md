# Cómo se lee la planilla de evaluación y qué evidencia tiene cada celda

**Qué es la planilla.** El equipo recibió una hoja de evaluación en blanco (no está en el repositorio ni es parte del enunciado: el enunciado sigue sin traer rúbrica, pesos ni metas numéricas). Tiene **cuatro criterios**, cada uno con una «Nota del tema» de **máximo 1,00**:

1. **Factibilidad de uso en cada etapa del reto**
2. **Creatividad de la solución**
3. **Funcionalidad del prototipo y completitud**
4. **Presentación**

Los tres primeros se califican **por etapa** (filas «Etapa primeras seis horas», «Silencio digital», «Integración») y una cuarta fila, «Consideración del Jurado». El cuarto se califica por **Claridad**, **Comunicación asertiva**, **Manejo de la evidencia** y «Consideración del Jurado». La planilla no trae descriptores ni pesos.

**Inferencias mías, no dichas por la planilla.** «Etapa primeras seis horas» ≈ Escenario 1 (el enunciado dice «primeros minutos»), «Silencio digital» ≈ Escenario 2 y «Integración» ≈ el recorrido de 8 pasos del §4.7. Es lo más probable por los nombres; conviene confirmarlo con quien reparte la planilla. **Aquí no hay puntajes ni autoevaluación**: sólo qué evidencia respalda cada celda, dónde está, cómo se enseña y qué falta.

---

## Cuadrícula 3 × 3: criterio × etapa

### 1 · Factibilidad de uso

| Etapa | Qué se puede enseñar | Dónde / cómo | Brecha honesta |
|---|---|---|---|
| **Primeras seis horas** (capturar y transmitir) | Un SOS en un toque que se guarda sin red y sale solo al volver la señal; trama de 33 B; confirmaciones selectivas; modo ahorro; presupuesto por dispositivo que degrada en vez de rechazar | La app en el simulador; cap. 5 y 7 del PDF; T01–T05 | GPS y batería se simularon en el emulador y el simulador (lo que permite el §4.7); no hubo prueba con personas |
| **Silencio digital** (nodo caído, nodos aislados, fragmentos) | Un nodo que se apaga sin aviso y otro que sigue con **todo** lo replicado; la capa «Silencio»; incertidumbre y contradicciones visibles | `bash tool/expo.sh` y `bash tool/expo_ctl.sh kill A`; T18, T19; [`cobertura.md`](resultados/cobertura.md) | **La ventana del navegador depende del nodo que la sirvió:** si ése cae hay que abrir la del otro (no conmuta sola). La capa «Silencio» no distingue un apagón de un rato de calma (T20: precisión 49 %) |
| **Integración** (el recorrido de 8 pasos) | Reporte → almacenamiento local → transmisión intermitente → priorización → tablero → pérdida de un nodo → recuperación | `PART=4 bash tool/demo.sh 42` (misma semilla ⇒ misma huella) y el recorrido en vivo de [`demo-en-vivo.md`](pitch/demo-en-vivo.md) | Los ocho pasos no se ven juntos en una sola pantalla: se cuentan en el pitch |

### 2 · Creatividad

| Etapa | Qué la distingue | Dónde |
|---|---|---|
| **Primeras seis horas** | «SOS primero, detalles después»: el reporte es una trama mínima y lo demás son revisiones del mismo reporte; la urgencia nunca depende del modelo (piso de reglas) | PDF cap. 6–7; T06 |
| **Silencio digital** | No hay nodo principal: log por nodo, trabajo caro repartido con *rendezvous hashing* y relevo si el dueño calla; **una capa que se mide a sí misma** (T20 dice cuánto confunde calma con apagón) y lo muestra en su propio rótulo | `docs/resultados/t18`, `t19`, `t20-silencio.md` |
| **Integración** | Un solo registro de eventos, del teléfono al tablero; la huella de proyección convierte «funciona» en algo **comparable** entre ejecuciones; historia del incidente con auditoría | T15; panel «Historia» |

### 3 · Funcionalidad del prototipo y completitud

| Etapa | Evidencia | Dónde |
|---|---|---|
| **Primeras seis horas** | App móvil, nodo y tablero funcionando; los 7 entregables con su comando de reproducción | README (mapa de 7 entregables); `bash tool/test_all.sh` |
| **Silencio digital** | Las cinco preguntas del Escenario 2 con su prueba (E2.1 T09 · E2.2 T10 · E2.3 T07/T13 · E2.4 T08 · E2.5 T11/T14) más T18 y T19 | Matriz de trazabilidad del PDF (cap. 4) |
| **Integración** | Recorrido con una condición adversa reproducible | `tool/demo.sh`, `tool/expo.sh` |

**Lo que NO se logró o no se cumple** (se dice, no se esconde; el detalle y las cifras están en el README y en los informes):

- **T06:** el recall de P1 con reglas (78,5 %) no llega a la meta propia de 95 %; con el modelo sube, en una corrida y con datos sintéticos.
- **Reto 4:** el agrupamiento casi no fusiona (0,43 % de los pares verdaderos con reglas); el juez de modelo se midió **dos veces** y no se adoptó (la pregunta se cerró).
- **Quien aprueba no está autenticado** (con `--coordinator-codes` queda *identificado por código*) y la clave de integridad es compartida; `--llm on` envía texto libre de ciudadanos a un tercero sin redactar datos personales (apagado por omisión).
- **No hubo prueba con coordinadores** ni con despachadores reales; los datos son sintéticos y los genera el mismo autor que las reglas, así que las cifras miden coherencia interna.
- **T19:** el cómputo duplicado salió 17 en una corrida y 0 en otra, sin explicar.
- **Falta el video de respaldo** (se graba con el código congelado).

### 4 · Presentación

| Subcriterio | Qué lo respalda | Dónde |
|---|---|---|
| **Claridad** | Una idea por lámina (16 láminas); el tablero explica cómo se lee (panel «Situación») | `docs/pitch/SARD-pitch.pdf` y el Artifact |
| **Comunicación asertiva** | Cifras con su límite al lado; lista de **frases que no se deben decir**; preguntas difíciles con respuesta preparada | [`guion.md`](pitch/guion.md) |
| **Manejo de la evidencia** | Cada afirmación → un informe con fecha, commit y comando; criterios o hipótesis commiteados **antes** de medir (T20; la ronda 2 del juez, con un criterio reescrito tras ver la ronda 1, y dicho); un guion de demostración con lo que se hace en vivo y lo que se muestra guardado | `docs/resultados/`, [`demo-en-vivo.md`](pitch/demo-en-vivo.md) |

---

## Cómo mejorarlo (en orden de lo que más mueve)

1. **Ensayar el guion en vivo tres veces con la carga de la exposición** (simulador, dos ventanas del navegador y los dos nodos a la vez) y anotar los tiempos reales en la tabla de ensayos de [`demo-en-vivo.md`](pitch/demo-en-vivo.md). Es lo que decide *Presentación* y *Funcionalidad* a la vez; hoy sólo se ha ensayado la parte que se puede automatizar.
2. **Grabar el video de respaldo** cuando el código esté congelado, con la última interfaz (no se versiona; no se sube a ningún servicio sin decidirlo).
3. **Abrir cada etapa del pitch con la pregunta del enunciado, una cifra y una prueba en vivo.** Así cada celda de la cuadrícula tiene su momento: las seis horas (el SOS en el simulador), el silencio (la capa y el nodo que cae) y la integración (`demo.sh`).
4. **Decidir si se cierra una brecha propia antes de exponer** (la que más se vea): que el tablero conmute solo al otro nodo cuando el que lo sirvió cae es la más directa para *Silencio digital → Factibilidad*; el agrupamiento del Reto 4 y el recall de P1 con reglas son brechas conocidas que cuestan más y que ya están dichas con cifras.
5. **No prometer lo que la evidencia no sostiene:** no decir «detecta apagones» (T20: la mitad de las zonas marcadas eran sólo calma), «agrupa duplicados» ni «probado con coordinadores».
