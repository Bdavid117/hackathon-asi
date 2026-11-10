# Plan: historia del incidente, partición larga real, tres nodos y segunda ronda del juez

> **Para quien lo ejecute:** sub-habilidad REQUERIDA: `superpowers:executing-plans` (ejecución nativa, sin subagentes salvo que el usuario los pida). Los pasos usan casillas `- [ ]`.

**Objetivo:** convertir tres «límites» del proyecto en evidencia (traza de agentes visible, partición larga y relevo con tres nodos medidos de verdad, y una segunda ronda del juez de modelo con gasto acotado) y añadir una línea de tiempo auditable por incidente.

**Arquitectura:** la traza y la auditoría son UNA proyección pura (`incident_history.dart`) que se sirve sólo en el **detalle** de un incidente: nunca en la cola ni en el resumen, para que la huella T15 no cambie. La partición larga usa pares configurados y un proxy con interruptor (no nodos sin pares). La ronda 2 del juez reutiliza `t07_modelo.dart` con un registro de gasto acumulado que se niega a lanzar si pasa el tope.

**Pila:** Dart (nodo, agentes, sim), Flutter Web (tablero), procesos reales de nodo, servidor de modelo falso (`FakeClaudeServer`), API real de Anthropic sólo en la Parte C.

**Origen:** petición del usuario (10 nov 2026): puntos 1, 2, 3 y 5 de la propuesta de mejoras, con tope de gasto de **50 USD en total** (incluido lo ya gastado). No hay documento de diseño aparte: este plan es el diseño.

## Restricciones globales

- **Español** con tildes correctas en todo texto visible, informe y commit. Identificadores de código tal cual.
- **Alcance sintético y simulado** (§4.7 del enunciado): no se proponen radio, teléfonos ni coordinadores reales como brechas. Los umbrales (95 %, 1 %, 10 min, 5/15 min, 500 m, etc.) son **del propio diseño**: nunca se atribuyen al enunciado.
- **Prueba primero** (rojo antes que verde) y **mutaciones** sobre lo nuevo (`mutate.py` del scratchpad); un mutante que sobrevive es un hueco de la prueba o un equivalente, y se dice cuál.
- **Lo que ve el coordinador es evento replicado o proyección pura**; nada cambia de tamaño o sitio con datos que llegan cada 2 s; nada de la historia entra en cola/resumen/huella (una prueba lo demuestra).
- **Mediciones:** semillas NUEVAS, criterio escrito y commiteado **antes** de ejecutar, ejecutar solo (sin carga encima), informe con lectura honesta de lo que no demuestra.
- **Gasto de API:** la clave sólo por entorno (`~/.sard-anthropic-key`), nunca impresa ni escrita. El registro de gasto es la fuente; la **consola de Anthropic manda**. Nada se gasta sin el visto bueno del usuario a la cifra de la consola y al criterio.
- **Git:** `git add` con rutas explícitas (nunca `-A`), sin `clean`, sin amend; autoría `Bdavid117 <bcollazos@unal.edu.co>`; push sólo con `bash tool/test_all.sh` completo y verde (esperar la línea `EXIT=`). `docs/pitch/video-respaldo.md` sigue sin versionar.
- **Ejecutar toda la suite del paquete tocado**, no sólo el archivo nuevo (una prueba existente se rompió así en B9).

## Qué mirar con lupa (Review Focus)

1. **Un incidente de ~500 miembros:** la historia no puede crecer sin tope (se corta en 60 pasos y dice «N de M»). Prueba en la Tarea 1.
2. **Un evento replicado desde otro nodo:** debe mostrar su nodo de origen, no el del que sirve el detalle. Tarea 1.
3. **Nodo anterior sin `history`:** el tablero sigue funcionando y no muestra un panel vacío ni lanza. Tarea 2.
4. **Una aprobación cuya recomendación ya cambió (caduca) o que sustituyó a otra:** la línea de tiempo lo dice sin inventar qué se aprobó (sólo se guarda el identificador de la versión). Tareas 1 y 2.
5. **Dos modelos falsos que contestan distinto durante la partición:** tras reconectar los dos nodos deben converger (misma huella) y los juicios duplicados se miden, no se tratan como fallo. Tarea 4.
6. **El registro de gasto frente a un tope casi agotado o a un archivo corrupto:** se niega a lanzar (falla cerrado). Tarea 6.

---

## Parte A · Historia del incidente (puntos 2 y 5)

Qué se muestra y qué NO (decisiones tomadas):
- Pasos respaldados por un evento llevan **nodo de origen y hora** (la parte física del `hlc`): recepción (`report.received`), normalización (`report.normalized`), triaje (`triage.assessed`, con su `mode` y `agent_version`), vínculo auditado (`incident.linked`), aprobaciones y declaraciones de recursos de las unidades propuestas.
- Lo que se **calcula al leer** (agrupamiento del agente 3, contradicciones, recomendación del agente 6) se rotula «derivado de estos eventos» y **no lleva hora**.
- Los agentes 4 (comunicación, en el teléfono) y 5 (resiliencia, estado de nodos) no dejan eventos por incidente: **no se les inventa fila**; el panel lo dice en una línea.
- La aprobación guarda sólo el identificador de la versión de la recomendación: la auditoría dice **quién, cuándo, estado (vigente/caduca/sustituida) y qué decisión sustituyó**, no «qué se aprobó». Se dice en el panel.
- La historia **no incluye texto de reportes** (privacidad): sólo códigos, modos, nodos, horas y nombres de quien decide.

### Tarea 1: proyección `incident_history` en el nodo

**Archivos:**
- Crear: `apps/node/lib/src/incident_history.dart`, `apps/node/test/incident_history_test.dart`
- Modificar: `apps/node/lib/src/queue_service.dart` (el camino de `detailOf` añade `history`), `apps/node/lib/sard_node.dart` (exportar)

**Interfaces — produce:**
- `class HistoryStep { String agent; String kind; String summary; String? nodeId; int? atMs; bool derived; List<String> eventIds; Map<String, Object?> toJson(); }`
- `class AuditEntry { String eventId; String who; String decision; int atMs; String status; List<String> supersedes; String? note; Map<String, Object?> toJson(); }`
- `class IncidentHistory { List<HistoryStep> steps; int stepsTotal; List<AuditEntry> audit; Map<String, Object?> toJson(); }`
- `IncidentHistory buildIncidentHistory({required List<Event> memberEvents, required List<Event> approvalEvents, required List<Event> resourceEvents, required Set<String> proposedResourceIds, required Map<String, String> approvalStatusByEventId, int maxSteps = 60})` (función pura).
- El detalle JSON gana la clave `history`; `summary`, `queue` y `incidentsPage` NO la llevan.

- [ ] **Paso 1: escribir las pruebas (rojas)**, con estos nombres y aserciones:
  - `'un paso respaldado por un evento lleva su nodo y su hora; uno derivado no lleva hora'`
  - `'el triaje del modelo se distingue del de reglas (mode rules+llm) y nombra agent_version'`
  - `'un evento replicado desde otro nodo muestra ese nodo de origen, no el que sirve el detalle'`
  - `'la auditoría dice quién, cuándo, estado y qué decisión sustituyó; vigente, caduca y sustituida se distinguen'`
  - `'una declaración de recurso de una unidad propuesta aparece; la de una unidad que no se propone no'`
  - `'un incidente de 500 miembros devuelve a lo sumo 60 pasos y stepsTotal con el total real'`
  - `'la historia no contiene el texto de ningún reporte'`
  - `'la huella T15 de la cola es idéntica con y sin historia, y summary/incidentsPage no traen la clave history'`
  - `'los pasos salen ordenados por hora y, a igual hora, por agente; el resultado no depende del orden de entrada'`
- [ ] **Paso 2: ejecutar** `cd apps/node && dart test test/incident_history_test.dart` → FALLA (falta `incident_history.dart`).
- [ ] **Paso 3: implementar** `buildIncidentHistory` y la integración en `detailOf` (los eventos de los miembros se piden al log sólo para el incidente pedido). El estado de cada aprobación se toma de lo que ya calcula `approvals.dart` (no se recalcula).
- [ ] **Paso 4: ejecutar** el archivo y luego `dart test` completo del nodo + `dart analyze` → verdes.
- [ ] **Paso 5: mutaciones** (quitar el tope de pasos, mostrar hora en un derivado, confundir el nodo de origen, incluir texto, añadir `history` al resumen): ninguna debe sobrevivir.
- [ ] **Paso 6: commit** `feat(nodo): historia del incidente (traza de agentes y auditoría) sólo en el detalle`.

### Tarea 2: panel «Historia» en el tablero

**Archivos:**
- Crear: `apps/dashboard/lib/incident_history_panel.dart`, `apps/dashboard/test/incident_history_test.dart`
- Modificar: `apps/dashboard/lib/models.dart` (`HistoryInfo.fromJson`, tolerante), `apps/dashboard/lib/detail_panel.dart` (se muestra bajo «Observaciones originales»), `apps/dashboard/test/fake_api.dart`

**Interfaces — consume:** el JSON de `history` de la Tarea 1. **Produce:** `class HistoryInfo { List<HistoryStepInfo> steps; int stepsTotal; List<AuditEntryInfo> audit; static HistoryInfo? fromJson(Object? j); }` (`null` si falta: nodo anterior) y `class IncidentHistoryPanel extends StatefulWidget` con las claves `history_panel`, `history_tab_agents`, `history_tab_audit`, `history_step_<i>`, `history_derived_note`, `history_count`.

- [ ] **Paso 1: pruebas rojas:**
  - `'nodo anterior sin history: no hay panel y el detalle sigue funcionando'`
  - `'la pestaña Agentes agrupa por agente 1–6; los derivados dicen «derivado de estos eventos» y no muestran hora'`
  - `'los agentes 4 y 5 no tienen fila y el panel lo dice en una línea'`
  - `'la pestaña Decisiones lista quién, cuándo, estado y a quién sustituyó; dice que no registra qué se aprobó'`
  - `'con stepsTotal > pasos mostrados dice «N de M»'`
  - `'a 360 px de ancho no desborda y la altura no cambia al llegar datos nuevos (el panel se pliega, no empuja la lista)'`
  - `'cada paso tiene etiqueta accesible con agente, nodo y hora'`
- [ ] **Paso 2: ejecutar** el archivo → FALLA.
- [ ] **Paso 3: implementar** modelo tolerante y panel (pestañas, plegado por defecto para no gastar altura de lectura).
- [ ] **Paso 4: ejecutar la suite COMPLETA** `cd apps/dashboard && flutter analyze && flutter test` → verde.
- [ ] **Paso 5: mutaciones** (mostrar hora en derivados, perder el «N de M», no tolerar `history` ausente, perder el nombre del nodo).
- [ ] **Paso 6: comprobación visual** con un nodo real y `seed_scenario --now --extended` (Playwright, captura en `.playwright-mcp/`); **commit** `feat(tablero): panel Historia con la traza de agentes y las decisiones`.

---

## Parte B · Partición larga real y tres nodos (punto 3)

Decisiones: `demo.dart --partition-seconds 600` **no sirve** (arranca los nodos sin pares: sólo espera). La partición real necesita **pares configurados y un enlace cortado por un proxy con interruptor**, para ejercitar los errores del replicador y el cambio de dueño por rendezvous. Con el modelo activo, durante el corte cada lado se vuelve dueño de todo y habrá juicios duplicados: **se miden, no son fallo**. Los dos scripts van aparte (informe en `docs/resultados/`), **no en `test_all`**, y se corren solos.

### Tarea 3: `PartitionProxy` en el simulador

**Archivos:** Crear `packages/sim/lib/src/partition_proxy.dart`, `packages/sim/test/partition_proxy_test.dart`; Modificar `packages/sim/lib/sard_sim.dart` (exportar).

**Interfaces — produce:** `class PartitionProxy { static Future<PartitionProxy> start({required Uri target, int port = 0}); Uri get url; bool get isCut; void cut(); void heal(); int get forwarded; int get refused; Future<void> close(); }`.

- [ ] **Paso 1: pruebas rojas** (servidor de eco local): `'cerrado el corte, reenvía método, ruta, cabeceras y cuerpo'`, `'cortado, la conexión se corta sin llegar al destino (el destino no recibe nada)'`, `'heal restablece el paso'`, `'cuenta lo reenviado y lo rechazado'`, `'close libera el puerto'`.
- [ ] **Paso 2–4:** ejecutar (rojo), implementar con `HttpServer` + `http.Client`, ejecutar la suite de `sim` completa y `dart analyze` (verde).
- [ ] **Paso 5: commit** `feat(sim): proxy con interruptor para particiones reales`.

### Tarea 4: T18 · partición larga real con dos nodos

**Archivos:** Crear `packages/sim/bin/t18_particion_larga.dart`.

**Criterios (propios; se escriben en la cabecera del script y se commitean ANTES de ejecutar):**
1. tras `heal`, las huellas de proyección de A y B coinciden en ≤ 60 s (la réplica sondea cada 3 s);
2. 0 reportes acusados se pierden (todos presentes en ambos nodos tras converger);
3. dos decisiones contradictorias tomadas cada una en su lado se conservan las dos y la discrepancia queda a la vista;
4. ningún proceso de nodo muere solo durante la partición;
5. **se miden y se informan, sin criterio:** juicios del modelo duplicados, tiempo real hasta converger, errores de réplica registrados por `/api/nodes`.

**Forma:** A y B con pares = las URL de sus proxies; modelos falsos que contestan DISTINTO (para forzar la diferencia); ráfaga con semilla; corte de `--partition-seconds` (por omisión 600); decisiones en ambos lados; `kill -9` de uno durante el corte y reinicio con su mismo disco; `heal`; esperar convergencia; informe `docs/resultados/t18-particion-larga.md` con la lectura honesta.

- [ ] **Paso 1:** escribir cabecera con criterios y flags (`--seed 42 --reports 120 --partition-seconds 600 --port-a --port-b --out`); **commit del criterio antes de ejecutar**.
- [ ] **Paso 2:** implementar el recorrido; `dart analyze` verde; un **ensayo corto** `--partition-seconds 20` debe pasar (verifica el montaje, sin valer como resultado).
- [ ] **Paso 3:** la corrida de 600 s, **sola** y con el árbol limpio; guardar el informe; **commit** `feat(sim): T18 partición larga real (10 min) con informe`.

### Tarea 5: T19 · tres nodos y relevo del modelo

**Archivos:** Crear `packages/sim/bin/t19_tres_nodos.dart`.

**Criterios (propios, commiteados antes):** 1. con tres nodos y malla completa por proxies, los tres convergen (misma huella) tras `heal` en ≤ 90 s; 2. se corta C de A y B, se mata al dueño de una parte de los reportes y **todos** los reportes con texto acaban con juicio del modelo (el relevo cambia de dueño por rendezvous); 3. 0 reportes acusados perdidos; 4. se miden sin criterio: juicios duplicados y tiempo de relevo (`--takeover 6`).

- [ ] **Paso 1–3:** cabecera + commit del criterio; implementación con la misma estructura que T18 (reutiliza lo común en `packages/sim/lib/src/`, sólo si se repite en dos sitios); ensayo corto; corrida real sola; informe `docs/resultados/t19-tres-nodos.md`; **commit** `feat(sim): T19 tres nodos, relevo del modelo y convergencia`.

---

## Parte C · Segunda ronda del juez (punto 1, con gasto acotado)

**Cuentas del gasto.** Lo registrado por el propio programa: T06 (Sonnet 1,77 + Opus 3,58), T13, humo y juez (T07 5,66 + piloto 700) ≈ **12 USD**. La consola puede diferir: **se le pide la cifra al usuario antes de gastar**. El tope total es 50 USD; este plan se **auto-limita** muy por debajo: gasto nuevo previsto ≈ 9 USD, tope de la corrida 12 USD, y el registro se niega a lanzar si lo gastado + el tope de la corrida supera **40 USD** (reserva de 10 USD, porque el tope por corrida no es estrictamente duro).

**Análisis gratuito ya hecho** (datos crudos de la ronda 1, `t07-modelo-datos.csv`, conjuntos de semilla): uniones `same` por confianza mínima: 0,80 → 257 buenas y 5 malas; 0,82 → 144 y 0; **0,85 → 143 y 0**; 0,90 → 63 y 0. Es una **hipótesis deducida de los mismos datos**, no un resultado. Consecuencias: (a) el criterio viejo «+5 puntos y el doble de recall» es **inalcanzable por aritmética** con 0,85 (≈ 56 % de la ganancia: ≈ +2 puntos); (b) el criterio de «5 fuentes» depende de un texto que el juez calificó `possible` (0,6): subir el umbral no lo arregla.

**Por eso el criterio se reescribe, y se dice:** el informe de la ronda 2 declarará que el criterio fue **reescrito tras ver la ronda 1** (evidencia más débil que la primera vez) y por qué.

**Criterio v2 (propuesta; el usuario lo aprueba antes de gastar).** Ronda: semillas **706–713** (8 nuevas), mismo tamaño por semilla que la ronda 1 (24 sucesos, 300 reportes, 6 adversariales) para poder comparar, `--min-confidence 0.85`, mismo modelo, mismo esfuerzo y **mismo mensaje** (no se toca), comparación pareada contra reglas solas sobre los mismos reportes. Se adopta sólo si se cumplen **todos**:
1. falsa fusión de pares ≤ 1 % **y** ≤ la de reglas + 0,5 puntos (agregado de las 8 semillas);
2. precisión de las uniones ≥ 95 % con **al menos 100 uniones** hechas (si hay menos, el resultado es «no concluyente», no «cumple»);
3. recall de pares ≥ el de reglas + **1,5 puntos** (sustituye a «+5 y el doble»);
4. fallos ≤ 5 % y llamadas de más de 8 s ≤ 5 %;
5. el rumor de T08 (12 copias) no gana credibilidad.
**Se retira** el criterio de «5 fuentes» (se informa como observación, no como criterio). Si el criterio 1 vuelve a fallar, **la pregunta se cierra** y no se hace una tercera ronda.

### Tarea 6: registro de gasto que falla cerrado

**Archivos:** Crear `packages/sim/lib/src/api_ledger.dart`, `packages/sim/test/api_ledger_test.dart`, `docs/resultados/gasto-api.json` (sólo importes y fechas, jamás claves); Modificar `packages/sim/bin/t07_modelo.dart` (`--ledger`, por omisión el archivo anterior), `packages/sim/lib/sard_sim.dart`.

**Interfaces — produce:** `class ApiLedger { static ApiLedger load(String path); double get spentUsd; void guard({required double runCapUsd, double totalCapUsd = 50, double reserveUsd = 10}); void record({required String run, required double usd, required String note}); void save(); }`; `guard` lanza `StateError` con el motivo si `spentUsd + runCapUsd > totalCapUsd − reserveUsd`.

- [ ] **Paso 1: pruebas rojas:** `'se niega a lanzar si lo gastado más el tope de la corrida pasa del límite menos la reserva'`, `'con un tope que cabe, deja lanzar'`, `'un archivo corrupto o ausente falla cerrado (no se asume 0)'`, `'record acumula y save/load conserva el total'`, `'el archivo no contiene nada parecido a una clave'`.
- [ ] **Paso 2–4:** ejecutar (rojo), implementar, suite de `sim` completa y analyze (verde). `t07_modelo.dart` llama a `guard` ANTES de la primera llamada y a `record` al terminar (también si la corrida se corta).
- [ ] **Paso 5:** sembrar `gasto-api.json` con las cuentas del programa (≈ 12 USD, desglosadas) y la nota «la consola manda»; **commit** `feat(sim): registro de gasto de API que falla cerrado`.

### Tarea 7: criterio v2 aplicado por código y commiteado ANTES de gastar

**Archivos:** Modificar `packages/sim/lib/src/t07_model.dart` (`decideT07V2`), `packages/sim/test/t07_model_test.dart`; Crear `docs/resultados/t07-ronda2-criterio.md` (el criterio y el análisis gratuito de arriba).

**Interfaces — produce:** `T07Verdict decideT07V2(T07Tally rules, T07Tally model)` con campos por criterio y `adopt`/`inconclusive`.

- [ ] **Paso 1: pruebas rojas** (tabla de casos con los valores exactos de arriba): `'falla si la falsa fusión supera 1 % aunque supere el recall'`, `'falla si supera a reglas en más de 0,5 puntos'`, `'no concluyente con menos de 100 uniones'`, `'recall exige +1,5 puntos sobre reglas'`, `'rumor ganando credibilidad falla'`, `'todos los criterios en el límite exacto cumplen (tolerancia de coma flotante)'`.
- [ ] **Paso 2–4:** rojo → implementar → suite completa verde.
- [ ] **Paso 5:** `dart run packages/sim/bin/t07_modelo.dart --plan --seeds 706,707,708,709,710,711,712,713 --min-confidence 0.85` (gratis); anotar las consultas y el coste estimado en `t07-ronda2-criterio.md`. **Si el coste estimado > 12 USD, parar y consultar.**
- [ ] **Paso 6: commit** `feat(sim): criterio v2 de adopción del juez, escrito antes de la ronda 2` y **anotar el hash**: la corrida sólo vale con ese hash y el árbol limpio.

### Tarea 8: la corrida (CON PERMISO) y su informe

- [ ] **Paso 0 (puerta):** el usuario da (a) la cifra de la consola y (b) el visto bueno al criterio v2. Sin ambas, **no se gasta**.
- [ ] **Paso 1:** árbol limpio, máquina sin carga; `ANTHROPIC_API_KEY="$(cat ~/.sard-anthropic-key)" dart run packages/sim/bin/t07_modelo.dart --seeds 706,707,708,709,710,711,712,713 --min-confidence 0.85 --budget-usd 12 --out docs/resultados/t07-ronda2.md`. Una sola corrida; no se repite para mejorar la cifra.
- [ ] **Paso 2:** el veredicto sale de `decideT07V2`; escribir `docs/resultados/reto4-juez.md` §«Ronda 2» con: el criterio reescrito tras ver la ronda 1, el resultado, lo que NO demuestra (mismo autor del generador y de las reglas, 8 conjuntos de 24 sucesos, una corrida, muestreo no fijable), y el gasto real contra la consola.
- [ ] **Paso 3: commit** `docs: segunda ronda del juez de modelo (resultado, lectura y gasto)`.

### Tarea 9 (CONDICIONAL: sólo si `adopt`): integrar el juez en el nodo, apagado por omisión

Cumple las tres condiciones de `reto4-juez.md`: excluir `source_class: 'radio'`; el juicio es un **evento replicado** (no se calcula al leer: rompería la huella); **veto apagado**. Flag `--link-judge on` (apagado por omisión).
- [ ] Pruebas con el modelo falso (rojas): `'un juicio válido se escribe como evento y dos nodos muestran el mismo grupo tras replicar'`, `'los informes de despachador nunca llegan al modelo'`, `'sin el flag el nodo no hace ninguna llamada'`, `'un juicio con confianza < 0,85 no une'`, `'el nodo cae al respaldo por reglas si el modelo falla'`.
- [ ] Implementar, suite del nodo completa, mutaciones, informe y **commit** `feat(nodo): juez de vínculos opcional (--link-judge), medido en la ronda 2`.
Si el veredicto es `no adopt` o `inconclusive`: **no se hace**, y se documenta como cerrado.

---

## Parte D · Cierre

### Tarea 10: documentación, capturas, batería y push

- [ ] README: filas nuevas en «Estado actual» (historia, T18, T19, ronda 2) y en la tabla de resultados; total de pruebas desde UN solo registro de `test_all.sh` (README, `repro.html` ×2, `b6-mapa.md`); quitar de «Lo que no cumplimos» lo que quede resuelto y dejar lo que no.
- [ ] PDF de arquitectura (`python3 docs/src/build.py`): §6.7 (panel Historia) y §9 (T18, T19, ronda 2); páginas nuevas en `repro.html`.
- [ ] Pitch: recapturar el tablero con el panel Historia abierto; actualizar «Lo que no cumplimos» (partición de 10 min medida o no); regenerar `SARD-pitch.pdf`; subir las imágenes nuevas al Artifact y republicar (comparar antes por sha256 el contenido vivo con HEAD).
- [ ] `bash tool/test_all.sh` completo y **verde** (esperar `EXIT=0`); **push**; actualizar la memoria del proyecto con el gasto final y lo cerrado.

---

## Orden, tiempo y riesgos

| Parte | Qué | Tiempo estimado | Gasto |
|---|---|---|---|
| A | Historia (nodo + tablero) | 3–4 h | 0 |
| B | Proxy, T18 (corrida ≈ 15 min), T19 (≈ 10 min) | 3–4 h | 0 |
| C | Registro, criterio v2, ronda 2 (≈ 25 min de corrida) | 2–3 h | ≈ 9 USD (tope 12; total ≈ 21–24 de 50) |
| D | Cierre, batería (≈ 6 min), push | 1–2 h | 0 |

Riesgos: (1) T18/T19 pueden destapar un defecto real de convergencia: si pasa, **se informa y se corrige con prueba primero**, no se afloja el criterio; (2) la ronda 2 puede salir «no concluyente» o `no adopt`: es un resultado válido y cierra la pregunta; (3) el léxico de paráfrasis **se descarta**: el generador y el léxico comparten autor y cualquier mejora medida sobre `synth.dart` sería circular (sólo valdría contra un conjunto escrito a mano y congelado antes).

## Autorevisión

- **Cobertura:** punto 2 (Tareas 1–2), punto 5 (auditoría dentro de las Tareas 1–2), punto 3 (3–5), punto 1 (6–9). Sin tarea huérfana.
- **Consistencia de nombres:** `buildIncidentHistory`/`IncidentHistory`/`HistoryStep`/`AuditEntry` (nodo) ↔ `HistoryInfo`/`HistoryStepInfo`/`AuditEntryInfo` (tablero); `PartitionProxy.cut/heal`; `ApiLedger.guard/record`; `decideT07V2`.
- **Proporción:** tareas como firmas, nombres de prueba y comandos; sin cuerpos de código.
