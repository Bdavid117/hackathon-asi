# SARD · Bloque B2 · Transporte real · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (el usuario prefiere ejecución inline). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el cliente se comporte bien en las condiciones del enunciado (ventanas breves, pérdida alta, batería baja) y que eso se **mida**: aging y cuota anti-inanición, ventanas y retardo simulados, bytes por reporte confirmado, modos de energía con batería real, ubicación real con calidad y envío al volver la conectividad.

**Architecture:** La lógica nueva vive en paquetes de Dart puro (`client_core`, `sim`) con tiempo virtual para que las pruebas sean deterministas y rápidas; la app sólo conecta plugins (batería, GPS, conectividad) a esa lógica por interfaces.

**Tech Stack:** Dart 3.11.5, Flutter 3.41.9; nuevos plugins en la app: `battery_plus`, `geolocator`, `connectivity_plus` (versiones vigentes en pub.dev al instalarlos).

**Spec:** `docs/SARD-arquitectura-app-movil.pdf` v0.2 (§5.5 planificador, §5.6 ahorro de batería, §7.4 parámetros, §9.2 pruebas T02–T04 y T11) y `docs/adr/0001-desarrollo-individual-dart.md`. Continúa `docs/superpowers/plans/2026-11-08-sard-b0-b1.md`.

## Global Constraints

- Las restricciones de B0/B1 siguen vigentes (paquetes compartidos en Dart puro; `device_id` nunca como `int`; SQLite WAL + `synchronous=FULL`; confirmar sólo tras el `commit`; nunca descartar un reporte por su prioridad; textos de UI en español, identificadores en inglés).
- **Cuota anti-inanición:** 1 de cada 5 posiciones del lote es el pendiente más antiguo (PDF §7.4).
- **Envejecimiento:** cada 10 minutos de espera sube un nivel la prioridad efectiva (mínimo P1). Valor inicial mío, a calibrar con T11.
- **Ventana de envío:** hasta 8 tramas en vuelo (ya implementado).
- **Modos de energía** (PDF §5.6): *normal* con batería ≥ 20 %; *ahorro* con < 20 % (umbral del enunciado); *sólo SOS* con < 5 % (propuesta mía a validar).
- **Calidad de ubicación** según precisión horizontal: ≤ 10 m, ≤ 50 m, ≤ 200 m, ≤ 1 km, > 1 km (PDF §7.2). Una lectura puntual con plazo de 8 s; la app **nunca inventa** coordenadas.
- **El SOS se guarda al instante:** nada de esperar a un GPS ni a la red para confirmar «Guardado». La ubicación fresca llega como revisión posterior.
- **Batería:** `batteryQ = round(porcentaje × 15 / 100)` (4 bits).
- **Metas de las pruebas** (PDF §9.2, sugeridas): T02 SOS ≤ 40 B y con texto ≤ 160 B; T03 curva de entrega con pérdida 0/30/60/90 %; T04 SOS en la primera ventana de 3 s cada 60 s ≥ 95 %; T11 sin inanición.
- **Commits:** autorizados por el usuario; un commit por tarea, mensaje en español con prefijo convencional.

## Review Focus

1. **Una ventana que se cierra con tramas en vuelo:** lo que no recibió respuesta vuelve a la cola con su espera; nada se pierde ni se duplica en el nodo (Tareas 20 y 21).
2. **Llamadas simultáneas a `pump()`** (temporizador, toque de SOS y reconexión a la vez): no se doble-cuentan intentos ni se reenvía la misma trama dos veces (Tarea 20).
3. **Un solo reporte antiguo y de baja prioridad frente a una avalancha de P1:** acaba saliendo dentro de la cuota (Tarea 19).
4. **GPS denegado, apagado o sin fix en 8 s:** el SOS sale igual con ubicación «ninguna» y se corrige después sin duplicar el reporte (Tarea 23).
5. **Batería desconocida** (el plugin devuelve nulo o falla): se asume modo normal y el campo viaja con el valor marcador, no con un número inventado (Tarea 22).

## Estructura de archivos

```
packages/client_core/lib/src/outbox.dart          (modifica) aging + cuota en due()
packages/client_core/lib/src/send_scheduler.dart  (modifica) guarda de reentrada + TransportStats
packages/client_core/lib/src/transport_stats.dart TransportStats
packages/client_core/lib/src/power_mode.dart      PowerMode, powerModeFor, batteryQFromPercent
packages/client_core/lib/src/location.dart        LocationFix, LocationProvider, locQualityFromAccuracy
packages/client_core/lib/src/pump_trigger.dart    PumpTrigger (reconexión → pump)
packages/sim/lib/src/virtual_clock.dart           VirtualClock
packages/sim/lib/src/windowed_channel.dart        WindowedChannel, DelayedChannel
packages/sim/lib/src/fake_node.dart               FakeNodeChannel (nodo en memoria con ACK real)
packages/sim/bin/transport_report.dart            genera docs/resultados/b2.md (T02–T04, T11)
apps/mobile/lib/…                                 proveedores reales (batería, GPS, conectividad) y modos
```

---

### Task 18: Android en el emulador

**Files:** ninguno (verificación).

**Interfaces:** Consumes: licencias de Android aceptadas; `integration_test/app_test.dart` y `main_test.dart`. Produces: la confirmación de que `package:sqlite3` y la app funcionan en Android.

- [ ] **Step 1: Compilar.** Run: `cd apps/mobile && flutter build apk --debug` — Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`. Si Gradle protesta por una licencia, es la que falta aceptar al usuario.
- [ ] **Step 2: Arrancar el AVD.** Run: `flutter emulators --launch MediumAndroid` y esperar a que `flutter devices` liste `emulator-5554`.
- [ ] **Step 3: Pruebas de integración en Android.** Con un nodo en el anfitrión (`dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A-and`): `flutter test integration_test/app_test.dart -d emulator-5554 --dart-define=NODES=http://10.0.2.2:8081` y lo mismo con `main_test.dart` — Expected: `All tests passed!` ambos. Si `sqlite3` no carga la biblioteca nativa, probar `sqlite3_flutter_libs` y anotarlo en el ADR.

---

### Task 19: Envejecimiento y cuota anti-inanición en la bandeja

**Files:**
- Modify: `packages/client_core/lib/src/outbox.dart` (`due`)
- Test: `packages/client_core/test/outbox_test.dart`

**Interfaces:**
- Produces: `List<OutboxEntry> due(DateTime now, {int limit = 8, Duration agingStep = const Duration(minutes: 10), int quotaEvery = 5})`. Prioridad efectiva = `max(0, prioHint − ⌊(now − createdAt) / agingStep⌋)`. Orden: prioridad efectiva, luego `createdAt`, luego `frameSeq`. **Cuota:** en cada grupo de `quotaEvery` posiciones del lote (la 5.ª, 10.ª…), si el pendiente más antiguo vencido no está ya incluido, ocupa esa posición.

- [ ] **Step 1: Escribir las pruebas que fallan** (nombres exactos): `el envejecimiento sube la prioridad de lo que espera` (un P4 creado hace 35 min compite como P1: con un P3 reciente y límite 1, sale el P4 viejo); `la cuota hace salir al más antiguo aunque haya una avalancha de P1` (1 P4 de hace 5 min y 30 P1 recientes; con `limit: 5` y `agingStep` enorme, el lote de 5 incluye el P4 en la posición 5); `sin la cuota un lote de 4 sólo lleva P1` (con `limit: 4` no hay cuota); `no repite entradas ni excede el límite`; `lo que aún no venció su espera no entra por la cuota`.
- [ ] **Step 2: Verificar que fallan.** Run: `cd packages/client_core && dart test test/outbox_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implementar** `due` leyendo las candidatas vencidas (`state='queued'` y `next_try_at` vencido) y ordenándolas en Dart con la prioridad efectiva; aplicar la cuota sobre la lista ordenada.
- [ ] **Step 4: Verificar.** Run: `dart test` — Expected: PASS (las pruebas anteriores de `due` siguen en verde: con `createdAt` reciente el orden no cambia).

---

### Task 20: Guarda de reentrada y estadísticas de transporte

**Files:**
- Create: `packages/client_core/lib/src/transport_stats.dart`
- Modify: `packages/client_core/lib/src/send_scheduler.dart`, `packages/client_core/lib/sard_client_core.dart`
- Test: `packages/client_core/test/send_scheduler_test.dart`

**Interfaces:**
- Produces: `class TransportStats { int framesSent; int bytesOut; int bytesIn; int acked; int failed; double? get bytesPerAcked; }`; `SendScheduler.stats` (`TransportStats`); `pump()` con **guarda de reentrada**: si ya hay un `pump` en curso, la llamada devuelve `0` inmediatamente sin enviar ni contar nada.
- `bytesOut` suma `frame.length` por **cada envío** (reintentos incluidos); `bytesIn` suma el largo de cada respuesta recibida (válida o no); `bytesPerAcked` = `(bytesOut + bytesIn) / acked`, `null` si `acked == 0`.

- [ ] **Step 1: Escribir las pruebas que fallan:** `un SOS entregado a la primera cuesta 33 B de ida y 22 B de vuelta` (con un nodo falso que acusa: `bytesOut 33`, `bytesIn 22`, `bytesPerAcked 55.0`); `los reintentos suman bytes de ida` (dos fallos y un éxito: `bytesOut 99`, `failed 2`); `dos pump simultáneos no envían dos veces` (con un canal lento y dos llamadas concurrentes, el canal recibe 1 llamada y el segundo `pump` devuelve 0); `una respuesta inválida cuenta sus bytes y es un fallo`.
- [ ] **Step 2: Verificar que fallan.** Run: `dart test test/send_scheduler_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implementar.**
- [ ] **Step 4: Verificar.** Run: `dart test` — Expected: PASS.

---

### Task 21: Tiempo virtual, ventanas, retardo y la medición T02–T04

**Files:**
- Create: `packages/sim/lib/src/virtual_clock.dart`, `windowed_channel.dart`, `fake_node.dart`, `packages/sim/bin/transport_report.dart`
- Modify: `packages/sim/lib/sard_sim.dart`
- Test: `packages/sim/test/windowed_channel_test.dart`, `packages/sim/test/transport_scenarios_test.dart`

**Interfaces:**
- Produces:
  - `class VirtualClock { VirtualClock(DateTime start); DateTime now(); void advance(Duration d); }`
  - `class WindowedChannel implements Channel { WindowedChannel(Channel inner, {required VirtualClock clock, required Duration open, required Duration closed, DateTime? epoch}); }` — en la fase abierta delega; en la cerrada devuelve `null` sin entregar. La fase abierta es `[epoch + k·(open+closed), epoch + k·(open+closed) + open)`.
  - `class FakeNodeChannel implements Channel { FakeNodeChannel(Uint8List key); int get received; }` — decodifica la trama, la guarda (set por `(reportKey, rev)`), y responde un ACK real con `AckTracker`; ignora tramas inválidas (devuelve `null`).
  - Escenarios (en el test): `entrega bajo pérdida 0/30/60/90 %` (T03), `primer SOS en una ventana de 3 s cada 60 s` (T04), `bytes por reporte confirmado` (T02).

- [ ] **Step 1: Escribir las pruebas que fallan.** `windowed_channel_test`: fase abierta delega, cerrada devuelve `null` sin llamar al interno, el borde exacto `open` ya está cerrado, el ciclo se repite. `transport_scenarios_test` con `VirtualClock` + `SendScheduler(clock: …)` y espera simulada (avanzar 100 ms por iteración): **T03** con semilla fija y 20 reportes (10 P1 y 10 P4), pérdida 0 → entrega 100 % en ≤ 1 s virtual; con 0.3 y 0.6 → 100 % antes de 10 min virtuales y los P1 salen antes que los P4 en promedio; con 0.9 → entrega ≥ 95 % antes de 6 h virtuales (sólo se reporta la curva, no se exige otra cosa); **T04** con ventana de 3 s abierta cada 60 s, sin pérdida dentro de la ventana, 100 SOS creados en instantes aleatorios (semilla fija) → el porcentaje que sale en **la primera ventana que se abre tras su creación** es ≥ 95 %; **T02** sin pérdida: bytes por reporte confirmado = 55,0.
- [ ] **Step 2: Verificar que fallan.** Run: `cd packages/sim && dart test` — Expected: FAIL.
- [ ] **Step 3: Implementar** las tres clases y un `main` en `transport_report.dart` que ejecute los mismos escenarios y escriba `docs/resultados/b2.md` con las tablas (curva de entrega, latencias p50/p95 de P1, bytes por reporte confirmado).
- [ ] **Step 4: Verificar.** Run: `dart test` y `dart run bin/transport_report.dart` — Expected: PASS y `b2.md` generado.

---

### Task 22: Modos de energía con batería real

**Files:**
- Create: `packages/client_core/lib/src/power_mode.dart`; en la app `lib/power.dart`
- Modify: `apps/mobile/lib/app.dart`, `sos_screen.dart`, `main.dart`, `pubspec.yaml` (añadir `battery_plus`)
- Test: `packages/client_core/test/power_mode_test.dart`, `apps/mobile/test/power_mode_ui_test.dart`

**Interfaces:**
- Produces: `enum PowerMode { normal, saver, sosOnly }`; `PowerMode powerModeFor(int? percent)` (`null` → `normal`; < 5 → `sosOnly`; < 20 → `saver`); `int batteryQFromPercent(int? percent, {int unknown = 15})`; en la app `typedef BatteryReader = Future<int?> Function()` inyectable en `SardApp` y el modo mostrado con la clave `power_banner` (texto «Modo ahorro de batería» / «Sólo SOS: batería muy baja»); en `sosOnly` se ocultan los chips y la lista.
- El modo *ahorro* alarga el refresco de la lista a 5 s; el reporte lleva `batteryQ` real.

- [ ] **Step 1: Escribir las pruebas que fallan.** `power_mode_test`: fronteras 100/20/19/5/4/0 y `null`; `batteryQFromPercent(100) == 15`, `(0) == 0`, `(50) == 8`, `(null) == 15`. `power_mode_ui_test`: con lector 15 % se ve `power_banner` «Modo ahorro de batería» y los chips siguen; con 3 % no hay chips ni lista pero sí `sos_button`; con lector que lanza una excepción o devuelve `null` no hay banner y el SOS funciona; el reporte creado con el lector a 50 % lleva `batteryQ == 8` (decodificar la trama).
- [ ] **Step 2: Verificar que fallan.** Run: `dart test` en `client_core` y `flutter test` en `apps/mobile` — Expected: FAIL.
- [ ] **Step 3: Implementar.** `main.dart` usa `battery_plus` (`Battery().batteryLevel`) como lector real.
- [ ] **Step 4: Verificar.** Run: ambas suites + `flutter analyze` — Expected: PASS.

---

### Task 23: Ubicación real con calidad y corrección posterior

**Files:**
- Create: `packages/client_core/lib/src/location.dart`; en la app `lib/location_geolocator.dart`
- Modify: `apps/mobile/lib/app.dart`, `main.dart`, `pubspec.yaml` (añadir `geolocator`), `android/app/src/main/AndroidManifest.xml` (permisos), `ios/Runner/Info.plist` (`NSLocationWhenInUseUsageDescription`)
- Test: `packages/client_core/test/location_test.dart`, `apps/mobile/test/location_flow_test.dart`

**Interfaces:**
- Produces: `class LocationFix { final double lat, lon; final double accuracyMeters; final DateTime at; }`; `abstract interface class LocationProvider { Future<LocationFix?> lastKnown(); Future<LocationFix?> fresh({Duration timeout}); }`; `LocQuality locQualityFromAccuracy(double meters)`; en `SardApp` el parámetro `LocationProvider? location`.
- Flujo: al tocar SOS se usa `lastKnown()` **sólo si tiene menos de 2 min**; el reporte se guarda sin esperar. Si no había ubicación utilizable, `fresh(timeout: 8 s)` se pide en segundo plano y, si llega, se encola una **revisión** (mismos campos + ubicación) del mismo reporte. Si hay un fix reciente no se pide otro.

- [ ] **Step 1: Escribir las pruebas que fallan.** `location_test`: `locQualityFromAccuracy` en 10 / 10.1 / 50 / 50.1 / 200 / 200.1 / 1000 / 1000.1 m → `within10m, within50m, within50m, within200m, within200m, within1km, within1km, over1km`; negativo o NaN → `none`. `location_flow_test` con un `LocationProvider` falso: (a) con `lastKnown` de hace 30 s y ±20 m el reporte 0 sale con `within50m` y coordenadas, y no se pide `fresh`; (b) con `lastKnown` de hace 10 min se ignora: el reporte 0 sale `none` y, al llegar `fresh`, hay una revisión 1 con coordenadas **del mismo reporte** (`reportKey` igual) y sólo 2 entradas en total; (c) con `fresh` que devuelve `null` (sin fix en el plazo) no hay revisión y el SOS quedó guardado; (d) con un proveedor que lanza una excepción el SOS se guarda igual.
- [ ] **Step 2: Verificar que fallan.** Run: ambos — Expected: FAIL.
- [ ] **Step 3: Implementar.** El proveedor real usa `Geolocator.getLastKnownPosition()` y `Geolocator.getCurrentPosition(timeLimit: …)`, comprobando permisos y servicio **sin** pedir permisos durante el SOS (se piden al primer arranque).
- [ ] **Step 4: Verificar.** Run: suites + `flutter analyze` — Expected: PASS.

---

### Task 24: Enviar al volver la conectividad

**Files:**
- Create: `packages/client_core/lib/src/pump_trigger.dart`
- Modify: `apps/mobile/lib/main.dart`, `pubspec.yaml` (añadir `connectivity_plus`)
- Test: `packages/client_core/test/pump_trigger_test.dart`

**Interfaces:**
- Produces: `class PumpTrigger { PumpTrigger(this._pump, {Duration minGap = const Duration(milliseconds: 500), DateTime Function()? clock}); Future<void> onConnectivity(bool online); Future<void> onEvent(); }` donde `_pump` es `Future<int> Function()`; al pasar de sin red a con red lanza `pump` de inmediato; ignora eventos repetidos dentro de `minGap`; nunca solapa dos ejecuciones.

- [ ] **Step 1: Escribir las pruebas que fallan:** `al volver la red se envía de inmediato`; `un evento sin red no envía`; `los eventos repetidos dentro de minGap se ignoran`; `no solapa dos pump`.
- [ ] **Step 2: Verificar que fallan.** Run: `dart test test/pump_trigger_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implementar** y cablear en `main.dart` con `Connectivity().onConnectivityChanged` (online = algún resultado distinto de `none`) además del temporizador de 3 s.
- [ ] **Step 4: Verificar.** Run: `bash tool/test_all.sh` — Expected: `TODO EN VERDE`.

---

## Cierre del bloque

- [ ] Ejecutar `bash tool/test_all.sh`, las dos pruebas de integración en iOS y (si las licencias lo permiten) en Android.
- [ ] Actualizar `docs/resultados/` (`b2.md` generado) y el README.
- [ ] Revisión final del bloque (pasada propia + revisor externo).

## Auto-revisión

- **Cobertura del spec:** T02 (Tarea 21), T03 (21), T04 (21), T11 aging/cuota (19), modos de energía §5.6 (22), ubicación honesta §5.3 (23), reintento al volver la señal §5.5 (24). Fuera de B2: deduplicación semántica y modelo de lenguaje (B3), resiliencia avanzada (B4).
- **Consistencia de tipos:** `TransportStats` (20) se consume en el informe (21); `PowerMode` y `batteryQFromPercent` (22) alimentan `NewReport.batteryQ`; `LocationProvider`/`LocationFix` (23) alimentan `NewReport.locQuality/lat/lon`.
- **Riesgo declarado:** `geolocator`, `battery_plus` y `connectivity_plus` se verifican con widgets e interfaces falsas; el comportamiento real en dispositivo se comprueba con el emulador/simulador (ubicación y batería simuladas), no con hardware.
