# hackathon-asi · SARD

Repositorio del proyecto para la **Hackathon SARD** (Sistema Agéntico de Respuesta y Resiliencia ante Desastres), Expo ASI 2026, Universidad Nacional de Colombia | Sede Manizales.

El enunciado oficial es [`HackathonExpoASI2026.pdf`](HackathonExpoASI2026.pdf). Lo que se evalúa es un **recorrido completo de ocho pasos** (reporte ciudadano → almacenamiento local → transmisión intermitente → procesamiento por agentes → priorización → tablero → pérdida de un nodo → recuperación), no una pantalla aislada.

> **Alcance de la demostración.** El enunciado lo permite en su §4.7: «El recorrido puede ejecutarse con datos sintéticos y canales simulados. No se exige desplegar una red de radio real ni contar con acceso a infraestructura gubernamental.» Por eso todo lo de este repositorio usa datos sintéticos y canales simulados, y el objetivo 10 pide justamente «pruebas reproducibles de desconexión, pérdida de paquetes y recuperación». El emulador de Android y el simulador de iOS son una decisión del equipo (el enunciado no fija plataforma). **Dos cosas que NO vienen del enunciado:** (1) el enunciado no trae rúbrica, pesos ni metas numéricas; (2) los umbrales que aparecen aquí —recall de P1 ≥ 95 %, falsa fusión ≤ 1 %, particiones de 10 min, «ningún P1 fuera de la vista»— son metas del **propio diseño** (cap. 9 del PDF de arquitectura). Incumplir una meta propia se reporta, pero no es incumplir el enunciado.

> **¿Quiere repetir las pruebas?** Siga la [guía paso a paso](#guía-paso-a-paso-de-cero-a-todas-las-pruebas): va de la instalación a cada prueba, con el comando, lo que debe verse y cuánto tarda.

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
| 1 | Prototipo funcional | La app ciudadana ([`apps/mobile`](apps/mobile)), el nodo superviviente ([`apps/node`](apps/node)) y el tablero del coordinador ([`apps/dashboard`](apps/dashboard)) | `PART=20 bash tool/demo.sh 42` (recorrido de punta a punta con una condición adversa) o «Un nodo con el tablero» en el [paso 6 de la guía](#guía-paso-a-paso-de-cero-a-todas-las-pruebas) |
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

## Guía paso a paso: de cero a todas las pruebas

**Quién es el «usuario» aquí.** El sistema tiene tres papeles: la **persona que envía un SOS** (la app), el **despachador** que registra lo que oyó por radio o teléfono, y el **coordinador** que revisa y aprueba (el tablero). Esta guía los recorre **con datos sintéticos y canales simulados**, a mano y con scripts, que es lo que permite el §4.7 del enunciado. **No hubo pruebas con personas** (ni ciudadanos, ni despachadores, ni coordinadores): ningún paso de abajo las sustituye, y la guía no trae un protocolo de sesión con personas.

**Siga el orden.** Los pasos comparten puertos (8081 y 8082 para la demostración) y **tres scripts matan todos los nodos en marcha** (`access_check.sh`, `device_check.sh` y `android_offline_check.sh`, avisados donde aparecen). No deje nada arriba entre un paso y el siguiente. Los comandos se escriben desde la raíz del repositorio.

| Paso | Qué hace | Tiempo | ¿Gasta API? |
|---|---|---|---|
| 0 y 1 | Comprobar requisitos e instalar | según la conexión | no |
| 2 | La batería completa de pruebas automáticas | ≈ 6 min | no |
| 3 | Resultados sueltos (T01 a T20), sin ensuciar el repositorio | segundos a 11 min | no |
| 4 | El recorrido de punta a punta con una condición adversa | ≈ 1 min | no |
| 5 | **Los tres papeles, a mano**, con la demostración en vivo | a su ritmo (arranque ≈ 14 s) | no |
| 6 | Un nodo suelto con el escenario ampliado | a su ritmo | no |
| 7 | Comprobaciones con procesos reales y en dispositivo | 9 a 27 s cada script de nodos | no |
| 8 | El modelo de lenguaje real | — | **sí** |

### Paso 0 · Comprobar los requisitos

```bash
flutter --version                       # debe decir Flutter 3.41.9 (con Dart 3.11.5)
git --version && python3 --version && curl --version | head -1
ls -d "/Applications/Google Chrome.app" # si Chrome está en otra ruta: export CHROME="/ruta/a/chrome"
```

El detalle de qué necesita cada prueba (simulador, emulador, `pypdf`) está en [«0 · Requisitos»](#0--requisitos).

### Paso 1 · Descargar e instalar

```bash
git clone https://github.com/Bdavid117/hackathon-asi && cd hackathon-asi
dart pub get          # resuelve el workspace: cuatro paquetes y tres aplicaciones
```

Debe terminar sin errores. Si ya tiene el repositorio, `git pull` y otra vez `dart pub get`.

### Paso 2 · La batería completa (nada más en marcha)

```bash
bash tool/test_all.sh                   # ≈ 6 min
echo $?                                 # 0
```

Debe terminar con `TODO EN VERDE` y código 0. Corre las pruebas de los cuatro paquetes y de las tres aplicaciones, el análisis estático, el recorrido H1 con pérdida de nodo, la demostración adversa **dos veces** con la misma semilla, T12, la ráfaga con el modelo colgado, T14, el tablero compilado en Chrome sin cabeza y los scripts de códigos de acceso, despachador y recursos. La tabla completa está en «2 · La batería completa» de [Reproducir los resultados](#reproducir-los-resultados). Con `--sin-e2e` omite lo que arranca nodos reales (más rápido). **No la corra con la demostración del paso 5 arriba.**

### Paso 3 · Resultados sueltos, sin ensuciar el repositorio

Los que escriben un informe lo dejan en `/tmp`; **conserve siempre el `--out`**: sin él, T12, T18 y T19 sobrescriben su informe versionado. Qué mide cada uno, su informe y su tiempo están en la tabla de [«3 · Cada resultado, con su comando»](#3--cada-resultado-con-su-comando).

```bash
(cd packages/client_core && dart test test/t01_kill_test.dart)      # T01 · 6 kill -9 sin perder un SOS guardado (≈ 14 s)
dart run packages/sim/bin/transport_report.dart /tmp/b2.md          # T02–T04 · bytes, pérdida de paquetes y ventanas breves (≈ 6 s)
dart run packages/sim/bin/b3_report.dart /tmp/b3.md                 # T06 (reglas), T07, T08 · urgencia, duplicados y rumor (≈ 22 s)
dart run packages/sim/bin/burst.dart --reports 10000 --out /tmp/burst.md                      # T11 · ráfaga de 10 000 (≈ 22 s)
dart run packages/sim/bin/t12.dart --reports 100 --out /tmp/t12.md                            # T12 · modelo colgado y relevo (≈ 78 s)
dart run packages/sim/bin/t14.dart --seeds 401 --out /tmp/t14.md                              # T14 · ningún P1 fuera de la vista (≈ 9 s)
dart run packages/sim/bin/t17_contradicciones.dart --out /tmp/t17.md                          # T17 · contradicciones (≈ 2 s)
(cd apps/node && dart run tool/t20_silencio.dart --seeds 20 --zones 60 --first-seed 100 --out /tmp/t20.md)   # T20 · capa «Silencio» (≈ 2 s)
dart run packages/sim/bin/t19_tres_nodos.dart --out /tmp/t19.md                               # T19 · tres nodos (≈ 63 s)
dart run packages/sim/bin/t18_particion_larga.dart --out /tmp/t18.md                          # T18 · partición de 10 min (≈ 11 min)
```

Cada uno termina con un veredicto aplicado por código (por ejemplo, T17 imprime «cumple los tres criterios»; T20 dice que **H4 no se cumple**: es lo esperado, el informe lo reporta así). Las cifras se comparan con las del informe versionado: los que usan semilla dan lo mismo; los de tiempos varían con la máquina.

### Paso 4 · El recorrido de punta a punta con una condición adversa

```bash
PART=4 bash tool/demo.sh 42             # ≈ 53 s (PART=20 para una partición de 20 s)
```

Levanta **dos nodos reales**, los parte en dos, manda una ráfaga de 26 reportes, mata a uno con `kill -9` a mitad, lo reinicia midiendo el RTO, reconecta la red y compara las proyecciones. Debe verse que **A acusó 8 de 26 y los otros 18 conmutaron a B**, el RTO, la convergencia y, al final, `misma semilla ⇒ misma huella (T15)` (lo ejecuta dos veces). Cubre los pasos 7 y 8 del recorrido del enunciado: [`b5.md`](docs/resultados/b5.md) §1 (T09, T10, T15). El recorrido H1 completo, con el mismo canal de pérdida: `dart run packages/sim/bin/e2e_skeleton.dart --seed 42` (≈ 20 s; usa los puertos 8081–8082).

### Paso 5 · Los tres papeles, a mano, con la demostración en vivo

Es la demostración de [`demo-en-vivo.md`](docs/pitch/demo-en-vivo.md) con cada papel por separado. Necesita dos ventanas de Chrome y dos terminales (la 1.ª se queda ocupada).

**5.1 · Levantar los dos nodos** (terminal 1, no la cierre):

```bash
bash tool/expo.sh --build               # la primera vez: compila el tablero (1–2 min); después basta  bash tool/expo.sh  (≈ 14 s)
```

Debe mostrar un cuadro final con `Nodo A … (123 eventos)`, `Nodo B … (123 eventos)` y `Zonas en silencio ahora: 4`. Los dos nodos se replican entre sí y cargan seis horas de historia **sintética**. Las dos zonas que siguen reportando pasan a silencio solas 30 minutos después de arrancar: si se retrasa, reinicie con Ctrl+C y otra vez. `bash tool/expo.sh --empty` arranca sin escenario.

**5.2 · Abrir el tablero en dos ventanas** (1440 × 900): `http://localhost:8081` (nodo A) y `http://localhost:8082` (nodo B). Debe verse la barra `3 P1 · 21 P2 · 16 P3`, «31 pendientes de decisión» y, a la derecha, el panel «Situación» con la red de nodos sincronizada.

**5.3 · Papel del coordinador.** En la ventana de A: abra un P1 de la lista. Debe verse el *porqué* (indicadores y citas), la observación original, «Fuente única» y una **recomendación que es una propuesta**, con lo que falta antes de aprobar. Pulse **Aprobar** y escriba un nombre: queda registrado quién decidió y con qué versión. Abra «Historia» al final del detalle: pestaña «Agentes» (qué hizo cada uno, con nodo y hora) y pestaña «Decisiones» (quién, cuándo, estado). Respaldo: T13 y T14 en [`b5.md`](docs/resultados/b5.md) §1 y `apps/dashboard/test/detail_panel_test.dart`.

**5.4 · Silencio digital.** Cambie a «Mapa» y active el botón **«Silencio»** (franja bajo el mapa). Debe verse **4 zonas rayadas** y el rótulo que empieza por «El silencio no es seguridad». Cuánto acierta, medido en el paso 3 (T20): precisión 48,8 % y exhaustividad 89,1 %. Respaldo: [`cobertura.md`](docs/resultados/cobertura.md).

**5.5 · Papel del despachador.** Pulse **«Registrar informe»** (arriba a la derecha). Escriba lo que «oyó por radio», de quién viene, marque «Atrapado» y «Herido» y envíe. Debe aparecer un incidente **P1 «De segunda mano»**, con una sola fuente, confianza 0,2 y «Sin ubicación»: el detalle dice que todavía no se puede recomendar por falta de ubicación. Si escribe latitud y longitud, entra con calidad «manual» y la recomendación pide confirmarla. Lo mismo, con tres nodos reales y sin teclear: `bash tool/dispatch_check.sh` (≈ 23 s; sólo toca los puertos 8194–8196). Respaldo: [`despachador.md`](docs/resultados/despachador.md) (T16).

**5.6 · Papel del ciudadano, en un simulador o emulador.** Elija **una** plataforma (terminal 2).

*iOS (simulador):*

```bash
xcrun simctl list devices               # copie el UDID del simulador (el equipo usó uno llamado «SARD-iPhone»)
xcrun simctl boot <UDID>
open -a Simulator                                       # si Xcode no trae la app Simulator, el simulador corre sin ventana: véalo con  xcrun simctl io <UDID> screenshot foto.png
xcrun simctl location booted set 5.0689,-75.5174        # GPS en Manizales
(cd apps/mobile && flutter run -d <UDID> --dart-define=NODES=http://localhost:8081,http://localhost:8082)
```

*Android (emulador):*

```bash
~/Library/Android/sdk/emulator/emulator -list-avds      # nombre del AVD (el equipo usó «MediumAndroid»)
~/Library/Android/sdk/emulator/emulator -avd <nombre del AVD> &
flutter devices                         # espere a ver emulator-5554
(cd apps/mobile && flutter run -d emulator-5554 --dart-define=NODES=http://10.0.2.2:8081,http://10.0.2.2:8082)
```

La primera compilación tarda minutos; hágala antes. La primera vez aparece el diálogo del sistema de ubicación (iOS: «¿Permitir a SARD utilizar tu ubicación?»; Android: «Allow SARD to access this device's location?»): **ningún script de prueba lo pulsa**, toque «Permitir al usar la app» («While using the app» en Android). El 10.0.2.2 es cómo el emulador de Android ve el equipo anfitrión.

Lo que se hace en la app (**pasos manuales: el equipo no ha ensayado el toque en el simulador**, porque un script no puede pulsarlo; lo que sí está automatizado es el paso 7):

1. Toque **SOS**. Debe decir «Guardado en tu teléfono» sin esperar a la red, y en el tablero aparece el reporte nuevo en pocos segundos.
2. Después, con calma, toque «2–5» personas y escriba una frase: enriquece el **mismo** reporte, no lo duplica (el SOS nunca lleva texto; la frase se corta a 140 bytes).
3. *Sin red, sólo en Android.* Apague la red del emulador, toque SOS, mate la app y reábrala (sigue ahí), y devuelva la red: el reporte sale solo ≈ 1 s después. **El simulador de iOS no tiene un interruptor de red por script**; ese caso se prueba en Android (`tool/android_offline_check.sh`, paso 7).

   ```bash
   ADB=~/Library/Android/sdk/platform-tools/adb
   $ADB shell svc wifi disable; $ADB shell svc data disable     # sin red
   $ADB shell svc wifi enable;  $ADB shell svc data enable      # con red otra vez (no la deje apagada)
   ```
4. Compruebe que los dos nodos tienen lo mismo: `bash tool/expo_ctl.sh status`.

**5.7 · Se cae un nodo** (terminal 2, mientras el tablero sigue abierto):

```bash
bash tool/expo_ctl.sh kill A            # kill -9 de verdad, sin avisar
bash tool/expo_ctl.sh start A           # lo reanima con SU MISMO disco (≈ 3 s)
bash tool/expo_ctl.sh status            # los dos con el mismo número de eventos y «sincronizado»
```

Tras `kill A`, la ventana de **B** sigue con todo y muestra una franja amarilla «Vista parcial», el par en rojo («Sin respuesta · hace N s») y el aviso en «Situación». La ventana de **A** queda en «Sin conexión»: es lo esperado, porque esa página depende del nodo que la sirvió (el tablero no conmuta solo; se abre la del otro). Con A caído puede enviar otro SOS desde la app: **ese caso (la app pasando a B) no se ha ensayado a mano**; la conmutación sí está medida con procesos reales en el paso 4. Tras `start A`, espere ≤ 3 s para que replique.

**5.8 · Cerrar.** Ctrl+C en la terminal 1 apaga los dos nodos y borra sus datos temporales. Compruebe que no quedó nada (no debe imprimir nada):

```bash
lsof -nP -iTCP:8081 -iTCP:8082 -sTCP:LISTEN
```

### Paso 6 · Un nodo suelto con el escenario ampliado

Con **nada** en los puertos 8081 y 8082 (cierre el paso 5). Primero compile el tablero si no lo hizo (`(cd apps/dashboard && flutter build web --no-web-resources-cdn)`).

```bash
D=$(mktemp -d)
(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data "$D" \
   --web-root ../dashboard/build/web --resources ../../config/recursos.json) &
until curl -s localhost:8081/api/health >/dev/null 2>&1; do sleep 0.5; done     # espera a que el nodo responda
dart run packages/sim/bin/seed_scenario.dart --node http://localhost:8081 --now --extended
```

Abra `http://localhost:8081`. `--now` pone horas de ahora (el tablero dice «hace 3 min») y `--extended` añade **una contradicción** entre dos reportes (se muestran los dos y se cuentan en «Con contradicciones», sin resolverse), **una vía bloqueada** en la ruta de la ambulancia (la propuesta del P1 pide «confirmar que la ruta esté libre») y **la ambulancia 2 no disponible** (panel «Recursos» de la barra; cambiar una unidad no despacha nada). Para apagarlo:

```bash
pkill -f "sard_node.dart --id A --port 8081"; rm -rf "$D"
```

Con identidad por coordinador, el nodo se arranca con `--coordinator-codes "Ana=código,Luis=código"`: cada código tiene dueño y el de Luis no puede firmar como Ana. Sin ese argumento, el nodo está abierto. Es «identificado por código», no «autenticado».

### Paso 7 · Comprobaciones con procesos reales y en dispositivo

Con **nada** en marcha. Los marcados con ⚠ **matan todo nodo que corra** (`pkill` de `bin/sard_node.dart`).

```bash
bash tool/web_smoke.sh --no-build       # ≈ 9 s · el tablero compilado en Chrome sin cabeza pinta los contadores (OK / 77 si no hay Chrome)
pkill -f "sard_node.dart --id A --port 8099"   # web_smoke deja su nodo escuchando en el 8099 al terminar: ciérrelo así
bash tool/resources_check.sh            # ≈ 27 s · recursos en vivo: partición, kill -9, conflicto y resolución (puertos 8197–8198)
bash tool/dispatch_check.sh             # ≈ 23 s · el canal del despachador con tres nodos (8194–8196)
bash tool/access_check.sh               # ≈ 19 s · ⚠ códigos de acceso e identidad por coordinador (8191–8194)
```

Con el emulador o el simulador **ya encendido** (`flutter devices` lo lista):

```bash
bash tool/device_check.sh android emulator-5554       # ⚠ SOS → nodo → reabrir, agentes, GPS y detalles, con el main() real
bash tool/device_check.sh ios <UDID>                  # ⚠ lo mismo en el simulador de iOS
bash tool/android_offline_check.sh                    # ⚠ SOS sin red → no llega nada → al volver la red sale solo (siempre la deja encendida)
bash tool/android_battery_check.sh                    # batería a 100, 15 y 3 %: modos normal, ahorro y sólo SOS (siempre la restablece)
bash tool/build_apk.sh                                # APK de Android (con el emulador: bash tool/build_apk.sh emulador)
```

### Paso 8 · El modelo de lenguaje real (cuesta dinero)

Es lo **único** que llama a la API de Anthropic. Haga siempre primero el plan, que no gasta nada, y vea [«4 · Lo que cuesta dinero»](#4--lo-que-cuesta-dinero-el-modelo-de-lenguaje-real) antes de lanzar nada:

```bash
dart run packages/sim/bin/t06_model.dart --plan --seeds 601,602,603,604,605 --per-seed 150    # cuántas llamadas y cuánto costarían; NO gasta
```

La clave va sólo en la variable de entorno `ANTHROPIC_API_KEY`, nunca en un archivo del repositorio. Si algo falla en cualquier paso, mire [«7 · Si algo falla»](#7--si-algo-falla).

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
| «el puerto NNNN ya está en uso» | Otra demostración o prueba: `lsof -nP -iTCP:NNNN -sTCP:LISTEN` y cierre lo que sobre. Puertos: H1 8081–8082 · burst 8093 · T14 8094 · demo 8095–8096 · web 8099 · T18 8101–8102 · T19 8111–8113 · accesos 8191–8194 · despachador 8194–8196 · recursos 8197–8198 |
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
