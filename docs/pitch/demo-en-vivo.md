# Demostración en vivo: cómo reproducirla, con tiempos y plan B

Complementa a [`guion.md`](guion.md) (qué decir y qué cifra respalda cada frase): este documento dice **qué teclear, qué debe aparecer, cuánto tarda** y qué hacer si falla. Todo usa **datos sintéticos y canales simulados** (lo que permite el §4.7), **no usa el modelo de lenguaje ni la red** (no gasta API) y se levanta con dos comandos.

## 0 · Antes (30 min antes; comprobarlo una vez)

```bash
cd /ruta/a/hackathon-asi
dart pub get
flutter devices                      # debe listar el simulador de iOS (o el emulador de Android) encendido
bash tool/expo.sh --build            # compila el tablero (1–2 min la primera vez) y deja todo arriba; luego Ctrl+C
```

- **Los nodos sirven el tablero ya compilado:** si cambió la interfaz hay que pasar `--build`, o la demostración enseña la versión anterior.
- **Permiso de ubicación del simulador (un toque, una vez):** la primera vez que la app se abre en iOS aparece un diálogo del sistema («¿Permitir a SARD utilizar tu ubicación?»). **Ningún script puede pulsarlo**: toque «Permitir al usar la app» antes de empezar. Para que el GPS sea de Manizales: `xcrun simctl location booted set 5.0689,-75.5174`.
- **No corra `bash tool/test_all.sh` con la demostración arriba:** comparten procesos y el simulador de carga puede hacer fallar un arranque (una vez un nodo no arrancó en 60 s con la máquina cargada). Las que usan otros puertos pueden correr al lado de `expo.sh` (8081/8082): `demo.sh` 8095/8096, T14 8094, ráfaga 8093, T18 8101/8102, T19 8111–8113, T20 ninguno. **Las que NO**: el recorrido H1 (`e2e_skeleton.dart`) usa 8081/8082 por omisión (`--port-base` lo cambia) y `tool/device_check.sh` usa 8081 y hace `pkill` de **todo** nodo en marcha, incluidos los de la demostración.

## 1 · El recorrido central (≈ 8 min)

**Arranque (hágalo ≤ 20 min antes de empezar):** en una terminal, que se queda abierta.

```bash
bash tool/expo.sh
```

El escenario es una **foto de AHORA**: dos zonas siguen reportando y **pasan a silencio solas 30 min después de arrancar**. Si la demostración se retrasa, reinicie (Ctrl+C y otra vez) o envíe un SOS desde el teléfono, que reaviva la zona.

| # | Escena | Qué se hace | Qué debe verse | Tiempo medido | Plan B |
|---|---|---|---|---|---|
| 1 | **Arranque** | `bash tool/expo.sh` | El cuadro final: `Nodo A … (123 eventos)`, `Nodo B … (123 eventos) ← se replican entre sí`, `Zonas en silencio ahora: 4` | ≈ 14 s con el tablero ya compilado | `bash tool/expo.sh --empty` (nodos vacíos) y `dart run packages/sim/bin/seed_scenario.dart --node http://localhost:8081 --now` |
| 2 | **El tablero** | Dos ventanas de Chrome (1440 × 900): `http://localhost:8081` (nodo A) y `http://localhost:8082` (nodo B) | Barra de triaje `3 P1 · 21 P2 · 16 P3`, «31 pendientes de decisión · la más antigua hace 5 h»; a la derecha, **«Situación»** con la red de nodos (`localhost:8082: Sincronizado`) y los recursos (10 unidades · 9 disponibles) | inmediato | La captura [`capturas/expo-mapa-silencio.png`](capturas/expo-mapa-silencio.png) y las láminas |
| 3 | **Primeras seis horas: el SOS** | En el simulador: `cd apps/mobile && flutter run -d <id-del-simulador> --dart-define=NODES=http://localhost:8081,http://localhost:8082` y un toque en SOS | La app dice «Guardado» sin esperar a la red; en el tablero aparece el reporte nuevo en pocos segundos y **los dos nodos muestran los mismos eventos** (`bash tool/expo_ctl.sh status`) | la 1.ª compilación tarda minutos (hágala antes); después, segundos | Emulador de Android: `--dart-define=NODES=http://10.0.2.2:8081,http://10.0.2.2:8082`; o el comando de `seed_scenario` de la fila 1 |
| 4 | **Silencio digital: la capa** | Mapa → botón **«Silencio»** (en la franja bajo el mapa) | **4 zonas rayadas**; el rótulo: «El silencio no es seguridad. 4 zonas en silencio (rayadas: reportaron y llevan 30 min o más sin reportar)». Una zona tuvo **un solo mensaje** (Villamaría) y otra **un urgente antes de callar** (Alta Suiza) | inmediato | [`capturas/expo-mapa-silencio.png`](capturas/expo-mapa-silencio.png) |
| 5 | **Lo que mide la capa (T20)** | `cd apps/node && dart run tool/t20_silencio.dart --seeds 20 --zones 60 --first-seed 100` | **Precisión 48,8 %**: de dos zonas marcadas, una es un apagón de verdad; **exhaustividad 89,1 %**. Las zonas poco habladoras se marcan por calma (78,5 % de falsas alarmas). H4 **no** se cumple y el informe lo dice | 2 s | `docs/resultados/t20-silencio.md` |
| 6 | **Pérdida del nodo** | `bash tool/expo_ctl.sh kill A` | `Nodo A muerto con kill -9 (…)`. La ventana de **B** sigue operativa con todo: franja amarilla «**Vista parcial.** Algún nodo no responde», el par en rojo («Sin respuesta · hace N s») y «Situación» con el aviso. La ventana de A queda en «Sin conexión» (**es lo esperado**: la página depende del nodo que la sirvió) | instantáneo | [`capturas/expo-nodo-caido.png`](capturas/expo-nodo-caido.png) es lo que debe verse en B. Si no aparece la franja: espere ≤ 3 s (el periodo de sondeo) |
| 7 | **Recuperación** | `bash tool/expo_ctl.sh start A` y luego `bash tool/expo_ctl.sh status` | `Nodo A de vuelta en 3 s, con su mismo disco.` y los dos nodos con el **mismo número de eventos** y `sincronizado` | ≈ 3 s + ≤ 3 s de réplica | Si `start` dice que ya escucha, `kill` no mató al servidor: `lsof -nP -iTCP:8081 -sTCP:LISTEN` |
| 8 | **Integración reproducible** | `PART=4 bash tool/demo.sh 42` | Partición, `kill -9`, reinicio y reconexión; al final `✓ misma semilla ⇒ misma huella (T15)` y `RTO (kill -9 → el nodo responde): ≈ 4,2 s`; convergencia ≈ 3 s | **53 s** (corre dos veces para comparar la huella) | Mostrar `docs/resultados/` y las láminas |

**Con A muerto, envíe otro SOS desde el teléfono** (escena 6, antes de levantarlo): la app lo reintenta contra el otro nodo de su lista y la idempotencia absorbe cualquier duplicado; al levantar A, `expo_ctl.sh status` muestra los dos con los mismos eventos. Es la escena que más enseña de *Silencio digital*.

## 2 · Extras (si sobra tiempo)

```bash
dart run packages/sim/bin/t14.dart --seeds 401 --out /tmp/t14.md          # 9 s · «ningún P1 fuera de la vista»: 0 en total (criterio del PDF: 0)
dart run packages/sim/bin/t19_tres_nodos.dart --out /tmp/t19.md           # 63 s · tres nodos, relevo y convergencia
```

**Pase siempre `--out /tmp/…`:** sin él, T19 sobrescribe `docs/resultados/t19-tres-nodos.md` (el informe versionado) y el repositorio queda sucio.

## 3 · Se muestra guardado, no en vivo

| Qué | Por qué no en vivo | Dónde |
|---|---|---|
| T18 · partición de 10 min con dos nodos | dura 10 min | `docs/resultados/t18-particion-larga.md` |
| `bash tool/test_all.sh` (2 000+ pruebas, análisis, H1, demostración, T12, T14, tablero web, códigos, despachador, recursos) | ≈ 6 min y usa los mismos procesos | su última salida: `TODO EN VERDE` |
| Modelo real (T06, T13, T07) | cuesta API y no se repite en una sala | `docs/resultados/modelo-real.md`, `reto4-juez.md` |

## 4 · Plan B por si falla algo

| Falla | Qué hacer |
|---|---|
| El simulador de iOS no abre la app | Emulador de Android (`emulator-5554`, con `10.0.2.2`); o `seed_scenario --now` (envía 8 reportes por HTTP, sin teléfono) |
| Un nodo no arranca (puerto ocupado o máquina cargada) | `lsof -nP -iTCP:8081 -iTCP:8082 -sTCP:LISTEN`; cerrar lo que sobre; repetir `expo.sh` |
| El tablero enseña una interfaz vieja | `bash tool/expo.sh --build` (los nodos sirven lo compilado) |
| No hay tiempo de nada en vivo | Las láminas (`SARD-pitch.pdf`) y las capturas; el video de respaldo **cuando se grabe** (todavía no existe) |

## 5 · Después

`Ctrl+C` en la terminal de `expo.sh` apaga los dos nodos y borra los datos temporales. Compruebe que no quedó nada: `lsof -nP -iTCP:8081 -iTCP:8082 -sTCP:LISTEN` no debe imprimir nada.

## 6 · Qué se ha ensayado y qué no (honesto)

| Parte | Estado |
|---|---|
| `expo.sh`, `expo_ctl.sh` (matar y levantar A), las dos ventanas del tablero, la capa «Silencio» y «Situación» con el escenario, T20, `demo.sh`, T14, T19 | **Ejecutadas de punta a punta** (10 nov 2026) con los tiempos de arriba, en una sola máquina y sin personas |
| La app abre en el simulador de iOS contra los dos nodos | **Verificado** (arranca y pide el permiso de ubicación) |
| El **toque en SOS** del simulador y la conmutación del teléfono al nodo B con A muerto | **Sin ensayar a mano** (un script no puede pulsar el simulador): ensáyelo usted antes |
| Tiempos con la carga real de la exposición (simulador + dos ventanas + dos nodos a la vez) | **Pendiente**: llene la tabla de abajo |

### Tabla de ensayos (llenarla)

| Fecha | Quién | Escenas que fallaron | Tiempo total | Observaciones |
|---|---|---|---|---|
| | | | | |
| | | | | |
| | | | | |
