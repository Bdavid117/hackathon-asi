# Video de respaldo de la demostración

**Estado: decidido, NO grabado, y este archivo NO se versiona (se queda en local por decisión del usuario).** Se graba **cuando los retos estén cumplidos**: después del último cambio de la interfaz y con el código congelado. Motivo: una captura vieja ya enseñó un defecto que estaba corregido (lección de la presentación), y un video no se puede retocar con un `sed`.

**Qué es y qué no es.** Es el *plan B* si la máquina, el emulador o el nodo fallan en vivo (tabla de riesgos del cap. 10 del PDF de arquitectura). **No sustituye** a `tool/demo.sh`: el entregable 7 del enunciado pide una demostración *reproducible* bajo al menos una condición adversa, y eso lo da el comando con su semilla («misma semilla ⇒ misma huella»), no un video. El video es la copia filmada de esa misma ejecución.

## Antes de grabar (lista de control)

1. Código congelado y `git status` limpio; anotar el hash del commit (`git rev-parse --short HEAD`): va en el nombre del archivo y en su ficha.
2. `bash tool/test_all.sh` en verde justo antes (sólo la primera corrida; el nodo de demostración del puerto 8081 debe estar parado). Si T12 falla, ver `docs/resultados/t12.md`; no grabar sobre una batería en rojo.
3. Tablero compilado de nuevo (`flutter build web --no-web-resources-cdn`) y las **capturas y láminas rehechas** si la interfaz cambió.
4. Datos de ejemplo con horas de ahora y con lo último del tablero (`seed_scenario.dart --now --extended`), para que el tablero diga «hace 7 min» y no «hace 90 d», y se vean la contradicción, la vía bloqueada en la ruta y la ambulancia 2 no disponible.
5. Pantalla a 1920×1080 o 1360×860, sin notificaciones (modo «No molestar»), sin otras pestañas con correo, sin terminales con historial a la vista.
6. **Nada sensible en pantalla:** ni la clave de la API (`~/.sard-anthropic-key`, `ANTHROPIC_API_KEY`), ni códigos de acceso reales, ni el correo de la cuenta. Si el nodo se arranca con `--llm on`, que la clave entre sólo por el entorno y que el comando no se vea.
7. Ensayar una vez sin grabar, con reloj. Los tiempos son una propuesta, no una medición.

## Cómo grabar cada fuente

| Qué | Herramienta |
|---|---|
| Tablero en Chrome y terminal (macOS) | Grabación de pantalla del sistema (`⌘⇧5`) o QuickTime → «Nueva grabación de pantalla» |
| App en el emulador de Android | `adb shell screenrecord /sdcard/paso1.mp4` (corta a los 180 s por archivo) y `adb pull /sdcard/paso1.mp4`; o el botón de grabar de los controles extendidos del emulador |
| App en el simulador de iOS (si se enseña) | `xcrun simctl io booted recordVideo --codec=h264 paso1-ios.mp4` |

Grabar por tomas cortas y unirlas después es más seguro que una sola toma de 5 minutos: si algo sale mal, se repite una toma, no todo.

## Tomas propuestas (≈ 5 min, ruta de «5 min» del guion)

Siguen los pasos de [`guion.md`](guion.md); cada toma lleva la cifra que respalda lo que se dice.

| # | Toma | Qué se ve | Cifra o prueba que se nombra |
|---|---|---|---|
| 1 | Alcance (10 s) | Título y una línea: «Datos sintéticos y canales simulados (enunciado §4.7). Emulador de Android.» | — |
| 2 | La app sin red (≈ 60 s) | Modo avión, un toque en SOS, «Guardado en tu teléfono»; matar la app y reabrirla (sigue ahí); devolver la red: «Enviado a un nodo» | T01: 6 `kill -9` sin perder lo dado por guardado; sale ≈ 1 s después de volver la señal |
| 3 | El tablero (≈ 120 s) | Barra de triaje, contadores, fila de «SOS sin detalle»; el mapa con las unidades; abrir el P2 con contradicción (los dos reportes, sin resolver); abrir el P1: por qué, observaciones, recomendación con «confirmar la ruta»; el panel «Recursos»; aprobar con un nombre | T13: 0 acciones inventadas; T14: 0 P1 fuera de la vista; T17: 0 falsos positivos (y su límite: es una medición modesta) |
| 4 | La condición adversa (≈ 90 s) | `PART=4 bash tool/demo.sh 42`: partición, `kill -9` con la ráfaga a medias, reinicio con su RTO, reconexión, «huellas idénticas» | T09: RTO 2,3–3,7 s; T10: convergencia 3,1–3,6 s; T15: misma semilla ⇒ misma huella |
| 5 | Lo que no cumplimos (≈ 45 s) | La lámina «Lo que no cumplimos» | Sus cifras, con su límite |
| 6 | Cómo reproducirlo (≈ 20 s) | README y los comandos `test_all.sh` / `demo.sh` | — |

Regla del guion: **se dice lo medido y se dice dónde termina.** Un jurado que encuentra un límite que no se mencionó deja de creer el resto.

## Después de grabar

- Ver el video **completo**, con sonido, antes de darlo por bueno: que se lean las cifras, que no haya datos sensibles y que la huella final coincida con la de la ejecución.
- Nombre: `SARD-demo-respaldo-<fecha>-<hash>.mp4`. Los `*.mp4` y `*.mov` están en `.gitignore`: **el video no va al repositorio** (pesa) y se guarda aparte.
- **Dónde alojarlo se decide con la persona del equipo, no se sube a ningún servicio sin preguntar.** El repositorio es público: un enlace en el README lo vería cualquiera, así que el video no debe llevar nada que no se quiera público.
- Anotar en este archivo la fecha, el commit grabado y el lugar donde quedó, y cambiar el estado de arriba.
