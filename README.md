# hackathon-asi · SARD

Repositorio del proyecto para la **Hackathon SARD** (Sistema Agéntico de Respuesta y Resiliencia ante Desastres), Expo ASI 2026, Universidad Nacional de Colombia | Sede Manizales.

El enunciado oficial es [`HackathonExpoASI2026.pdf`](HackathonExpoASI2026.pdf). Lo que se evalúa es un **recorrido completo de ocho pasos** (reporte ciudadano → almacenamiento local → transmisión intermitente → procesamiento por agentes → priorización → tablero → pérdida de un nodo → recuperación), no una pantalla aislada.

> **Alcance de la demostración.** El enunciado lo permite en su §4.7: «El recorrido puede ejecutarse con datos sintéticos y canales simulados. No se exige desplegar una red de radio real ni contar con acceso a infraestructura gubernamental.» Por eso todo lo de este repositorio usa datos sintéticos y canales simulados, y el objetivo 10 pide justamente «pruebas reproducibles de desconexión, pérdida de paquetes y recuperación». El emulador de Android y el simulador de iOS son una decisión del equipo (el enunciado no fija plataforma). **Dos cosas que NO vienen del enunciado:** (1) el enunciado no trae rúbrica, pesos ni metas numéricas; (2) los umbrales que aparecen aquí —recall de P1 ≥ 95 %, falsa fusión ≤ 1 %, particiones de 10 min, «ningún P1 fuera de la vista»— son metas del **propio diseño** (cap. 9 del PDF de arquitectura). Incumplir una meta propia se reporta, pero no es incumplir el enunciado.

## Estado actual

**B0 a B5 implementados y medidos.** B4 y B5 —la app captura personas y frase; el nodo calcula incidentes con la recomendación del agente 6 y la aprobación registrada; el tablero del coordinador; el reparto del trabajo caro entre nodos; la ráfaga de 10 000 reportes y la demostración con una condición adversa— están en [`docs/resultados/b5.md`](docs/resultados/b5.md) (decisiones y mutaciones en [`b5-decisiones.md`](docs/resultados/b5-decisiones.md)). **Lo que NO se logró o no se probó** (límites de validez; que los datos sean sintéticos y los canales simulados no cuenta como uno, porque el enunciado lo permite): el modelo de lenguaje se consultó de verdad sólo en T06 y T13 con modelo y en una prueba del nodo (datos sintéticos, una corrida; T12 y la ráfaga siguen con un servidor falso); el agrupamiento casi no fusiona, así que la ventaja del tablero es de orden y no de agrupación; no hubo prueba con coordinadores; las particiones fueron de 5–20 s; quien aprueba no está autenticado y la clave de integridad es compartida. ⚠️ En B3, **dos de los tres criterios medidos —propios del diseño— no se cumplen** (T06 recall de P1 78,5 % frente a la meta propia de 95 %; T07 sólo cumple «falsa fusión ≤ 1 %» en conjunto y porque casi no agrupa: una de cinco semillas nuevas llega a 2,9 %) y se reportan así, con su diagnóstico, en [`docs/resultados/b3.md`](docs/resultados/b3.md). Los datos son sintéticos y los genera el mismo autor que las reglas, así que las cifras miden coherencia interna y no desempeño en campo. **`--llm on` envía el texto libre de los ciudadanos a un tercero sin redactar datos personales** (apagado por defecto; ver PDF §8). Desarrolla una sola persona, con Flutter: **Dart de punta a punta**. Un reporte recorre los ocho pasos del enunciado y la app se comporta bien en sus condiciones: **se guarda sin red y sale solo al volver la señal** (en el emulador de Android: 1 s tras devolver la red), lee el **GPS y la batería por las API del sistema** (en el emulador, simulados desde su consola; ubicación como revisión del mismo reporte; modos normal, ahorro y sólo SOS) y reparte el envío con **envejecimiento y cuota anti-inanición**.

- **1 448 pruebas automáticas** (el protocolo se cuenta en VM y en Chrome) en verde (`bash tool/test_all.sh`) más pruebas de integración en el emulador de Android y el simulador de iOS (`tool/device_check.sh`, `tool/android_offline_check.sh`, `tool/android_battery_check.sh`).
- **Canal del despachador (T16):** en el tablero, «Registrar informe» deja que una persona registre lo que oyó por radio, teléfono o en persona (`POST /api/dispatch`). Entra como información **de segunda mano**: una fuente, confianza 0,2 (supuesta), **sin ubicación** (el agente 6 no recomienda hasta saber el dónde), idempotente, replicable, y su texto **no** se envía al modelo. **No resuelve el Reto 4** (otros orígenes con otras palabras siguen sin agruparse) ni se probó con despachadores reales: [`docs/resultados/despachador.md`](docs/resultados/despachador.md), `bash tool/dispatch_check.sh` (tres nodos reales).
- **Reto 4 con un juez de modelo de lenguaje: medido y NO adoptado.** Se construyó (`packages/agents/lib/src/link_judge.dart`) y se midió una vez contra la API real con semillas nuevas, con el criterio fijado y commiteado antes de gastar. Resultado: une más reportes del mismo suceso (recall de pares 0,8 % → 4,4 %; 97,7 % de las uniones del modelo acertadas; en la corroboración de 5 fuentes reúne 4 y la confianza sube de 0,60 a 0,97), pero la falsa fusión sube de 1,22 % a 2,21 % (los errores son gemelos adversariales a confianza 0,80) y aplicado el criterio **no se ofrece en el nodo**: [`docs/resultados/reto4-juez.md`](docs/resultados/reto4-juez.md). Las 5 fuentes independientes siguen sin formar un grupo completo; el nodo no llama al juez.
- **Plataforma y alcance:** emulador de Android y simulador de iOS, datos sintéticos y canales simulados (lo que permite el §4.7). No se usó hardware ni radio reales, que el enunciado no exige; el APK de `dist/` no se ha instalado en un teléfono.

| Qué | Dónde |
|---|---|
| Diseño: análisis del enunciado, arquitectura, protocolo, agentes, pruebas y plan (v0.2) | [`docs/SARD-arquitectura-app-movil.pdf`](docs/SARD-arquitectura-app-movil.pdf) |
| Decisión: desarrollo individual, Dart de punta a punta y corte de alcance | [`docs/adr/0001-desarrollo-individual-dart.md`](docs/adr/0001-desarrollo-individual-dart.md) |
| Planes de implementación: B0/B1, B2, B3 y B4+B5 | [`docs/superpowers/plans/`](docs/superpowers/plans/) |
| Resultados: H1 (recorrido de punta a punta) | [`docs/resultados/h1.md`](docs/resultados/h1.md) |
| Resultados: transporte T02–T04 en tiempo virtual | [`docs/resultados/b2.md`](docs/resultados/b2.md) |
| Resultados: verificación en dispositivo | [`docs/resultados/b2-dispositivo.md`](docs/resultados/b2-dispositivo.md) |
| Resultados: agentes y deduplicación (B3) | [`docs/resultados/b3.md`](docs/resultados/b3.md) |
| Resultados: B4+B5 (T01, T09–T15), decisiones y límites | [`docs/resultados/b5.md`](docs/resultados/b5.md) · [`b5-decisiones.md`](docs/resultados/b5-decisiones.md) · [`t12.md`](docs/resultados/t12.md) · [`t14.md`](docs/resultados/t14.md) · [`b5-rafaga.md`](docs/resultados/b5-rafaga.md) |
| Resultados: canal del despachador (T16), decisiones y límites | [`docs/resultados/despachador.md`](docs/resultados/despachador.md) |
| **El modelo de lenguaje REAL**: T06 con modelo (Sonnet 5.5 y Opus 5.5, 750 reportes), T13 con modelo y la prueba del nodo; lectura, gasto y límites | [`docs/resultados/modelo-real.md`](docs/resultados/modelo-real.md) · [`t06-modelo.md`](docs/resultados/t06-modelo.md) · [`t06-modelo-opus.md`](docs/resultados/t06-modelo-opus.md) · [`t13-sonnet-5-5.md`](docs/resultados/t13-sonnet-5-5.md) |
| **Reto 4 con juez de modelo** (medido, no adoptado): protocolo, resultado, veredicto del criterio y por qué falló | [`docs/resultados/reto4-juez.md`](docs/resultados/reto4-juez.md) · [`t07-modelo.md`](docs/resultados/t07-modelo.md) |
| Guion de la demostración y del pitch | [`docs/pitch/guion.md`](docs/pitch/guion.md) |
| Presentación del pitch (15 láminas, con capturas reales; fuentes en `docs/pitch/deck/`, se regenera con `python3 -I docs/pitch/build_pdf.py --pdf docs/pitch/SARD-pitch.pdf`) | [`docs/pitch/SARD-pitch.pdf`](docs/pitch/SARD-pitch.pdf) |
| Oráculo del códec (genera los vectores de prueba) | [`docs/src/tools/frame_size.py`](docs/src/tools/frame_size.py) |

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
packages/sim/bin/llm_smoke.dart · t06_model.dart · t13_modelo.dart   el modelo REAL (necesitan ANTHROPIC_API_KEY en el entorno; ver docs/resultados/modelo-real.md)
tool/device_check.sh   pruebas de integración en Android o iOS contra un nodo real
tool/android_*_check.sh  sin red → sale solo; batería real → modos
```

## Comandos

```bash
dart pub get                                   # resuelve el workspace
bash tool/test_all.sh                          # pruebas + análisis + H1 + demostración + T12 + T14 + tablero web + canal del despachador (≈ 6 min)

# Un nodo con el tablero (compilar el tablero antes)
(cd apps/dashboard && flutter build web --no-web-resources-cdn)
(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --web-root ../dashboard/build/web --resources ../../config/recursos.json)
dart run packages/sim/bin/seed_scenario.dart            # opcional: 8 incidentes de ejemplo para ver el tablero

# El APK para instalar en un celular Android (la IP del nodo queda compilada dentro; misma Wi-Fi que esta Mac)
bash tool/build_apk.sh

# La app (iOS: localhost; emulador de Android: 10.0.2.2)
(cd apps/mobile && flutter run -d <dispositivo> --dart-define=NODES=http://localhost:8081)

# Recorrido de punta a punta con pérdida de nodo
dart run packages/sim/bin/e2e_skeleton.dart --seed 42 --reports 60 --loss 0.3

# Demostración con una condición adversa, ráfaga, modelo que falla y tablero estructural
PART=20 bash tool/demo.sh 42
dart run packages/sim/bin/burst.dart --reports 10000
dart run packages/sim/bin/t12.dart
dart run packages/sim/bin/t14.dart

# Mediciones de transporte (T02–T04) y pruebas en dispositivo
dart run packages/sim/bin/transport_report.dart docs/resultados/b2.md
bash tool/device_check.sh android emulator-5554
```

## Resumen de la arquitectura

- **App móvil ciudadana** (Flutter; Android primero): offline-first y *store-and-forward*, SOS en un toque, bandeja de salida en SQLite, trama binaria de 33 B con identificador idempotente y reintentos con variación.
- **Nodos supervivientes** (Dart) sin líder: log de eventos que sólo crece, vistas derivadas y sincronización entre pares.
- **Tejido de seis agentes** con respaldo determinista; el de resiliencia no usa modelo de lenguaje y ninguno puede despachar. Por omisión funcionan **sólo con reglas**; el modelo es **opcional** (`--llm on`, apagado por omisión) y SÍ se probó contra la API real: en 750 reportes sintéticos con texto sube el recall de P1 del 85,4 % al 96,0 % (Sonnet 5.5, `effort low`) a costa de 10 falsos P1, sin ninguna llamada por encima de los 8 s del nodo y a 0,0024 USD por reporte; T13 con modelo: 12 de 12 ([`t06-modelo.md`](docs/resultados/t06-modelo.md), [`t13-sonnet-5-5.md`](docs/resultados/t13-sonnet-5-5.md)).
- **Tablero del coordinador** (Flutter Web): incidentes con evidencia, recomendación con aprobación humana registrada, contadores honestos y «vista parcial». **Banco de pruebas** reproducible (datos sintéticos, simulador de canal, inyector de fallos).

**Seguridad, en una línea:** sin CORS por omisión, los `POST` exigen JSON, el presupuesto por dispositivo *degrada* y no rechaza; y —si el nodo arranca con `--coordinator-token` y `--peer-token`— lo que ve y decide el coordinador y la réplica entre nodos exigen un código compartido (`tool/access_check.sh`, 3 nodos reales). Pero ese código **no es identidad** (no dice quién aprobó), sin los códigos el nodo sigue abierto, viaja sin cifrar (HTTP, sin TLS) y la clave de integridad de las tramas es compartida (límites declarados en `docs/resultados/b5.md` §7).

Los paquetes compartidos (`protocol`, `client_core`, `agents`, `sim`) serán **Dart puro**, sin importar Flutter.

## Entorno de desarrollo

Flutter 3.41.9, Dart 3.11.5, AVD de Android `MediumAndroid` y simulador de iOS `SARD-iPhone` (iPhone 17, iOS 27). Aviso conocido: `flutter doctor` marca 1 de 8 licencias de Android sin aceptar; no impide compilar ni ejecutar en el emulador.

## Regenerar el PDF

Requiere Google Chrome, Python 3 y `pypdf`.

```bash
python3 docs/src/build.py              # genera docs/SARD-arquitectura-app-movil.pdf
python3 docs/src/tools/frame_size.py   # mide la trama binaria frente a JSON
```

Fuentes del documento: `docs/src/parts/*.html` (contenido), `docs/src/diagrams.py` (figuras), `docs/src/style.css` (estilo). Si Chrome está en otra ruta, definir la variable de entorno `CHROME`.

## Pendiente

- **Repositorio accesible al jurado (entregable 2):** está publicado como **privado** en `github.com/Bdavid117/hackathon-asi`. Falta darle acceso al jurado: hacerlo público, o añadir a cada integrante como colaborador (Settings → Collaborators).
- **Mapa de los 7 entregables en este README** (qué archivo, qué sección, qué comando). Hoy el árbol del cap. 10 del PDF de arquitectura promete `docs/agentes/`, `docs/protocolo.md` y `scenarios/`, que no existen: las fichas de agentes (8 campos, entregable 4) y el protocolo (entregable 5) están completos pero dentro del PDF (caps. 6 y 7). Falta el índice y corregir ese árbol, sin duplicar contenido.
- **Justificar el riesgo de aplazar un mensaje (enunciado §3.1: «qué riesgo existe al aplazar un mensaje»).** Cómo se decide qué sale primero está justificado (prioridad + envejecimiento + 1 de cada 5 posiciones para el más antiguo); falta el párrafo explícito sobre el riesgo, con las cifras que ya existen: T03 en [`b2.md`](docs/resultados/b2.md) (con 60 % de pérdida, P1 p95 = 32,7 s frente a P4 p95 = 7,5 min) y T11 en [`b5-rafaga.md`](docs/resultados/b5-rafaga.md).
- **Video de respaldo de la demostración — decidido; se graba cuando los retos estén cumplidos** (con el código congelado y tras el último cambio de la interfaz, para no enseñar un defecto ya corregido). Todavía no existe y **no se versiona** (los `*.mp4`/`*.mov` están en `.gitignore`). Respalda a `tool/demo.sh`, no lo sustituye: el entregable 7 pide una demostración *reproducible*.
- **T12 intermitente:** falló una de tres corridas completas de `test_all.sh` (A=24, B=0) y no se conoce la causa ([`t12.md`](docs/resultados/t12.md)). El jurado reproducirá con ese script.
- **Mejorar el canal del despachador** (T16): hoy un informe llega **sin ubicación** (por eso el agente 6 no recomienda), un «mensaje a medio terminar» no se marca como incertidumbre y quien registra no está autenticado.

**Opcional, más allá de lo que exige el enunciado** (mejoras del producto, no brechas frente al §4.7):

- Repetir la medición del modelo con más de una corrida ([`modelo-real.md`](docs/resultados/modelo-real.md): hoy sólo hay una), un agrupamiento que de verdad fusione (las cinco fuentes independientes de T08 siguen sin agruparse de punta a punta), el mapa de cobertura que advierta de que el silencio no es seguridad (pospuesto) y la redacción de datos personales antes de enviar texto al modelo (con datos sintéticos no hay datos personales; importaría si se alimentara con datos reales).
- Para un despliegue real, no para el §4.7: servicio en primer plano de Android (si el sistema mata el proceso, la cola sigue en SQLite pero no sale hasta reabrir la app), instalar el APK en un teléfono, canales de radio, autenticar a quien aprueba, TLS y una prueba de uso con coordinadores.
- La fragmentación de tramas (definida, no implementada) no hace falta con 33 B y 140 B: cada reporte cabe en una sola trama.
