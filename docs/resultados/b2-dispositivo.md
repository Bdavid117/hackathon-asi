# B2 · Verificación en dispositivo (emulador de Android y simulador de iOS)

**Fecha:** 8 de noviembre de 2026 · **Dispositivos:** Android 17 (API 37, emulador `MediumAndroid`, arm64) e iOS 27 (simulador iPhone 17) · **Nodo:** el real (`apps/node`), en el equipo anfitrión.

Todo corre el `main()` **real** de la app (plugins reales de batería, GPS y conectividad, `path_provider`, SQLite nativo), no un widget armado en la prueba.

## Cómo reproducirlo

```bash
bash tool/device_check.sh android emulator-5554     # app_test, main_test, gps_test
bash tool/device_check.sh ios <UDID del simulador>
bash tool/android_offline_check.sh                  # sin red → guardado → vuelve la red → sale solo
bash tool/android_battery_check.sh                  # batería real 100 / 15 / 3 % → tres modos
```

## Resultados

| Qué se verifica | Android | iOS | Evidencia |
|---|---|---|---|
| SOS guardado → HTTP real → ACK → «Enviado a un nodo» → reabrir conserva el estado (`app_test`) | ✓ | ✓ | `package:sqlite3` funciona en ambos sin `sqlite3_flutter_libs` |
| El nodo registra `received → normalized → triage.assessed` por cada trama (`main_test`) | ✓ | ✓ | terna completa por trama, también en las revisiones |
| GPS real: el nodo termina con la ubicación del dispositivo (`gps_test`) | ✓ | ✓ | ubicación fijada en 5,0703 / −75,5138; la cola del nodo muestra 5,07030 / −75,51380 (cuantizada a ≈ 1,2 m) |
| Vía del GPS | ✓ | — | eventos del nodo: `received rev 0` **sin** ubicación (guardado al instante) → `received rev 1` **con** ubicación (revisión del mismo reporte) |
| **Sin conexión → guardado → vuelve la red → sale solo** (`offline_test`) | ✓ | — | con la red apagada el nodo recibió **0 eventos**; al devolverla, el reporte llegó **1 s después** y la app mostró «Enviado a un nodo» |
| Batería real → modos de energía (`battery_test`) | ✓ | — | 100 % → normal; 15 % → «Modo ahorro de batería»; 3 % → «Sólo SOS: batería muy baja» y sin indicadores |

## Hallazgos de esta verificación (y qué se hizo)

- **`main()` esperaba el diálogo del permiso de ubicación antes de pintar la app:** con el permiso sin responder no había botón SOS. Ahora el permiso se pide *después* de `runApp`. La prueba sin red lo destapó (estaba en rojo) y quedó en verde tras el arreglo.
- **Mi primera comprobación de batería falló por el método, no por la app:** `dumpsys battery set` sólo cambia el *broadcast*; la capacidad que lee el plugin se cambia con la consola del emulador (`adb emu power capacity N`). El script usa la consola.
- **`main_test` esperaba exactamente 3 eventos:** con el permiso de ubicación concedido cada SOS genera también su revisión con GPS (6 eventos = 2 ternas). Se corrigió la aserción para exigir ternas completas.
- **La licencia de Android que falta** (1 de 8) **no bloquea** compilar ni ejecutar en el emulador; sólo `flutter doctor` la señala.

## Cambios tras la revisión final de B2 (y su verificación)

- **Coalescencia de envíos.** `SendScheduler.pump()` y `PumpTrigger` ya no *descartan* un disparo que llega mientras hay un envío en curso: lo anotan y hacen **una** ronda de seguimiento al terminar (conservando la liberación de esperas de una reconexión). Antes, con un nodo lento (hasta 5 s por intento), un SOS o una reconexión podían esperar al siguiente temporizador. Pruebas: envío solapado atendido al terminar, coalescencia de seis disparos en una ronda, reconexión a mitad de envío (`pump → release → pump`).
- **El toque de SOS pasa por `PumpTrigger.onNewReport`:** no intenta enviar sin red (sin bloquearse en plazos inútiles) y nunca se descarta por el filtro anti-parpadeo.
- **Filtro anti-pánico:** varios toques en menos de 2 s son el mismo SOS (antes, 5 toques daban 5 reportes, contra «un reporte vivo por incidente»). Pasado el plazo, otro toque es otro reporte.
- **Modo «sólo SOS»:** sin lista, la pantalla confirma el estado del último reporte («Guardado en tu teléfono»).
- **Envejecimiento con tope en P2:** un caso leve muy antiguo ya no iguala a un P1 (la cuota 1 de cada 5 garantiza igualmente que no muera de inanición).
- **T04 medido con el coste real de un nodo inalcanzable:** ver `b2.md`. Con la red bien detectada el 100 % de los SOS sale en la primera ventana de 3 s; si el sistema dice que hay red pero el nodo no responde (intentos de 5 s), **baja al 20 %** (todos acaban saliendo en ventanas posteriores). El 100 % de antes era el caso ideal.
- Tras estos cambios se repitieron las 3 pruebas en Android y en iOS, la de sin red y la de batería: todas en verde.
- **Un fallo único sin explicar:** durante estos cambios una ejecución de `location_flow_test` falló una vez y no volvió a fallar (12 repeticiones aisladas y 3 de la suite completa, todas en verde). No tengo causa demostrada.

## Limitaciones declaradas

- **Son emuladores:** la ubicación y la batería están simuladas desde la consola del emulador; no se probó hardware real, ni radio real (BLE, SMS, LoRa), ni consumo de energía real.
- **Sin red en iOS:** el simulador comparte la red del anfitrión y no se puede apagar con una orden; el escenario sin conexión sólo se verificó en Android.
- **La batería de iOS no se puede fijar en el simulador**, así que los modos de energía sólo se verificaron con batería real en Android (en iOS, con lector falso en pruebas de widgets).
- **Los servicios en primer plano de Android no están implementados:** el envío depende de que la app esté viva (primer plano o recién pasada a segundo plano). Es la limitación declarada en el PDF §5.8 y no se ha resuelto.
- **Reintentos con enlace vivo y plazos de intento:** con 30 % de pérdida dentro de una ventana de 3 s sólo el 69 % de los SOS sale en la primera ventana (caso ideal) y mucho menos si el sistema dice que hay red pero el nodo no responde (`docs/resultados/b2.md`). Un reintento inmediato mientras el enlace responde y un plazo de intento más corto justo tras volver la señal lo mejorarían: siguiente paso, sin medir.
