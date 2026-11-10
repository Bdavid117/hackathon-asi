# Video de presentación de SARD (≤ 1 minuto)

Un video de presentación de **52 s** (1920 × 1080, 30 fps, H.264 BT.709, AAC estéreo), rehecho desde cero con **metraje real en movimiento**: la app en el simulador de iOS (SOS → «Esperando señal» → «Enviado a un nodo» → «2–5 personas») y el tablero **navegado** (lista → clic en el P1 → detalle → mapa → capa «Silencio»), capturado fotograma a fotograma con Playwright. **Montaje:** rejilla de 12 columnas con márgenes de 120 px, escenas que alternan héroe centrado y partido 50/50, cortes al compás (100 ppm), transiciones con deslizamiento, desenfoque y fundido, cámara que se asienta al entrar y se mueve dentro de los marcos, texto cinético y revelados con máscara, cabecera editorial, contador 239 B → 33 B, nodos que laten, cursor real con clic, zonas en silencio que laten, contadores en el cierre y llamada a la acción con el repositorio. **Sonido:** voz del sistema tratada (filtro de graves y compresión), pista con pulso (pad, bajo, bombo, caja, charles, arpegio) que crece por escena, se retira al caer el nodo y baja bajo la voz, risers y golpes en las transiciones; todo sintetizado, nada de terceros. **Verificación:** `build_video.py check` mide la composición de siete fotogramas (márgenes izquierdo/derecho iguales en las escenas centradas, columnas respetadas y medios centrados en las partidas, nada fuera del área segura) y `render` se niega a empezar si algo falla.

> **El video (`*.mp4`) no se versiona ni se sube a ningún servicio sin decidirlo.** Aquí sólo están el guion, el compositor y las capturas con las que se reconstruye.

## Guion (lo que se dice y lo que lo respalda)

| Escena | Tiempo | Imagen | Narración | Qué lo respalda |
|---|---|---|---|---|
| 1 · Gancho | 0:00–0:06 | Un sismógrafo que se agita, se queda plano con el apagón y deja pasar un pulso; «Sismo. Apagón.», la marca de SARD y anillos de SOS | «Un sismo. Un apagón. Y alguien que necesita que su pedido de ayuda llegue.» | El enunciado, §1 y §3 |
| 2 · La app | 0:06–0:19 | **Grabación real** del simulador: se marcan «Atrapado» y «Herido», se toca SOS → «Esperando señal» → «Enviado a un nodo» → «2–5 personas» como revisión del mismo reporte | «SARD convierte un toque en un reporte que sobrevive. Se guarda sin red, pesa apenas treinta y tres bytes, y sale solo cuando vuelve la señal.» | Trama de SOS de 33 B ([`b2.md`](../../resultados/b2.md), T02); bandeja SQLite durable y reintentos (T01, T03) |
| 3 · La red | 0:18–0:28 | Un reporte pasa por los nodos, un nodo cae (`kill -9`) y otro sigue; al volver, los tres muestran la misma huella | «Cada reporte llega a una red de nodos sin jefe. Si uno cae, otro sigue; y al reunirse, vuelven a coincidir.» | Sin nodo principal; T09, T10, T15, T18, T19 ([`demo-en-vivo.md`](../demo-en-vivo.md)); la huella `fa1404d6…` es la de `PART=4 bash tool/demo.sh 42` |
| 4 · El tablero | 0:27–0:37 | **Metraje real** del tablero navegado: la lista, el cursor hace clic en el P1 y se abre el detalle, en una ventana de navegador con rótulos | «El tablero ordena lo urgente, explica por qué, y propone la acción. Nada se ejecuta sin la aprobación de una persona.» | T13, T14; el detalle muestra «Por qué esta prioridad» y la recomendación como propuesta |
| 5 · El silencio | 0:37–0:45 | **Metraje real**: el mapa y la capa «Silencio» encendiéndose, con las cuatro zonas latiendo | «Y cuando una zona deja de reportar, el mapa lo marca. Porque el silencio no es seguridad.» | [`cobertura.md`](../../resultados/cobertura.md) |
| 6 · Cierre | 0:44–0:52 | Marca, «SARD», lema y tres cifras: **33 B** por SOS, **0** nodos principales, **2 069** pruebas | «SARD. Reportes que sobreviven. Decisiones que se pueden explicar.» | `bash tool/test_all.sh` (2 069 pruebas) |

Los datos de las pantallas son **sintéticos** y los canales, simulados (lo que permite el §4.7 del enunciado). La toma de la app corre en el simulador de iOS; la «caída de la señal» la hace un canal con compuerta dentro del propio recorrido (`marketing_flow.dart`), no un corte de red del sistema.

## Cómo se reconstruye

```bash
# 1. Un nodo con datos (otra terminal):            bash tool/expo.sh
# 2. La toma de la app: arrancar la grabación y correr el recorrido pausado (≈ 25 s)
xcrun simctl io <ID_SIMULADOR> recordVideo --codec h264 --force "$SARD_VIDEO_WORK/phone.mov" &
(cd apps/mobile && flutter test integration_test/marketing_flow.dart -d <ID_SIMULADOR> --dart-define=NODES=http://localhost:8081)
kill -INT %1                                      # termina la grabación
# 3. La toma del tablero: con Playwright, en http://localhost:8081 a 1440 × 900, capturar page.screenshot() en bucle (≈ 15 fps) durante 16 s
#    en $SARD_VIDEO_WORK/board_frames/00000.png… mientras se hace clic en el P1 (2,5 s), «Ver el mapa» (7 s) y el interruptor «Silencio» (10 s);
#    escribir board_frames/meta.json = {"fps": 15.31, "frames": N}. (Si cambian los tiempos, ajustar BOARD_DETAIL/BOARD_MAP/BOARD_SILENCE.)
# 4. Compositor (sin ffmpeg: AVFoundation, `say` y Pillow):
export SARD_VIDEO_WORK=/tmp/sard-video            # carpeta con phone.mov y board_frames/
python3 -I docs/pitch/video/build_video.py prepare
python3 -I docs/pitch/video/build_video.py check  # composición: debe terminar en «TODO CUADRA»
python3 -I docs/pitch/video/build_video.py render # → $SARD_VIDEO_WORK/salida/SARD-video.mp4 (+ póster) y guion.srt
```

`build_video.py still 12.5` renderiza un solo fotograma (en el segundo 12,5) para revisar el diseño. **Voz propia:** si graba la narración (una frase por archivo, `l1`…`l6`, `.wav`, `.aiff` o `.m4a`; el guion está en la tabla de arriba), apunte `SARD_VOICE_DIR` a esa carpeta antes de `prepare` y el video usa su voz; los tiempos, la música y los subtítulos se ajustan solos. Es la mejora que más sube la calidad: la voz del sistema es sintética. El permiso de ubicación del simulador es un diálogo del sistema que ningún script puede pulsar: conceda `xcrun simctl privacy <ID> grant location com.example.sardMobile` y reinicie el simulador antes de grabar.

## Archivos

| Archivo | Qué es |
|---|---|
| `build_video.py` | Guion, escenas (Pillow), voz, música y orden de reconstrucción |
| `encode.swift` | Codificador H.264 y unión de audio con AVFoundation (se compila con `swiftc`) |
| `assets/` | La marca (PNG con transparencia); las capturas fijas del tablero ya no se usan (el metraje se captura al reconstruir) |
| `../../../apps/mobile/integration_test/marketing_flow.dart` | El recorrido pausado de la app que se graba |
