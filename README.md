# hackathon-asi · SARD

Repositorio del proyecto para la **Hackathon SARD** (Sistema Agéntico de Respuesta y Resiliencia ante Desastres), Expo ASI 2026, Universidad Nacional de Colombia | Sede Manizales.

El enunciado oficial es [`HackathonExpoASI2026.pdf`](HackathonExpoASI2026.pdf). Lo que se evalúa es un **recorrido completo de ocho pasos** (reporte ciudadano → almacenamiento local → transmisión intermitente → procesamiento por agentes → priorización → tablero → pérdida de un nodo → recuperación), no una pantalla aislada.

## Estado actual

**B0 a B5 implementados y medidos.** B4 y B5 —la app captura personas y frase; el nodo calcula incidentes con la recomendación del agente 6 y la aprobación registrada; el tablero del coordinador; el reparto del trabajo caro entre nodos; la ráfaga de 10 000 reportes y la demostración con una condición adversa— están en [`docs/resultados/b5.md`](docs/resultados/b5.md) (decisiones y mutaciones en [`b5-decisiones.md`](docs/resultados/b5-decisiones.md)). **Lo que NO se logró o no se probó:** el modelo de lenguaje nunca se consultó de verdad (todo con un servidor falso); el agrupamiento casi no fusiona, así que la ventaja del tablero es de orden y no de agrupación; no hubo prueba con coordinadores; las particiones fueron de 5–20 s; quien aprueba no está autenticado y la clave de integridad es compartida. ⚠️ En B3, **dos de los tres criterios medidos no se cumplen** (T06 recall de P1 78,5 % frente a 95 %; T07 sólo cumple «falsa fusión ≤ 1 %» en conjunto y porque casi no agrupa: una de cinco semillas nuevas llega a 2,9 %) y se reportan así, con su diagnóstico, en [`docs/resultados/b3.md`](docs/resultados/b3.md). Los datos son sintéticos y el modelo de lenguaje no se probó contra la API real. **`--llm on` envía el texto libre de los ciudadanos a un tercero sin redactar datos personales** (apagado por defecto; ver PDF §8). Desarrolla una sola persona, con Flutter: **Dart de punta a punta**. Un reporte recorre los ocho pasos del enunciado y la app se comporta bien en sus condiciones: **se guarda sin red y sale solo al volver la señal** (en el emulador de Android: 1 s tras devolver la red), usa **GPS y batería reales** (ubicación como revisión del mismo reporte; modos normal, ahorro y sólo SOS) y reparte el envío con **envejecimiento y cuota anti-inanición**.

- **1 166 pruebas automáticas** (el protocolo se cuenta en VM y en Chrome) en verde (`bash tool/test_all.sh`) más pruebas de integración en el emulador de Android y el simulador de iOS (`tool/device_check.sh`, `tool/android_offline_check.sh`, `tool/android_battery_check.sh`).
- **Sin probar en hardware real ni con radio real** (todo en emuladores).

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
| Guion de la demostración y del pitch | [`docs/pitch/guion.md`](docs/pitch/guion.md) |
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
tool/test_all.sh       toda la batería de pruebas (≈ 4 min)
tool/demo.sh           demostración adversa reproducible (partición, kill -9, decisiones contradictorias, misma semilla ⇒ misma huella)
tool/web_smoke.sh      el tablero compilado, abierto en Chrome sin cabeza
tool/device_check.sh   pruebas de integración en Android o iOS contra un nodo real
tool/android_*_check.sh  sin red → sale solo; batería real → modos
```

## Comandos

```bash
dart pub get                                   # resuelve el workspace
bash tool/test_all.sh                          # pruebas + análisis + H1 + demostración + T12 + T14 + tablero web (≈ 4 min)

# Un nodo con el tablero (compilar el tablero antes)
(cd apps/dashboard && flutter build web --no-web-resources-cdn)
(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --web-root ../dashboard/build/web --resources ../../config/recursos.json)
dart run packages/sim/bin/seed_scenario.dart            # opcional: 8 incidentes de ejemplo para ver el tablero

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
- **Tejido de seis agentes** con respaldo determinista; el de resiliencia no usa modelo de lenguaje y ninguno puede despachar. Todos funcionan hoy **sólo con reglas**; el puerto del modelo existe (apagado por omisión) y se probó únicamente con un servidor falso.
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

- **Acceso del jurado al repositorio:** está publicado en GitHub (`Bdavid117/hackathon-asi`), pero el enunciado pide que sea «accesible al jurado»: eso se concede desde la configuración del repositorio (hacerlo público o añadir a cada integrante del jurado como colaborador).
- **Un canal de entrada para el despachador** (radio de onda corta o informes manuales): hoy el nodo sólo recibe tramas binarias de la app, y `radio` como fuente sólo existe en el generador sintético.
- **Para que SARD sea más que una demostración:** probar el modelo con la API real, un agrupamiento que de verdad fusione (las cinco fuentes independientes de T08 siguen sin agruparse de punta a punta), una prueba con coordinadores, el mapa de cobertura que advierta de que el silencio no es seguridad (pospuesto), la redacción de datos personales antes de enviar texto al modelo, y la fragmentación de tramas (definida, no implementada).
