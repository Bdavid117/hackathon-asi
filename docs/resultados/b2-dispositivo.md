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
- **Reporte vivo y filtro anti-pánico:** varios toques en menos de 2 s son el mismo SOS (antes, 5 toques daban 5 reportes, contra «un reporte vivo por incidente»). Si el toque trae **banderas nuevas** (p. ej. «Atrapado» después del SOS), sale como **revisión del mismo reporte con la unión de banderas**; si no trae nada nuevo, no hace nada. Pasado el plazo, otro toque es otro reporte.
- **El reloj del teléfono no puede silenciar un SOS:** los plazos anti-pánico y anti-parpadeo tratan un tiempo transcurrido negativo (corrección de hora hacia atrás) como «hueco superado», y la hora de captura se acota al rango del protocolo (un reloj reiniciado a 1970 o desfasado ya no impide guardar). Antes, un reloj atrasado dejaba un SOS sin guardar.
- **Si guardar falla, se avisa** («No se pudo guardar el reporte. Vuelve a tocar SOS.») y el reintento inmediato **no** se descarta como duplicado de algo que nunca llegó a guardarse (probado con un bloqueo real de la base de datos).
- **Un disparo de envío descartado por el filtro anti-parpadeo se repite una vez** al terminar el hueco (con su liberación de esperas), en vez de perderse.
- **Modo «sólo SOS»:** sin lista, la pantalla confirma el estado del último reporte («Guardado en tu teléfono»).
- **Envejecimiento con tope en P2:** un caso leve muy antiguo ya no iguala a un P1 (la cuota 1 de cada 5 garantiza igualmente que no muera de inanición).
- **T04 medido con el coste real de un nodo inalcanzable:** ver `b2.md`. Con la red bien detectada el 100 % de los SOS sale en la primera ventana de 3 s; si el sistema dice que hay red pero el nodo no responde (intentos de 5 s), **baja al 20 %** (todos acaban saliendo en ventanas posteriores). El 100 % de antes era el caso ideal.
- Tras estos cambios se repitieron las 3 pruebas en Android y en iOS, la de sin red y la de batería: todas en verde.
- **Un fallo único sin explicar:** durante estos cambios una ejecución de `location_flow_test` falló una vez y no volvió a fallar (12 repeticiones aisladas y varias de la suite completa, todas en verde). **No se encontró la causa.**
- **Lo que NO se verificó en dispositivo:** la detección de red sólo se comprobó para «ningún transporte activo» (Wi-Fi y datos apagados). No se probó «Wi-Fi conectado pero el nodo no responde» ni una Wi-Fi local sin Internet, que es justo el escenario del peor caso de T04.

## Prueba manual en el emulador (usando la app como una persona)

Además de las pruebas automatizadas, usé la app a mano en el emulador de Android (`MediumAndroid`, 1080×2400) contra un nodo real que también servía el tablero: tocar indicadores y SOS, quitar y devolver la red, bajar la batería, tocar SOS repetidas veces; y la pantalla de arranque en el simulador de iOS. Capturas de pantalla en cada paso.

**Encontré y corregí un fallo real que ninguna prueba automática veía.** Al marcar «Atrapado» se le añadía una palomita, el chip se ensanchaba y todo el bloque de indicadores se reacomodaba; el toque siguiente, dado donde estaba «Herido», caía sobre «Atrapado» y lo **desmarcaba**. El SOS salía sin indicadores (`signals: []`). En una emergencia, con pulso inestable, los botones no pueden moverse bajo el dedo.
- Corrección: cuadrícula fija de 2 columnas × 3 filas, cada indicador de 52 dp de alto y con su casilla visible siempre (marcada o no), de modo que ni cambia de tamaño ni depende sólo del color.
- La prueba nueva (`sos_panel_layout_test.dart`, 4 casos, en 411 dp y 360 dp) **falló primero por la razón correcta**; mi primer intento de prueba pasaba sin arreglar nada porque medía antes de que terminara la animación de la palomita, y tuve que corregirla para que reprodujera el fallo.
- Tras corregirlo repetí el gesto exacto en el emulador: «Atrapado» + «Herido» + SOS llegó al nodo como **P1 `atrapado · herido`** con su ubicación como revisión 1.

**Lo que comprobé a mano y funciona:**
- Sin red (Wi-Fi y datos apagados): el SOS queda en «Guardado en tu teléfono», el nodo no recibe nada; al devolver la red llega **0,6 s después** como P2 `incendio`.
- Tres toques seguidos a SOS dan **un solo reporte**.
- Banners «Modo ahorro de batería» (15 %) y «Sólo SOS: batería muy baja» (3 %, con los indicadores ocultos); con 3 % el SOS sigue saliendo.
- Latencia del SOS hasta el nodo: 0,6 s (3 % y 100 %), 8 repeticiones seguidas a 0,1 s, y 0,4 s tras 150 s de inactividad.
- La cuadrícula se ve bien en iOS (iPhone con isla dinámica).

**Observaciones que NO corregí** (decisiones tuyas o de diseño; ninguna rompe el envío):
1. **Un SOS sin indicadores queda en P4, la urgencia más baja** (debajo de «vía bloqueada»). Está en la tabla de triaje documentada y probada, así que no es un accidente, pero en el tablero se ve claro: quien pulsa SOS sin dar detalles queda al final de la cola. «No saber» no debería ser lo mismo que «poco urgente». **Decisión pendiente tuya**: subir el SOS sin banderas a P3 o P2 cambia la tabla del PDF §5, `prioHintFromFlags` y sus pruebas.
2. Las revisiones automáticas (la ubicación que llega después) aparecen en la lista como filas aparte («Detalle #2») que la persona no creó; sería más claro plegarlas dentro de su SOS.
3. Sin señal el texto es «Guardado en tu teléfono»: no dice que **se enviará solo** al haber señal. Mejor: «Guardado — se enviará solo cuando haya señal».
4. En iOS el cuadro de permiso de ubicación aparece **antes del primer fotograma**, sobre una pantalla en blanco. No bloquea, pero la primera impresión es un cuadro sobre nada; convendría pedirlo después de pintar la pantalla.
5. La app lee la batería cada 60 s, así que un cambio de modo puede tardar hasta un minuto en reflejarse.
6. **Un retraso aislado sin explicar:** una vez, con 3 % de batería, el SOS tardó más de 4 s en llegar al nodo; en 12 repeticiones posteriores (3 %, 100 %, tras inactividad) no volvió a pasar. No tengo causa demostrada.

## Mejora de la interfaz (a petición: «más amigable con el usuario»)

Partí de lo que molestó al usar la app a mano (observaciones 2 a 4 de la sección anterior) y rediseñé la pantalla pensando en una persona con miedo, prisa y poca batería. Detalle en el PDF §5.3.

**Qué cambió:** un aviso = una tarjeta (se acabaron los «Detalle #N»); el estado justo debajo del botón con una frase de qué hacer («Sale solo… No hace falta volver a tocar»); franja de «sin señal»; indicadores con icono, casilla siempre visible y marcables **después** del SOS (hasta 10 min, salen como actualización del mismo aviso, lo enviado se ve en verde y no se quita); vibración al tocar SOS; etiquetas para lector de pantalla; paleta con contrastes medidos; permiso de ubicación pedido tras pintar la primera pantalla.

**Un segundo fallo de «botones que se mueven», esta vez causado por mi propio rediseño, encontrado otra vez usando la app.** Toqué «Atrapado» y 0,6 s después «Herido», pero «Herido» ya no estaba allí: al llegar el GPS la tarjeta de estado crecía ~40 px y empujaba toda la cuadrícula. Además la cuadrícula saltaba ~177 dp al pasar del texto de ayuda a la tarjeta tras el primer SOS. Corrección: zona de estado de altura constante (el titular se ajusta al ancho, la explicación tiene hueco para 3 líneas, la hora y la ubicación van en una línea). La prueba de regresión mide la posición de un indicador a través de SOS, GPS, acuse del nodo y detalle añadido; falló primero (−177 dp, luego −69 dp con la tipografía ancha de pruebas, que resultó ser un buen estresor de «teléfono estrecho o letra grande») y ahora pasa.

**Cómo se verificó:** 351 pruebas automáticas; las 3 de integración en Android y en iOS, la de sin red y la de batería, repetidas con la pantalla nueva; y a mano en el emulador con capturas: pantalla vacía, SOS sin red (franja ámbar + «Guardado en tu teléfono»), red de vuelta (salió 0,6 s después), SOS + dos indicadores en ráfaga (llegaron al nodo como un solo aviso P2 `herido, incendio`), modos de batería 15 % y 3 %, y el ancho del iPhone.

**Una confesión de método:** escribí la interfaz antes que las pruebas de lo nuevo (detalles después del SOS, tarjeta, franja de sin señal), lo que va contra el ciclo prueba-primero. Lo remedié escribiendo después las pruebas y **estropeando a propósito** la función para comprobar que las pruebas la detectan: desactivar «detalles después del SOS», dejar que un reloj que retrocede cuente como «vivo» y permitir re-enviar un indicador ya enviado hicieron fallar 4, 1 y 1 pruebas respectivamente. Las pruebas de agrupación por incidente y de la bandeja (`reportOf`) sí se escribieron antes.

**Sigue pendiente** (de la sección anterior): el SOS sin indicadores queda en P4 (decisión tuya) y la batería se lee cada 60 s. **Nuevo, sin resolver:** las franjas de aviso (sin señal, batería) empujan el contenido hacia abajo al aparecer, y con letra del sistema muy grande la zona de estado crece; los wireframes del PDF son el boceto de partida y no se redibujaron.

## Limitaciones declaradas

- **Son emuladores:** la ubicación y la batería están simuladas desde la consola del emulador; no se probó hardware real, ni radio real (BLE, SMS, LoRa), ni consumo de energía real.
- **Sin red en iOS:** el simulador comparte la red del anfitrión y no se puede apagar con una orden; el escenario sin conexión sólo se verificó en Android.
- **La batería de iOS no se puede fijar en el simulador**, así que los modos de energía sólo se verificaron con batería real en Android (en iOS, con lector falso en pruebas de widgets).
- **Los servicios en primer plano de Android no están implementados:** el envío depende de que la app esté viva (primer plano o recién pasada a segundo plano). Es la limitación declarada en el PDF §5.8 y no se ha resuelto.
- **Reintentos con enlace vivo y plazos de intento:** con 30 % de pérdida dentro de una ventana de 3 s sólo el 69 % de los SOS sale en la primera ventana (caso ideal) y mucho menos si el sistema dice que hay red pero el nodo no responde (`docs/resultados/b2.md`). Un reintento inmediato mientras el enlace responde y un plazo de intento más corto justo tras volver la señal lo mejorarían: siguiente paso, sin medir.
