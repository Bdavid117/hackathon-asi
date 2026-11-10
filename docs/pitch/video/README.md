# Video de presentación de SARD (≤ 1 minuto)

Un video de marketing de **52 s** (1920 × 1080, 30 fps) que presenta la aplicación y el sistema con **tomas reales**: la app corriendo en el simulador de iOS y el tablero con dos nodos y datos sintéticos. La voz es la del sistema (`say`, voz *Paulina*, español de México) y la música es un fondo sintetizado de bajo volumen; no se usó ningún recurso de terceros.

> **El video (`*.mp4`) no se versiona ni se sube a ningún servicio sin decidirlo.** Aquí sólo están el guion, el compositor y las capturas con las que se reconstruye.

## Guion (lo que se dice y lo que lo respalda)

| Escena | Tiempo | Imagen | Narración | Qué lo respalda |
|---|---|---|---|---|
| 1 · Gancho | 0:00–0:06 | «Sismo. Apagón.», la marca de SARD y anillos de SOS | «Un sismo. Un apagón. Y alguien que necesita que su pedido de ayuda llegue.» | El enunciado, §1 y §3 |
| 2 · La app | 0:06–0:17 | **Grabación real** del simulador: se marcan «Atrapado» y «Herido», se toca SOS → «Esperando señal» → «Enviado a un nodo» | «SARD convierte un toque en un reporte que sobrevive. Se guarda sin red, pesa apenas treinta y tres bytes, y sale solo cuando vuelve la señal.» | Trama de SOS de 33 B ([`b2.md`](../../resultados/b2.md), T02); bandeja SQLite durable y reintentos (T01, T03) |
| 3 · La red | 0:17–0:26 | Un reporte pasa por los nodos, un nodo cae (`kill -9`) y otro sigue; al volver, los tres muestran la misma huella | «Cada reporte llega a una red de nodos sin jefe. Si uno cae, otro sigue; y al reunirse, vuelven a coincidir.» | Sin nodo principal; T09, T10, T15, T18, T19 ([`demo-en-vivo.md`](../demo-en-vivo.md)); la huella `fa1404d6…` es la de `PART=4 bash tool/demo.sh 42` |
| 4 · El tablero | 0:26–0:37 | Capturas reales del tablero (lista y detalle de un P1) con rótulos | «El tablero ordena lo urgente, explica por qué, y propone la acción. Nada se ejecuta sin la aprobación de una persona.» | T13, T14; el detalle muestra «Por qué esta prioridad» y la recomendación como propuesta |
| 5 · El silencio | 0:37–0:45 | El mapa con la capa «Silencio»: cuatro zonas rayadas | «Y cuando una zona deja de reportar, el mapa lo marca. Porque el silencio no es seguridad.» | [`cobertura.md`](../../resultados/cobertura.md) |
| 6 · Cierre | 0:45–0:52 | Marca, «SARD», lema y tres cifras: **33 B** por SOS, **0** nodos principales, **2 069** pruebas | «SARD. Reportes que sobreviven. Decisiones que se pueden explicar.» | `bash tool/test_all.sh` (2 069 pruebas) |

Los datos de las pantallas son **sintéticos** y los canales, simulados (lo que permite el §4.7 del enunciado). La toma de la app corre en el simulador de iOS; la «caída de la señal» la hace un canal con compuerta dentro del propio recorrido (`marketing_flow.dart`), no un corte de red del sistema.

## Cómo se reconstruye

```bash
# 1. Un nodo con datos (otra terminal):            bash tool/expo.sh
# 2. La toma de la app: arrancar la grabación y correr el recorrido pausado (≈ 20 s)
xcrun simctl io <ID_SIMULADOR> recordVideo --codec h264 --force "$SARD_VIDEO_WORK/phone.mov" &
(cd apps/mobile && flutter test integration_test/marketing_flow.dart -d <ID_SIMULADOR> --dart-define=NODES=http://localhost:8081)
kill -INT %1                                      # termina la grabación
# 3. Compositor (sin ffmpeg: AVFoundation, `say` y Pillow):
export SARD_VIDEO_WORK=/tmp/sard-video            # carpeta con phone.mov
python3 -I docs/pitch/video/build_video.py prepare
python3 -I docs/pitch/video/build_video.py render # → $SARD_VIDEO_WORK/sard-video.mp4
```

`build_video.py still 12.5` renderiza un solo fotograma (en el segundo 12,5) para revisar el diseño. El permiso de ubicación del simulador es un diálogo del sistema que ningún script puede pulsar: conceda `xcrun simctl privacy <ID> grant location com.example.sardMobile` y reinicie el simulador antes de grabar.

## Archivos

| Archivo | Qué es |
|---|---|
| `build_video.py` | Guion, escenas (Pillow), voz, música y orden de reconstrucción |
| `encode.swift` | Codificador H.264 y unión de audio con AVFoundation (se compila con `swiftc`) |
| `assets/` | La marca (PNG con transparencia) y las capturas reales del tablero usadas en las escenas |
| `../../../apps/mobile/integration_test/marketing_flow.dart` | El recorrido pausado de la app que se graba |
