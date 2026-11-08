# hackathon-asi · SARD

Repositorio del proyecto para la **Hackathon SARD** (Sistema Agéntico de Respuesta y Resiliencia ante Desastres), Expo ASI 2026, Universidad Nacional de Colombia | Sede Manizales.

El enunciado oficial es [`HackathonExpoASI2026.pdf`](HackathonExpoASI2026.pdf). Lo que se evalúa es un **recorrido completo de ocho pasos** (reporte ciudadano → almacenamiento local → transmisión intermitente → procesamiento por agentes → priorización → tablero → pérdida de un nodo → recuperación), no una pantalla aislada.

## Estado actual

**B0 y B1 implementados; hito H1 verificado.** Desarrolla una sola persona, con Flutter: **Dart de punta a punta**. Un reporte recorre los ocho pasos del enunciado (app → bandeja local → red con pérdida → nodo → agentes de reglas → tablero → pérdida de un nodo → recuperación). Lo verificado y lo que falta está en [`docs/resultados/h1.md`](docs/resultados/h1.md): 218 pruebas en verde más dos pruebas de integración en el simulador de iOS; **sin probar todavía en Android** (licencias del SDK sin aceptar) y **sin commits** (no autorizados).

| Qué | Dónde |
|---|---|
| Diseño: análisis del enunciado, arquitectura, protocolo, agentes, pruebas y plan (v0.2) | [`docs/SARD-arquitectura-app-movil.pdf`](docs/SARD-arquitectura-app-movil.pdf) |
| Decisión: desarrollo individual, Dart de punta a punta y corte de alcance | [`docs/adr/0001-desarrollo-individual-dart.md`](docs/adr/0001-desarrollo-individual-dart.md) |
| Plan de implementación de B0 y B1 | [`docs/superpowers/plans/2026-11-08-sard-b0-b1.md`](docs/superpowers/plans/2026-11-08-sard-b0-b1.md) |
| Resultados y limitaciones de B0/B1 | [`docs/resultados/h1.md`](docs/resultados/h1.md) |
| Oráculo del códec (genera los vectores de prueba) | [`docs/src/tools/frame_size.py`](docs/src/tools/frame_size.py) |

## Estructura

```
packages/protocol/     códec binario, ACK selectivo, Channel (Dart puro)
packages/client_core/  bandeja de salida durable, planificador, HttpChannel (Dart puro)
packages/agents/       triaje y normalización por reglas (Dart puro)
packages/sim/          canal con pérdida, NodeProcess y el recorrido E2E (Dart puro)
apps/node/             nodo: log de eventos, ingreso, API HTTP, replicación
apps/mobile/           app ciudadana (Flutter)
apps/dashboard/        tablero del coordinador (Flutter Web)
spikes/sqlite_kill/    prueba técnica: SQLite ante kill -9
tool/test_all.sh       toda la batería de pruebas
```

## Comandos

```bash
dart pub get                                   # resuelve el workspace
bash tool/test_all.sh                          # pruebas + análisis + recorrido H1 (≈ 1 min)

# Un nodo con el tablero (compilar el tablero antes)
(cd apps/dashboard && flutter build web --no-web-resources-cdn)
(cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A --web-root ../dashboard/build/web)

# La app (iOS: localhost; emulador de Android: 10.0.2.2)
(cd apps/mobile && flutter run -d <dispositivo> --dart-define=NODES=http://localhost:8081)

# Recorrido de punta a punta con pérdida de nodo
dart run packages/sim/bin/e2e_skeleton.dart --seed 42 --reports 60 --loss 0.3
```

## Resumen de la arquitectura

- **App móvil ciudadana** (Flutter; Android primero): offline-first y *store-and-forward*, SOS en un toque, bandeja de salida en SQLite, trama binaria de 33 B con identificador idempotente y reintentos con variación.
- **Nodos supervivientes** (Dart) sin líder: log de eventos que sólo crece, vistas derivadas y sincronización entre pares.
- **Tejido de seis agentes** con respaldo determinista; el de resiliencia no usa modelo de lenguaje y ninguno puede despachar. Los agentes de los primeros bloques son sólo reglas.
- **Tablero del coordinador** (Flutter Web) y **banco de pruebas** reproducible (datos sintéticos, simulador de canal, inyector de fallos).

Los paquetes compartidos (`protocol`, `client_core`, `agents`, `sim`) serán **Dart puro**, sin importar Flutter.

## Entorno de desarrollo

Flutter 3.41.9, Dart 3.11.5, AVD de Android `MediumAndroid` y simulador de iOS `SARD-iPhone` (iPhone 17, iOS 27). Pendiente: aceptar las licencias de Android (`flutter doctor --android-licenses`).

## Regenerar el PDF

Requiere Google Chrome, Python 3 y `pypdf`.

```bash
python3 docs/src/build.py              # genera docs/SARD-arquitectura-app-movil.pdf
python3 docs/src/tools/frame_size.py   # mide la trama binaria frente a JSON
```

Fuentes del documento: `docs/src/parts/*.html` (contenido), `docs/src/diagrams.py` (figuras), `docs/src/style.css` (estilo). Si Chrome está en otra ruta, definir la variable de entorno `CHROME`.

## Pendiente

El **plazo** de la hackathon (dimensiona el recorte de alcance) y la decisión de publicar el repositorio en un remoto.
