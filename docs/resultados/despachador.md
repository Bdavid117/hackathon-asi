# Canal del despachador (T16) · informe de lo construido y de sus límites

El Escenario 2 del enunciado habla de despachadores que «reciben ráfagas de datos fragmentados, rumores capturados por radio de onda corta y mensajes a medio terminar». Hasta aquí el nodo sólo aceptaba tramas binarias de la app. Este canal deja que **una persona registre en el tablero lo que oyó** (por radio, por teléfono o en persona) y que ese informe recorra el mismo camino que un aviso de la app: triaje, agrupamiento, cola, réplica y aprobación.

> **Lo que no hay que leer de más.** Esto **no resuelve el Reto 4**: cinco orígenes que describen el mismo suceso con otras palabras siguen sin agruparse (T08 de punta a punta, `b3.md`). Sólo se mide que la maquinaria acepta, conserva y muestra esos informes y que **no amplifica un rumor**: el mismo texto de varios orígenes cuenta como una sola fuente. No se probó con despachadores reales ni con radio real; un informe lo teclea una persona.

## 1. Qué se construyó

| Pieza | Dónde |
|---|---|
| `POST /api/dispatch` (sólo JSON, ≤ 8 KiB), validación estricta y registro idempotente | `apps/node/lib/src/dispatch.dart`, `api.dart` |
| El informe es un `report.received` con `channel: dispatcher`, `source_class: radio`, `medium`, `origin`, `registered_by`, sin ubicación | `dispatch.dart` |
| La fuente (`app` / `radio`) sale del evento y llega al agente 3 y al JSON de la cola | `merged_reports.dart`, `queue_view.dart` |
| El texto de este canal **no** se envía al modelo de lenguaje | `pipeline.dart` (`_sinModelo`) |
| El arranque del nodo ya no depende de que todo `report.received` traiga `frame_seq` | `ingest.dart` |
| «Registrar informe» en el tablero: formulario, cliente HTTP, observación de segunda mano | `apps/dashboard/lib/dispatch_dialog.dart`, `api.dart`, `detail_panel.dart` |
| Comprobación con tres nodos reales | `tool/dispatch_check.sh` (dentro de `tool/test_all.sh`) |

**El cuerpo** (`test/fixtures/dispatch_request.json`, el mismo literal que leen la prueba del nodo y la del tablero):

```json
{ "id": "a1b2c3d4e5f6a7b8", "text": "edificio con gente atrapada en la carrera 23", "medium": "telefono",
  "origin": "Estación Bomberos 3", "who": "Ana Gómez", "flags": ["atrapado", "herido"], "people": 2 }
```

`id` lo genera el tablero (8–64 caracteres): reintentar con el mismo id y el mismo contenido **no duplica** (200 con `duplicate: true`); el mismo id con **otro** contenido es un **409** (no se descarta en silencio). `text` ≤ 500 caracteres (no bytes); `who` ≤ 80; `flags` por nombre (los mismos códigos que cita el triaje); `people` es el código de `PeopleBucket`. Cualquier campo desconocido se rechaza (400) y la respuesta dice cuál.

## 2. Decisiones que tomé yo (revertibles)

1. **Una sola clase de fuente, `radio`**, para los tres medios (radio, teléfono, en persona). Su credibilidad base es la que ya existía (0,2) y **sigue sin calibrarse con datos reales**. El medio sólo es una etiqueta para quien lee.
2. **La independencia la da el origen declarado, no quien teclea**: `device_id = radio:<origen>` (minúsculas, espacios→guion, sin signos; **no se quitan los acentos**). Dos informes del mismo origen son una fuente; sin origen, todos comparten «sin origen» (se subestima la independencia, no se amplifica un rumor). Límite: «Estación 3» y «E3» son orígenes distintos aunque sean la misma persona.
3. **Sin ubicación y sin campo para ella.** El agente 1 no la inventa. Consecuencia real, visible en el tablero: un informe P1 por radio muestra «**Todavía no se puede recomendar: falta saber la ubicación**»; el coordinador debe confirmarla por otra vía. No hay geocodificación de «carrera 23 con calle 10».
4. **La hora es la del nodo al registrar**, no la de cuando se oyó. El tablero lo dice («registrado 15:19»).
5. **El texto de este canal no va al modelo** aunque se arranque con `--llm on`: por radio es más probable que traiga nombres, teléfonos y direcciones que la frase de 140 B de la app, y hoy no se redacta nada (ver PDF §8). Tampoco ocupa un hueco de consulta: una ráfaga de informes no deja sin hueco a la app.
6. **Banderas y personas opcionales con el mismo significado que en la app.** Con sólo texto el recall de P1 por reglas es 53,4 % (`b3.md`); con banderas marcadas por quien registra es 100 %. Radio es donde el triaje por texto es más débil.
7. **Sin límite de tasa propio.** Sin `--coordinator-token` cualquiera que llegue por red puede registrar un informe (igual que una aprobación); con él se exige el código del coordinador. Ese código **no identifica a quien registra**: `who` es declarado.

## 3. Qué se verificó

| Qué | Resultado |
|---|---|
| Pruebas nuevas del nodo | **85** (323 → 408): validación (≈ 40 entradas malas), registro, idempotencia, conflicto, cuerpo con todas las claves de una trama real, cola, independencia, JSON, ruta (415/413/400/401/409), `ETag`, réplica, reinicio, modelo |
| Pruebas nuevas del tablero | **36** (138 → 174): modelo, **contrato HTTP contra el mismo literal que lee el nodo**, formulario, ids de reintento, doble toque, anchos 320–1 280 px, observación, evidencia |
| Mutaciones | **44** cambios deliberados al código (27 en el nodo, 17 en el tablero): todos acabaron detectados por alguna prueba. **3 sobrevivieron al primer intento** y obligaron a añadir pruebas (el informe no debe ocupar un hueco del modelo; la caché debe invalidarse sin pipeline; el botón debe cambiar de forma según el ancho) |
| `tool/dispatch_check.sh` | Con **tres nodos reales** (procesos, HTTP, disco): registro, reintento sin escribir, 409, 415/400/413 sin escribir, convivencia con tramas de la app, **`kill -9` y reinicio**, códigos de acceso, réplica a otro nodo y reinicio de éste. **Quitando la defensa del arranque el script falla** («el nodo A no arrancó»: `Null check` en `ingest.dart`) |
| Tablero real en Chrome | Se abrió el tablero compilado, se pulsó «Registrar informe», se llenó (teléfono, texto, origen, atrapado, herido, 2–5, nombre) y se envió: el nodo lo aceptó, lo mostró como incidente **P1**, fuente `radio`, medio `telefono`, 1 fuente, confianza 0,2, «Fuente única» y «Sin ubicación» (`/api/incidents`) |
| `bash tool/test_all.sh` | 1 287 casos en verde (124 + 89 + 267 + 98 + 408 + 127 + 174), análisis limpio, H1 ×2, demostración adversa, T12, ráfaga, T14, tablero web, códigos de acceso e informe de despachador |

### Un defecto que este trabajo habría introducido

Un informe no tiene `frame_seq` ni `device_id` de dispositivo, y el constructor de `Ingest` leía ambos con `!`: **registrar un solo informe y reiniciar dejaba el nodo muerto**. Se escribió primero la prueba en rojo (en sus dos variantes: evento propio y evento replicado) y la defensa es **estructural** (la forma del cuerpo), no por canal. Otro lector del evento, cualquiera, tolera ya un cuerpo con otra forma (hay una prueba que compara las claves con las de una trama real).

## 4. Lo que NO se logró o no se probó

- **No se probó con despachadores ni con radio real.** Un informe lo teclea una persona; no hay captura de audio, ni transcripción, ni integración con una radio.
- **No agrupa lo que no se parece.** Cinco orígenes que cuentan el mismo suceso con palabras distintas forman cinco incidentes. Sólo el mismo texto (copias) se funde y se cuenta como una fuente.
- **La credibilidad 0,2 de `radio` es un supuesto**, no un dato.
- **Sin ubicación no hay recomendación** (agente 6): el informe llega a la cola, con su urgencia, pero el coordinador debe resolver el dónde.
- **«Mensaje a medio terminar»** no tiene una marca propia: quien registra puede escribirlo en el texto, pero el sistema no lo detecta ni lo señala como incertidumbre.
- **La fila de la lista no dice de dónde viene un incidente**; sólo el detalle lo hace.
- **Quien registra no está autenticado** (`who` es declarado; el código de acceso no es identidad) y no hay límite de tasa ni de tamaño por persona.

## 5. Cómo reproducirlo

```bash
cd apps/node && dart test test/dispatch_test.dart test/dispatch_queue_test.dart test/dispatch_api_test.dart test/dispatch_startup_test.dart
cd apps/dashboard && flutter test test/dispatch_test.dart
bash tool/dispatch_check.sh      # tres nodos reales, puertos 8194–8196

# A mano: un nodo con el tablero, y «Registrar informe» arriba a la derecha
(cd apps/dashboard && flutter build web --no-web-resources-cdn)
(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --web-root ../dashboard/build/web --resources ../../config/recursos.json)
curl -s -X POST -H 'content-type: application/json' localhost:8081/api/dispatch \
  -d '{"id":"prueba-0001-abcd","text":"hay gente atrapada en el segundo piso","medium":"radio","origin":"Estación 3","who":"Ana","flags":["atrapado"]}'
```
