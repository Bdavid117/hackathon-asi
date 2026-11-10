# hackathon-asi · SARD

Repositorio del proyecto para la **Hackathon SARD** (Sistema Agéntico de Respuesta y Resiliencia ante Desastres), Expo ASI 2026, Universidad Nacional de Colombia | Sede Manizales.

El enunciado oficial es [`HackathonExpoASI2026.pdf`](HackathonExpoASI2026.pdf). Lo que se evalúa es un **recorrido completo de ocho pasos** (reporte ciudadano → almacenamiento local → transmisión intermitente → procesamiento por agentes → priorización → tablero → pérdida de un nodo → recuperación), no una pantalla aislada.

> **Alcance de la demostración.** El enunciado lo permite en su §4.7: «El recorrido puede ejecutarse con datos sintéticos y canales simulados. No se exige desplegar una red de radio real ni contar con acceso a infraestructura gubernamental.» Por eso todo lo de este repositorio usa datos sintéticos y canales simulados, y el objetivo 10 pide justamente «pruebas reproducibles de desconexión, pérdida de paquetes y recuperación». El emulador de Android y el simulador de iOS son una decisión del equipo (el enunciado no fija plataforma). **Dos cosas que NO vienen del enunciado:** (1) el enunciado no trae rúbrica, pesos ni metas numéricas; (2) los umbrales que aparecen aquí —recall de P1 ≥ 95 %, falsa fusión ≤ 1 %, particiones de 10 min, «ningún P1 fuera de la vista»— son metas del **propio diseño** (cap. 9 del PDF de arquitectura). Incumplir una meta propia se reporta, pero no es incumplir el enunciado.

## Estado actual

**B0 a B5 implementados y medidos.** B4 y B5 —la app captura personas y frase; el nodo calcula incidentes con la recomendación del agente 6 y la aprobación registrada; el tablero del coordinador; el reparto del trabajo caro entre nodos; la ráfaga de 10 000 reportes y la demostración con una condición adversa— están en [`docs/resultados/b5.md`](docs/resultados/b5.md) (decisiones y mutaciones en [`b5-decisiones.md`](docs/resultados/b5-decisiones.md)). **Lo que NO se logró o no se probó** (límites de validez; que los datos sean sintéticos y los canales simulados no cuenta como uno, porque el enunciado lo permite): el modelo de lenguaje se consultó de verdad sólo en T06 y T13 con modelo y en una prueba del nodo (datos sintéticos, una corrida; T12 y la ráfaga siguen con un servidor falso); el agrupamiento casi no fusiona, así que la ventaja del tablero es de orden y no de agrupación; no hubo prueba con coordinadores; las particiones de `demo.sh` fueron de 5–20 s (después T18 midió una de 10 min con dos nodos y T19 un aislamiento de 30 s con tres, en una sola máquina y con modelos falsos); quien aprueba no está autenticado y la clave de integridad es compartida. ⚠️ En B3, **dos de los tres criterios medidos —propios del diseño— no se cumplen** (T06 recall de P1 78,5 % frente a la meta propia de 95 %; T07 sólo cumple «falsa fusión ≤ 1 %» en conjunto y porque casi no agrupa: una de cinco semillas nuevas llega a 2,9 %) y se reportan así, con su diagnóstico, en [`docs/resultados/b3.md`](docs/resultados/b3.md). Los datos son sintéticos y los genera el mismo autor que las reglas, así que las cifras miden coherencia interna y no desempeño en campo. **`--llm on` envía el texto libre de los ciudadanos a un tercero sin redactar datos personales** (apagado por defecto; ver PDF §8). Desarrolla una sola persona, con Flutter: **Dart de punta a punta**. Un reporte recorre los ocho pasos del enunciado y la app se comporta bien en sus condiciones: **se guarda sin red y sale solo al volver la señal** (en el emulador de Android: 1 s tras devolver la red), lee el **GPS y la batería por las API del sistema** (en el emulador, simulados desde su consola; ubicación como revisión del mismo reporte; modos normal, ahorro y sólo SOS) y reparte el envío con **envejecimiento y cuota anti-inanición**.

- **2 069 pruebas automáticas** (el protocolo se cuenta en VM y en Chrome) en verde (`bash tool/test_all.sh`) más pruebas de integración en el emulador de Android y el simulador de iOS (`tool/device_check.sh`, `tool/android_offline_check.sh`, `tool/android_battery_check.sh`).
- **Canal del despachador (T16):** en el tablero, «Registrar informe» deja que una persona registre lo que oyó por radio, teléfono o en persona (`POST /api/dispatch`). Entra como información **de segunda mano**: una fuente, confianza 0,2 (supuesta), **sin ubicación** (el agente 6 no recomienda hasta saber el dónde), idempotente, replicable, y su texto **no** se envía al modelo. **No resuelve el Reto 4** (otros orígenes con otras palabras siguen sin agruparse) ni se probó con despachadores reales: [`docs/resultados/despachador.md`](docs/resultados/despachador.md), `bash tool/dispatch_check.sh` (tres nodos reales).
- **Reto 4 con un juez de modelo de lenguaje: medido en dos rondas y NO adoptado.** Se construyó (`packages/agents/lib/src/link_judge.dart`) y se midió contra la API real con semillas nuevas, con el criterio fijado y commiteado antes de gastar. **Ronda 1:** Resultado: une más reportes del mismo suceso (recall de pares 0,8 % → 4,4 %; 97,7 % de las uniones del modelo acertadas; en la corroboración de 5 fuentes reúne 4 y la confianza sube de 0,60 a 0,97), pero la falsa fusión sube de 1,22 % a 2,21 % (los errores son gemelos adversariales a confianza 0,80) y aplicado el criterio **no se ofrece en el nodo**: [`docs/resultados/reto4-juez.md`](docs/resultados/reto4-juez.md). Las 5 fuentes independientes siguen sin formar un grupo completo; el nodo no llama al juez. **Ronda 2** (viñeta de abajo): tampoco se adopta.
- **Repositorio público (entregable 2):** [github.com/Bdavid117/hackathon-asi](https://github.com/Bdavid117/hackathon-asi). Verificado el 10 nov 2026 sin credenciales: la web y la API lo ven público, un clon anónimo funciona y desde ese clon `dart pub get` y las pruebas del paquete `protocol` pasan. Antes de publicarlo se buscaron secretos en los 74 commits (patrones de claves y el valor exacto de la clave de la API usada en las mediciones): no aparecen.
- **Tablero: mapa de incidentes (B6, 10 nov 2026).** Selector Lista | Mapa en la barra superior: un esquema sin Internet (cuadrícula y barra de escala) con un marcador por incidente localizado, un anillo con la precisión de la ubicación cuando es mayor que el marcador, grupos con conteo cuando dos incidentes caen en el mismo sitio (el más urgente encima: un P1 no queda tapado), lo que no tiene ubicación listado aparte y lo que queda fuera de la vista avisado. El encuadre **no se mueve solo** con los datos que llegan cada 2 s; «Reencuadrar» es a petición. Informe, mutaciones y límites: [`docs/resultados/b6-mapa.md`](docs/resultados/b6-mapa.md).
- **Tablero: cola de decisiones, filtros y novedades (B6, resto).** «Pendientes de decisión» cuenta sobre el total del nodo y dice desde cuándo espera la más antigua; una propuesta P1 sin decidir pasados 5 min (P2, 15) lo dice en su tarjeta (plazos **propios** del diseño, no del enunciado). Los filtros y la búsqueda actúan sobre lo cargado y no esconden nada sin decirlo (cuentan lo oculto y cuántos son P1). Las novedades se avisan sin reordenar ni cambiar el tamaño de nada.
- **Contradicciones y mensajes cortados (B8).** El agente 3 detecta, sin modelo, dos clases de contradicción entre reportes distintos (negación explícita de algo que otro afirma, y cantidades de personas incompatibles); el tablero las muestra, las cuenta y las filtra, pero **no las resuelve** ni cambia la urgencia. T17, con el criterio fijado antes de medir: 100 % de 97 inyectadas, **0 falsos positivos** en 500 grupos y 267 señuelos; es un resultado modesto y [`t17-contradicciones.md`](docs/resultados/t17-contradicciones.md) dice por qué. Un texto que termina en «y», en coma o en puntos suspensivos se marca «posible mensaje cortado» (informativo). El informe del despachador puede llevar una ubicación escrita a mano.
- **Recursos en vivo y restricción de ruta (B7).** Una unidad se declara o redeclara mientras el sistema corre (`POST /api/resources`): es un evento replicado, y si dos nodos aislados declaran cosas distintas hay un **conflicto** y la unidad no se ofrece hasta que una persona elija. Si la unidad propuesta deja de estar disponible, la aprobación vigente **caduca**. Una vía bloqueada reportada por otro incidente a ≤ 500 m del trayecto (radio **propio**) añade «confirmar la ruta» a lo que falta antes de aprobar; sólo avisa. El tablero tiene un panel «Recursos» y una capa de unidades en el mapa. `tool/resources_check.sh` lo prueba con dos nodos reales.
- **Identidad del aprobador (B7), opcional.** Con `--coordinator-codes "Ana=código,Luis=código"` cada código tiene dueño: aprobar, registrar un informe y declarar un recurso se hace a nombre de quien presenta el código, y el de Luis no puede firmar como Ana (403, sin registrar nada; `tool/access_check.sh`). Es «identificado por código», **no «autenticado»**: no hay TLS, no hay límite de intentos y los nodos pares replican el evento sin volver a comprobar el nombre. Sin la opción, todo funciona como antes.
- **Historia del incidente (traza de agentes y auditoría).** Al final del detalle y plegado, un panel «Historia» con dos pestañas: **Agentes** (qué hizo cada uno; los pasos respaldados por un evento dicen nodo y hora, los que se calculan al leer se rotulan «derivado» y no llevan hora; los agentes 4 y 5 no dejan eventos por incidente y no tienen fila) y **Decisiones** (quién, cuándo, estado —vigente, caduca, sustituida— y a quién sustituyó; el registro no guarda *qué* se aprobó, y el panel lo dice). Sólo el detalle la sirve: la cola, la lista y el resumen no, así que la huella no cambia. Nunca lleva el texto de un reporte. Lee los eventos de **a lo sumo 1 000 miembros** (medido: 64 ms con 2 000 y 316 ms con 10 000 por petición, en el hilo que también acusa reportes; con el tope, 34 ms) y la pestaña de agentes avisa «se leyeron los primeros N de M reportes» cuando recorta.
- **Partición larga real y tres nodos (T18, T19).** Con un proxy con interruptor (pares configurados, enlace cortado de verdad; `demo.sh` arranca sin pares y por eso no ejercita esto): [T18](docs/resultados/t18-particion-larga.md) corta 10 minutos con dos nodos —modelos falsos que contestan distinto, dos decisiones contradictorias y un `kill -9`—: 170 reportes acusados y 170 en cada cola, convergencia en 2,5 s. [T19](docs/resultados/t19-tres-nodos.md) mide con tres nodos el relevo del modelo tras matar a uno y la convergencia al reunirse: **dos corridas, las dos cumplen los cinco criterios** (relevo de 30 de 30 en 8,1 y en 10,3 s; convergencia en 2,9 y en 4,4 s; en la 2.ª se midió directamente que 13 de los 30 eran de C y los 13 los relevó A o B), pero el **cómputo duplicado salió 17 en una y 0 en otra** —sin explicar—, así que no se cita como valor. Todo en una máquina y con modelos falsos; criterios propios, commiteados antes de correr.
- **Panel «Situación» y demostración en vivo.** A la derecha del tablero, mientras no hay un incidente elegido, un panel con lo que el tablero ya sabe: la **red de nodos** (cada par con su estado en palabras, su color, cuánto hace que se le vio y cuántos eventos le faltan; sin pares dice que el nodo trabaja solo; el error crudo de un par se resume —«conexión rechazada»— y el texto completo queda en un tooltip), los **recursos** y tres principios para leer el tablero. Para exponer: `bash tool/expo.sh` levanta **dos nodos que se replican** con un escenario **sintético** de seis horas de historia (seis zonas de Manizales, cuatro en silencio) sembrado por la misma ruta que un reporte real pero con horas pasadas, y `bash tool/expo_ctl.sh kill A|start A` mata un nodo con `kill -9` de verdad y lo reanima con su disco (≈ 3 s). Todo, con tiempos medidos y plan B, en [`docs/pitch/demo-en-vivo.md`](docs/pitch/demo-en-vivo.md). **Sin ensayar a mano:** el toque en SOS del simulador (un script no puede pulsarlo) y los tiempos con la carga real de la exposición.
- **T20 · la capa «Silencio» medida contra una verdad aparte** ([`t20-silencio.md`](docs/resultados/t20-silencio.md); hipótesis commiteadas antes de correr): con zonas sintéticas que reportan como un proceso de Poisson y un 30 % que sufre un apagón (tasa al 5 %), el detector real marca **621 zonas y acierta 303 (precisión 48,8 %, exhaustividad 89,1 %)**; en zonas poco habladoras la precisión baja a 29,3 % (78,5 % de las zonas normales se marcan) y con λ ≥ 4 reportes/h sube a 90,1 %. La ventana de 30 min es un **compromiso** (15→120 min: precisión 42→71 %, exhaustividad 96→58 %). **H4 no se cumple** (64,5 % de los apagones de menos de 30 min se marcan porque ya estaban calladas; diagnóstico añadido después y rotulado). Modelo sencillo del mismo autor (Poisson, tasa residual fija), sin prueba con coordinadores.
- **Capa «Silencio» del mapa (las zonas que reportaron y callaron).** Un interruptor marca las celdas de ≈ 550 m donde llegaron reportes con ubicación en las últimas 6 h y ninguno en los últimos 30 min (`GET /api/coverage`, aparte de la cola y **fuera de la huella**; apagada por omisión y apagada no cuesta red). **El silencio no es seguridad:** no predice nada, no dice que una zona sin marca esté a salvo y no sabe por qué calló; el rótulo empieza por esa advertencia, cuenta lo que no entra (reportes sin ubicación, zonas fuera de la vista) y, si el nodo es anterior o falla, lo dice sin afirmar ningún recuento. Una primera versión con el rótulo sobre el mapa **tapaba un incidente** en una captura contra un nodo real: pasó a una franja fuera del lienzo. Ventanas y rejilla son elecciones propias (no del enunciado) y **no se midió con personas**. [`cobertura.md`](docs/resultados/cobertura.md)
- **Segunda ronda del juez de modelo: medida y tampoco se adopta.** Con semillas nuevas 706–713 y confianza mínima 0,85, y un criterio **reescrito tras ver la ronda 1** (evidencia más débil, y se dice; [`t07-ronda2-criterio.md`](docs/resultados/t07-ronda2-criterio.md), commiteado antes de gastar): recall de pares 0,48 → 1,99 % (+1,51 puntos), 175 de 178 uniones acertadas (98,3 %), pero la falsa fusión sube de 0,00 a 0,92 %: bajo el 1 % absoluto y **fuera de la cláusula «≤ reglas + 0,5 puntos»**. Aplicado por código, no se adopta y **la pregunta se cierra** (no hay tercera ronda). La hipótesis de que 0,85 dejaría fuera a los gemelos adversariales no se confirmó: los 3 errores tienen justo 0,85. 9,54 USD; registro de gasto que falla cerrado ([`gasto-api.json`](docs/resultados/gasto-api.json): la consola de Anthropic manda y no se ha conciliado). Informe: [`t07-ronda2.md`](docs/resultados/t07-ronda2.md), lectura en [`reto4-juez.md`](docs/resultados/reto4-juez.md).
- **Plataforma y alcance:** emulador de Android y simulador de iOS, datos sintéticos y canales simulados (lo que permite el §4.7). No se usó hardware ni radio reales, que el enunciado no exige; el APK de `dist/` no se ha instalado en un teléfono.

| Qué | Dónde |
|---|---|
| Diseño: análisis del enunciado, arquitectura, protocolo, agentes, pruebas y plan (v0.2) | [`docs/SARD-arquitectura-app-movil.pdf`](docs/SARD-arquitectura-app-movil.pdf) |
| Decisión: desarrollo individual, Dart de punta a punta y corte de alcance | [`docs/adr/0001-desarrollo-individual-dart.md`](docs/adr/0001-desarrollo-individual-dart.md) |
| Resultados: H1 (recorrido de punta a punta) | [`docs/resultados/h1.md`](docs/resultados/h1.md) |
| Resultados: transporte T02–T04 en tiempo virtual | [`docs/resultados/b2.md`](docs/resultados/b2.md) |
| Resultados: verificación en dispositivo | [`docs/resultados/b2-dispositivo.md`](docs/resultados/b2-dispositivo.md) |
| Resultados: agentes y deduplicación (B3) | [`docs/resultados/b3.md`](docs/resultados/b3.md) |
| Resultados: B4+B5 (T01, T09–T15), decisiones y límites | [`docs/resultados/b5.md`](docs/resultados/b5.md) · [`b5-decisiones.md`](docs/resultados/b5-decisiones.md) · [`t12.md`](docs/resultados/t12.md) · [`t14.md`](docs/resultados/t14.md) · [`b5-rafaga.md`](docs/resultados/b5-rafaga.md) |
| Resultados: **mapa del tablero (B6)**: reglas, mutaciones, defectos hallados, rendimiento y límites | [`docs/resultados/b6-mapa.md`](docs/resultados/b6-mapa.md) |
| Resultados: canal del despachador (T16), decisiones y límites | [`docs/resultados/despachador.md`](docs/resultados/despachador.md) |
| Resultados: **la capa «Silencio»** (qué hace) y **T20** (cuánto confunde calma con apagón) | [`docs/resultados/cobertura.md`](docs/resultados/cobertura.md) · [`t20-silencio.md`](docs/resultados/t20-silencio.md) |
| Resultados: **partición larga real (T18)** y **tres nodos (T19)** | [`docs/resultados/t18-particion-larga.md`](docs/resultados/t18-particion-larga.md) · [`t19-tres-nodos.md`](docs/resultados/t19-tres-nodos.md) |
| **Juez de modelo, ronda 2**: criterio escrito antes de gastar y gasto acumulado | [`docs/resultados/t07-ronda2-criterio.md`](docs/resultados/t07-ronda2-criterio.md) · [`gasto-api.json`](docs/resultados/gasto-api.json) |
| **El modelo de lenguaje REAL**: T06 con modelo (Sonnet 5.5 y Opus 5.5, 750 reportes), T13 con modelo y la prueba del nodo; lectura, gasto y límites | [`docs/resultados/modelo-real.md`](docs/resultados/modelo-real.md) · [`t06-modelo.md`](docs/resultados/t06-modelo.md) · [`t06-modelo-opus.md`](docs/resultados/t06-modelo-opus.md) · [`t13-sonnet-5-5.md`](docs/resultados/t13-sonnet-5-5.md) |
| **Reto 4 con juez de modelo** (medido, no adoptado): protocolo, resultado, veredicto del criterio y por qué falló | [`docs/resultados/reto4-juez.md`](docs/resultados/reto4-juez.md) · [`t07-modelo.md`](docs/resultados/t07-modelo.md) |
| **Demostración en vivo, reproducible**: qué teclear, qué debe verse, tiempos medidos y plan B | [`docs/pitch/demo-en-vivo.md`](docs/pitch/demo-en-vivo.md) |
| **La planilla de evaluación y la evidencia de cada celda** (con brechas, sin puntajes) | [`docs/evaluacion.md`](docs/evaluacion.md) |
| Guion de la demostración y del pitch | [`docs/pitch/guion.md`](docs/pitch/guion.md) |
| Presentación del pitch (18 láminas, con capturas reales; fuentes en `docs/pitch/deck/`, se regenera con `python3 -I docs/pitch/build_pdf.py --pdf docs/pitch/SARD-pitch.pdf`) | [`docs/pitch/SARD-pitch.pdf`](docs/pitch/SARD-pitch.pdf) |
| **Video de presentación (52 s)** con tomas reales de la app y del tablero, voz del sistema y rótulos; **el `.mp4` no se versiona**: se reconstruye con `docs/pitch/video/build_video.py` | [`docs/pitch/video/README.md`](docs/pitch/video/README.md) |
| Oráculo del códec (genera los vectores de prueba) | [`docs/src/tools/frame_size.py`](docs/src/tools/frame_size.py) |

## Los siete entregables

El enunciado (tabla 4, §6) pide siete. Dónde está cada uno y cómo comprobarlo:

| N.º | Entregable | Dónde está | Cómo comprobarlo |
|---|---|---|---|
| 1 | Prototipo funcional | La app ciudadana ([`apps/mobile`](apps/mobile)), el nodo superviviente ([`apps/node`](apps/node)) y el tablero del coordinador ([`apps/dashboard`](apps/dashboard)) | `PART=20 bash tool/demo.sh 42` (recorrido de punta a punta con una condición adversa) o «Un nodo con el tablero» en [Comandos](#comandos) |
| 2 | Código fuente | Este repositorio, público: [github.com/Bdavid117/hackathon-asi](https://github.com/Bdavid117/hackathon-asi). Instalación y versiones en [Entorno de desarrollo](#entorno-de-desarrollo) | `dart pub get` y `bash tool/test_all.sh` |
| 3 | Documento de arquitectura | [`docs/SARD-arquitectura-app-movil.pdf`](docs/SARD-arquitectura-app-movil.pdf): componentes y recorrido (cap. 3), app (cap. 5), nodos, sincronización, tejido de agentes, almacenamiento y tablero (cap. 6), dependencias (§3.4) | Se regenera con `python3 docs/src/build.py` |
| 4 | Fichas de agentes | El mismo PDF, §6.4: una ficha por agente con los ocho campos (objetivo, entradas, salidas, herramientas, memoria, límites de autonomía, manejo de errores y terminación) | El código de cada agente es una función pura en [`packages/agents`](packages/agents) |
| 5 | Protocolo de comunicación | El mismo PDF, cap. 7: formato de la trama (§7.2), confirmaciones, reintentos y fragmentación (§7.4, con el riesgo de aplazar un mensaje), deduplicación (§7.5), seguridad (§7.6) y canal del despachador (§7.8); la sincronización entre nodos, en §6.2 | El códec está en [`packages/protocol`](packages/protocol) y se prueba con vectores generados por un oráculo en Python ([`docs/src/tools/frame_size.py`](docs/src/tools/frame_size.py)) |
| 6 | Resultados de pruebas | [`docs/resultados/`](docs/resultados): métricas, escenarios, errores observados, límites y pruebas de estrés (ráfaga de 10 000 reportes en [`b5-rafaga.md`](docs/resultados/b5-rafaga.md)). Resumen de método en el PDF, cap. 9 | `bash tool/test_all.sh` (≈ 6 min) y los scripts de `packages/sim/bin/` |
| 7 | Pitch y demostración | [`docs/pitch/SARD-pitch.pdf`](docs/pitch/SARD-pitch.pdf) y el guion [`docs/pitch/guion.md`](docs/pitch/guion.md) | `PART=20 bash tool/demo.sh 42`: dos nodos reales, partición, `kill -9`, reconexión y la misma huella en dos ejecuciones; y **en vivo** `bash tool/expo.sh` (dos nodos con seis horas de historia sintética) + [`demo-en-vivo.md`](docs/pitch/demo-en-vivo.md) |

## Estructura

```
packages/protocol/     códec binario, ACK selectivo, Channel (Dart puro)
packages/client_core/  bandeja durable con aging y cuota, planificador, modos de energía, ubicación, PumpTrigger (Dart puro)
packages/agents/       triaje, correlación, agente 6 (recomendación y su validador), rendezvous (Dart puro)
packages/sim/          canales con pérdida, tiempo virtual, nodo falso, modelo falso, escenarios T02–T04, H1, ráfaga T11, T12, T14 y la demostración (Dart puro)
apps/node/             nodo: log de eventos, ingreso, incidentes, aprobaciones, API HTTP, replicación, reparto por rendezvous
config/recursos.json   recursos declarados SINTÉTICOS que el agente 6 puede nombrar
apps/mobile/           app ciudadana (Flutter)
apps/dashboard/        tablero del coordinador (Flutter Web)
spikes/sqlite_kill/    prueba técnica: SQLite ante kill -9
tool/test_all.sh       toda la batería de pruebas (≈ 6 min)
tool/demo.sh           demostración adversa reproducible (partición, kill -9, decisiones contradictorias, misma semilla ⇒ misma huella)
tool/web_smoke.sh      el tablero compilado, abierto en Chrome sin cabeza
tool/build_apk.sh      APK de release de la app ciudadana en dist/ (`bash tool/build_apk.sh` para el celular con la IP de esta Mac; `emulador` para el emulador)
tool/dispatch_check.sh el canal del despachador con tres nodos reales (registro, reintento, kill -9, códigos, réplica)
tool/resources_check.sh los recursos declarados con dos nodos reales (partición, kill -9, conflicto y su resolución)
tool/access_check.sh   los códigos de acceso con cuatro nodos reales (coordinador, réplica e identidad por código)
packages/sim/bin/llm_smoke.dart · t06_model.dart · t13_modelo.dart   el modelo REAL (necesitan ANTHROPIC_API_KEY en el entorno; ver docs/resultados/modelo-real.md)
tool/device_check.sh   pruebas de integración en Android o iOS contra un nodo real
tool/android_*_check.sh  sin red → sale solo; batería real → modos
```

## Reproducir los resultados

Todo lo que dice este repositorio sale de un comando de esta sección. **Casi todo corre sin conexión, sin claves y sin gastar nada**; la única excepción son las mediciones con el modelo de lenguaje real (§4). Los tiempos se midieron el 10 de noviembre de 2026 en una Mac (Apple silicon) con la máquina en reposo; con carga pueden variar.

### 0 · Requisitos

| Para | Qué hace falta |
|---|---|
| Todo | **Flutter 3.41.9** (trae Dart 3.11.5), `git`, `curl`, `lsof`, Python 3 |
| Protocolo en navegador, tablero web, prueba de humo y PDF | **Google Chrome** (si está en otra ruta, variable `CHROME`) |
| PDF de arquitectura | Python 3 con `pypdf` |
| La app en un simulador o emulador | Xcode (simulador de iOS) o Android SDK (emulador de Android) |
| El video de presentación | `swiftc` (viene con Xcode) y las voces del sistema (`say`); **no** hace falta `ffmpeg` |

Probado en macOS 27. Los datos son **sintéticos** y los canales, **simulados** (lo que permite el §4.7 del enunciado).

### 1 · Preparación (una vez)

```bash
git clone https://github.com/Bdavid117/hackathon-asi && cd hackathon-asi
dart pub get          # resuelve el workspace (paquetes y aplicaciones)
```

### 2 · La batería completa — `bash tool/test_all.sh` (≈ 6 min, termina con `TODO EN VERDE` y código 0)

| Qué corre | Pruebas / resultado |
|---|---|
| `packages/protocol` (en VM **y** en Chrome) · `client_core` · `agents` · `sim` | 124 · 89 · 421 · 224 |
| `apps/node` · `apps/mobile` (widgets) · `apps/dashboard` (widgets) | 596 · 127 · 488 |
| Análisis estático de los cinco paquetes y las dos aplicaciones Flutter | «No issues found» en cada uno |
| H1: recorrido de punta a punta con pérdida de nodo (dos corridas, la segunda con la rama del isolate) | `H1 OK` |
| Demostración adversa (partición, `kill -9`, reconexión) **dos veces** con la misma semilla | misma huella (T09, T10, T15) |
| T12 (modelo colgado o roto y relevo) · ráfaga con el modelo colgado y `ulimit -n 1024` · T14 | cada uno termina `OK` |
| Tablero **compilado** abierto en Chrome sin cabeza; códigos de acceso (3 nodos); informe de despachador (3 nodos); recursos declarados (2 nodos) | `OK` en cada uno |

**Total: 2 069 pruebas.** `bash tool/test_all.sh --sin-e2e` omite lo que arranca nodos reales (más rápido). **No la corra con la demostración en vivo (§5) arriba:** comparten los puertos 8081/8082 y la carga puede hacer fallar un arranque (una vez un nodo no arrancó en 60 s con la máquina cargada; aislado y repetido, pasa).

### 3 · Cada resultado, con su comando

Pase siempre `--out` a un archivo temporal si sólo quiere **reproducir**: sin él, T12, T18 y T19 **sobrescriben** su informe versionado (y el árbol queda sucio). Los informes más recientes (T17 a T20) llevan fecha, commit y semilla de la corrida que los produjo.

| Resultado | Informe | Comando | Tiempo |
|---|---|---|---|
| T01 · `kill -9` sin perder un SOS dado por guardado | [`b5.md`](docs/resultados/b5.md) §1 | `(cd packages/client_core && dart test test/t01_kill_test.dart)` | 14 s |
| T02–T04 · bytes por reporte, entrega bajo pérdida, ventanas breves (tiempo virtual) | [`b2.md`](docs/resultados/b2.md) | `dart run packages/sim/bin/transport_report.dart /tmp/b2.md` | 6 s |
| T06 (reglas), T07, T08 · urgencia, deduplicación, rumor frente a corroboración | [`b3.md`](docs/resultados/b3.md) | `dart run packages/sim/bin/b3_report.dart /tmp/b3.md` | 22 s |
| H1 · recorrido de punta a punta con pérdida de nodo | [`h1.md`](docs/resultados/h1.md) | `dart run packages/sim/bin/e2e_skeleton.dart --seed 42` (usa los puertos 8081–8082; `--port-base` los cambia) | 20 s |
| T09, T10, T15 · reinicio tras `kill -9`, convergencia y huella reproducible | [`b5.md`](docs/resultados/b5.md) §1 | `PART=4 bash tool/demo.sh 42` (`PART=20` para una partición de 20 s) | 53 s |
| T11 · ráfaga de 10 000 reportes | [`b5-rafaga.md`](docs/resultados/b5-rafaga.md) | `dart run packages/sim/bin/burst.dart --reports 10000 --out /tmp/burst.md` | 22 s |
| T12 · modelo colgado o roto, reparto y relevo entre dos nodos | [`t12.md`](docs/resultados/t12.md) | `dart run packages/sim/bin/t12.dart --reports 100 --out /tmp/t12.md` | 78 s |
| T14 · ningún P1 fuera de la vista inicial | [`t14.md`](docs/resultados/t14.md) | `dart run packages/sim/bin/t14.dart --seeds 401 --out /tmp/t14.md` | 9 s |
| T16 · canal del despachador con 3 nodos reales | [`despachador.md`](docs/resultados/despachador.md) | `bash tool/dispatch_check.sh` | 23 s |
| T17 · contradicciones entre reportes | [`t17-contradicciones.md`](docs/resultados/t17-contradicciones.md) | `dart run packages/sim/bin/t17_contradicciones.dart --out /tmp/t17.md` | 2 s |
| T18 · partición de 10 min con dos nodos y un proxy con interruptor | [`t18-particion-larga.md`](docs/resultados/t18-particion-larga.md) | `dart run packages/sim/bin/t18_particion_larga.dart --out /tmp/t18.md` | ≈ 11 min |
| T19 · tres nodos: relevo del modelo y convergencia | [`t19-tres-nodos.md`](docs/resultados/t19-tres-nodos.md) | `dart run packages/sim/bin/t19_tres_nodos.dart --out /tmp/t19.md` | 63 s |
| T20 · la capa «Silencio» frente a una verdad aparte | [`t20-silencio.md`](docs/resultados/t20-silencio.md) | `(cd apps/node && dart run tool/t20_silencio.dart --seeds 20 --zones 60 --first-seed 100 --out /tmp/t20.md)` | 2 s |
| Códigos de acceso (`--coordinator-token`, `--peer-token`) | [`b5.md`](docs/resultados/b5.md) | `bash tool/access_check.sh` | 19 s |
| Recursos declarados en vivo, conflicto y resolución | [`b5.md`](docs/resultados/b5.md) | `bash tool/resources_check.sh` | 27 s |
| Tablero compilado abierto en Chrome | — | `bash tool/web_smoke.sh --no-build` (antes: `(cd apps/dashboard && flutter build web --no-web-resources-cdn)`) | 9 s |
| Mapa, capa «Silencio», panel «Situación», historia del incidente | [`b6-mapa.md`](docs/resultados/b6-mapa.md), [`cobertura.md`](docs/resultados/cobertura.md) | pruebas de `apps/dashboard` y `apps/node` (en la batería) | — |

**En un dispositivo** (necesita un emulador o simulador encendido; **`device_check.sh` hace `pkill` de todo nodo en marcha** y usa el puerto 8081):

```bash
bash tool/device_check.sh android emulator-5554     # o:  bash tool/device_check.sh ios <UDID del simulador>
bash tool/android_offline_check.sh                  # SOS sin red → no llega nada → al volver la red sale solo
bash tool/android_battery_check.sh                  # modos normal, ahorro y sólo SOS con la batería a 100, 15 y 3 %
bash tool/build_apk.sh                              # APK de Android (emulador: bash tool/build_apk.sh emulador)
```

### 4 · Lo que cuesta dinero: el modelo de lenguaje real

T06, T07 y T13 **con modelo** llaman a la API de Anthropic; todo lo demás, no. Los informes de esas corridas traen sus datos crudos (CSV) y su gasto: [`modelo-real.md`](docs/resultados/modelo-real.md), [`t06-modelo.md`](docs/resultados/t06-modelo.md), [`reto4-juez.md`](docs/resultados/reto4-juez.md).

```bash
dart run packages/sim/bin/t06_model.dart --plan --seeds 601,602,603,604,605 --per-seed 150   # cuántas llamadas y cuánto costarían; NO gasta
ANTHROPIC_API_KEY=… dart run packages/sim/bin/t06_model.dart --seeds 601,602,603,604,605 --per-seed 150 --budget-usd 10
dart run packages/sim/bin/t07_modelo.dart --plan --seeds 701,702,703,704,705                 # lo mismo para el juez de modelo (Reto 4)
```

`--plan` siempre antes de gastar. Las corridas medidas costaron entre 1,8 y 9,5 USD cada una; el registro [`gasto-api.json`](docs/resultados/gasto-api.json) y `ApiLedger` se niegan a lanzar una corrida si lo gastado más su tope pasa de 40 USD. La clave va **sólo** en la variable de entorno `ANTHROPIC_API_KEY` (nunca se versiona); `--llm on` en un nodo envía texto libre a un tercero y está apagado por omisión.

### 5 · La demostración en vivo y la app en un simulador

```bash
bash tool/expo.sh                       # dos nodos que se replican (8081 y 8082) con seis horas de historia SINTÉTICA; se queda en primer plano; Ctrl+C lo apaga todo
bash tool/expo_ctl.sh kill A            # kill -9 de verdad del nodo A (en otra terminal)
bash tool/expo_ctl.sh start A           # lo reanima con su mismo disco (≈ 3 s)
bash tool/expo_ctl.sh status            # eventos y estado de los dos
(cd apps/mobile && flutter run -d <simulador> --dart-define=NODES=http://localhost:8081,http://localhost:8082)   # emulador de Android: http://10.0.2.2:8081,http://10.0.2.2:8082
```

Un nodo suelto con el tablero: `(cd apps/dashboard && flutter build web --no-web-resources-cdn)` y `(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --web-root ../dashboard/build/web --resources ../../config/recursos.json)`; `dart run packages/sim/bin/seed_scenario.dart --now` le carga 8 incidentes. **Guion con tiempos medidos, qué debe verse y plan B por escena:** [`docs/pitch/demo-en-vivo.md`](docs/pitch/demo-en-vivo.md). El diálogo de ubicación del simulador de iOS es del sistema y ningún script puede pulsarlo: toque «Permitir al usar la app» una vez (o concédalo con `xcrun simctl privacy <UDID> grant location com.example.sardMobile` **después** de instalar la app).

### 6 · Regenerar los documentos, el pitch y el video

```bash
python3 docs/src/build.py                                           # PDF de arquitectura → docs/SARD-arquitectura-app-movil.pdf (Chrome + pypdf)
python3 docs/src/tools/frame_size.py                                # mide la trama binaria frente a JSON
python3 -I docs/pitch/build_pdf.py --pdf docs/pitch/SARD-pitch.pdf [--png-dir DIR]   # el pitch (18 láminas; fuentes en docs/pitch/deck/)
python3 -I tool/brand/build_icons.py                                # los íconos de la marca (Android, iOS y tablero web)
dart run packages/sim/bin/make_dashboard_fixtures.dart              # los JSON del tablero a partir de un nodo real
```

El **video de presentación** (52 s, tomas reales de la app y del tablero) se reconstruye con [`docs/pitch/video/README.md`](docs/pitch/video/README.md); el `.mp4` no se versiona. Fuentes del PDF: `docs/src/parts/*.html` (contenido), `docs/src/diagrams.py` (figuras), `docs/src/style.css` (estilo).

### 7 · Si algo falla

| Síntoma | Causa y salida |
|---|---|
| «el puerto NNNN ya está en uso» | Otra demostración o prueba: `lsof -nP -iTCP:NNNN -sTCP:LISTEN` y cierre lo que sobre. Puertos: H1 8081–8082 · burst 8093 · T14 8094 · demo 8095–8096 · web 8099 · T18 8101–8102 · T19 8111–8113 · accesos 8191–8193 · despachador 8194–8196 · recursos 8197–8198 |
| «el nodo A no respondió en 60 s» | Arranque lento con la máquina cargada: repetir con la máquina en reposo (no es un fallo del nodo; aislada, la prueba pasa) |
| T12 con reparto desigual (A=24, B=0) | Intermitencia conocida y sin explicar (una vez en una corrida completa); el script imprime el estado de los dos nodos |
| Chrome no está en la ruta usual | `export CHROME="/ruta/a/chrome"`; sin Chrome la prueba de humo se omite (código 77) y lo dice |
| `flutter doctor` marca una licencia de Android sin aceptar | No impide compilar ni ejecutar en el emulador |

## Resumen de la arquitectura

- **App móvil ciudadana** (Flutter; Android primero): offline-first y *store-and-forward*, SOS en un toque, bandeja de salida en SQLite, trama binaria de 33 B con identificador idempotente y reintentos con variación.
- **Nodos supervivientes** (Dart) sin líder: log de eventos que sólo crece, vistas derivadas y sincronización entre pares.
- **Tejido de seis agentes** con respaldo determinista; el de resiliencia no usa modelo de lenguaje y ninguno puede despachar. Por omisión funcionan **sólo con reglas**; el modelo es **opcional** (`--llm on`, apagado por omisión) y SÍ se probó contra la API real: en 750 reportes sintéticos con texto sube el recall de P1 del 85,4 % al 96,0 % (Sonnet 5.5, `effort low`) a costa de 10 falsos P1, sin ninguna llamada por encima de los 8 s del nodo y a 0,0024 USD por reporte; T13 con modelo: 12 de 12 ([`t06-modelo.md`](docs/resultados/t06-modelo.md), [`t13-sonnet-5-5.md`](docs/resultados/t13-sonnet-5-5.md)).
- **Tablero del coordinador** (Flutter Web): incidentes con evidencia, recomendación con aprobación humana registrada, contadores honestos y «vista parcial». **Banco de pruebas** reproducible (datos sintéticos, simulador de canal, inyector de fallos).

**Seguridad, en una línea:** sin CORS por omisión, los `POST` exigen JSON, el presupuesto por dispositivo *degrada* y no rechaza; y —si el nodo arranca con `--coordinator-token` y `--peer-token`— lo que ve y decide el coordinador y la réplica entre nodos exigen un código compartido (`tool/access_check.sh`, 3 nodos reales). Con un solo código compartido **no hay identidad** (no dice quién aprobó); con `--coordinator-codes` el código sí identifica, pero sólo en el nodo que recibe la petición. Sin códigos el nodo sigue abierto, viaja sin cifrar (HTTP, sin TLS) y la clave de integridad de las tramas es compartida (límites declarados en `docs/resultados/b5.md` §7).

Los paquetes compartidos (`protocol`, `client_core`, `agents`, `sim`) serán **Dart puro**, sin importar Flutter.

## Entorno de desarrollo

Flutter 3.41.9, Dart 3.11.5, macOS 27, AVD de Android `MediumAndroid` y simulador de iOS `SARD-iPhone` (iPhone 17, iOS 27). Los requisitos de cada tarea están en [«Reproducir los resultados»](#reproducir-los-resultados).

## Pendiente

- **Video de respaldo de la demostración — decidido; se graba cuando los retos estén cumplidos** (con el código congelado y tras el último cambio de la interfaz, para no enseñar un defecto ya corregido). Todavía no existe y **no se versiona** (los `*.mp4`/`*.mov` están en `.gitignore`). Respalda a `tool/demo.sh`, no lo sustituye: el entregable 7 pide una demostración *reproducible*. Para que enseñe lo último: `dart run packages/sim/bin/seed_scenario.dart --now --extended`.
- **T12 intermitente, sin explicar:** una vez, en una corrida completa de `test_all.sh`, el reparto salió A=24, B=0 ([`t12.md`](docs/resultados/t12.md)). No se ha vuelto a ver en 7 corridas aisladas (5 con 7 procesos quemando CPU); con 30 procesos ni llegó a medirse (un nodo no arrancó en 60 s: otra causa). No se tocó ningún plazo; si vuelve, el script imprime el estado de los dos nodos para saber si B no recibió, no procesó o no contestó.

**Opcional, más allá de lo que exige el enunciado** (mejoras del producto, no brechas frente al §4.7):

- Repetir la medición del modelo con más de una corrida ([`modelo-real.md`](docs/resultados/modelo-real.md): hoy sólo hay una), un agrupamiento que de verdad fusione (las cinco fuentes independientes de T08 siguen sin agruparse de punta a punta) y la redacción de datos personales antes de enviar texto al modelo (con datos sintéticos no hay datos personales; importaría si se alimentara con datos reales).
- Para un despliegue real, no para el §4.7: servicio en primer plano de Android (si el sistema mata el proceso, la cola sigue en SQLite pero no sale hasta reabrir la app), instalar el APK en un teléfono, canales de radio, TLS, un límite de intentos con el código y que los nodos pares comprueben el nombre de quien firma (hoy el código identifica, pero sólo en el nodo que recibe la petición), y una prueba de uso con coordinadores.
- La fragmentación de tramas (definida, no implementada) no hace falta con 33 B y 140 B: cada reporte cabe en una sola trama.
