# Guion de la demostración y del pitch

Pensado para **8–10 minutos** (con 5 minutos se omiten los pasos 5 y 7). Cada paso dice qué se ve, qué decir, qué comando lo produce y **qué cifra respalda lo que se dice**. Todo está en el repositorio; nada depende de la red.

> **Las láminas** de este guion están en [`SARD-pitch.pdf`](SARD-pitch.pdf) (13 láminas; las notas del orador de cada una repiten lo que sigue). Las capturas son reales (tablero con el escenario de ejemplo y app en el emulador de Android), no maquetas.

> **Regla del guion:** se dice lo que está medido y se dice dónde termina. Cada «sí» lleva su «pero» (hay una lista al final). Un jurado que encuentra solo un límite que usted no mencionó deja de creer el resto.

## Antes de empezar (10 min antes)

```bash
dart pub get
(cd apps/dashboard && flutter build web --no-web-resources-cdn)       # el tablero compilado
bash tool/web_smoke.sh --no-build                                     # debe decir OK (Chrome sin cabeza)
# Un nodo con el tablero y el escenario fijo (8 incidentes):
D=$(mktemp -d); (cd apps/node && dart run bin/sard_node.dart --id A --port 8081 --data $D \
   --web-root ../dashboard/build/web --resources ../../config/recursos.json) &
dart run packages/sim/bin/seed_scenario.dart --node http://localhost:8081 --now   # horas de ahora: el tablero dice «hace 7 min», no «hace 90 d»
# La app en el emulador (Android: 10.0.2.2):
(cd apps/mobile && flutter run -d emulator-5554 --dart-define=NODES=http://10.0.2.2:8081)
```

Abra `http://localhost:8081/` en Chrome (1360 × 860). Tenga a mano una terminal con `bash tool/demo.sh 42` **ya ensayada** (con `PART=4` dura ≈ 45 s en total, porque la ejecuta dos veces para comprobar la huella). **Plan B** si falla la máquina: las capturas y las tablas están en `docs/resultados/b5.md` y en el PDF (§6.7 y §9).

## Los pasos

| # | Minutos | Qué se ve | Qué decir | Qué lo respalda |
|---|---|---|---|---|
| 1 | 0:00–1:30 | **La app, sin red.** Modo avión, un toque en SOS: «Guardado en tu teléfono». Se mata la app y se reabre: sigue ahí. Se devuelve la red: «Enviado a un nodo». | «Una persona asustada hace UNA cosa. Se guarda al instante y sale sola.» | T01: 6 golpes de `kill -9` sin perder nada de lo dado por guardado (`packages/client_core/test/t01_kill_test.dart`). En el emulador sale ≈ 1 s después de volver la señal. |
| 2 | 1:30–2:30 | **Después del SOS**, sin prisa: tocar «2–5» personas y escribir «mi mamá no puede salir del segundo piso». Los botones **no se mueven** al escribir. | «Lo urgente va primero; los detalles enriquecen el *mismo* reporte, no lo duplican.» | El SOS nunca lleva texto; 140 bytes cortados por bytes (una «ñ» pesa 2). `apps/mobile/test/details_test.dart`. |
| 3 | 2:30–4:30 | **El tablero.** La barra de triaje (1 P1 · 1 P2 · 6 P3), los contadores, la fila «3 SOS sin detalle». Abrir el P1: *por qué* (indicadores y citas), observaciones originales, recomendación «Enviar rescate + atención médica» con «antes de aprobar: confirmar con una segunda fuente». **Aprobar** con un nombre. | «La unidad es el incidente, no el mensaje. Nada se ejecuta solo: quien aprueba queda registrado con la versión que vio.» | T13: 0 acciones o recursos inventados, 0 aprobaciones automáticas. T14: 0 P1 fuera de la vista. Si el incidente cambia mientras se decide, **no se registra** (`detail_panel_test.dart`). |
| 4 | 4:30–6:30 | **Condición adversa** (terminal): `PART=4 bash tool/demo.sh 42`. Se ve la partición, el `kill -9` con la ráfaga a medias («A acusó 8 de 26; los otros 18 conmutaron a B»), el reinicio con su RTO, la reconexión y «huellas idénticas». | «Mato un nodo en pleno trabajo. Lo que acusó sigue ahí al volver; el otro nodo siguió sirviendo.» | T09: RTO 2,3–3,7 s (JIT). T10: convergencia 3,1–3,6 s. |
| 5 | 6:30–7:30 | En esa misma salida: **«dos coordinadores deciden a la vez, uno en cada nodo, y se contradicen»** → ambos nodos muestran el incidente «rechazada» con la discrepancia marcada. Y al final: «misma semilla ⇒ misma huella». | «Aislados, dos personas se contradijeron. No se pierde ninguna decisión; manda la más conservadora hasta que alguien la resuelva a propósito.» | T10 y T15. |
| 6 | 7:30–8:30 | **El modelo falla.** Mostrar la tabla de `docs/resultados/t12.md` (o `dart run packages/sim/bin/t12.dart --reports 100`, ≈ 1 min): con el modelo colgado, el ACK p95 pasa de 9 a 17 ms; todas acusadas. Y la ráfaga de 5 000 con el modelo colgado y el límite de 1 024 descriptores: **antes el nodo moría**, ahora 0 fallidas (con un tope de consultas simultáneas; a cambio, la mayoría de los reportes con texto se quedan sólo con reglas). Y el reparto/relevo entre dos nodos. | «Si el modelo se cuelga, el sistema sigue con reglas. Y el trabajo caro se reparte entre nodos; si el dueño cae, otro lo toma.» | T12. **El modelo es falso: dígalo.** |
| 7 | 8:30–9:30 | **Lo que no funciona.** La cifra de T06 (recall de P1 78,5 % frente a 95 %), el agrupamiento que casi no fusiona, T14 (la mejora es de ordenar, no de agrupar). | «Lo que no cumplimos, lo medimos y lo decimos. Esto es lo que el modelo y las personas tienen que resolver.» | `docs/resultados/b3.md`, `b5.md` §5 y §7. |

## Un paso más, si hay un minuto: el despachador (Escenario 2)

En el tablero, **«Registrar informe»** (arriba a la derecha): escribir lo que se «oyó por radio», de quién viene, marcar «Atrapado» y «Herido» y enviar. Aparece un incidente **P1**, marcado **«De segunda mano»** en la lista, con **una sola fuente y confianza 0,2**, «Sin ubicación» y «Todavía no se puede recomendar: falta saber la ubicación»; la observación dice «Informe por teléfono · registrado 15:35 por Ana Gómez · origen: …». Qué decir: «Es información de segunda mano: se conserva, se prioriza por lo que indica, pero no se amplifica (el mismo texto de tres orígenes es **una** fuente) y no inventa el dónde.» Respaldo: T16, `bash tool/dispatch_check.sh` (tres nodos reales, ≈ 1 min), `docs/resultados/despachador.md`.

## Frases que NO se deben decir (y por qué)

- «Funciona con el modelo de lenguaje.» → Sólo con cifras y límites: se midió contra la API real en **una** corrida con datos **sintéticos** (recall de P1 85,4 % → 96,0 % en reportes con texto, 10 falsos P1 en 750); T12 sigue con un servidor falso y no se probó con datos reales. «Resuelve el criterio de T06» es falso: el global sigue en ≈ 85 % (estimado) porque ≈ 38 % de los P1 no traen texto.
- «Agrupa los reportes duplicados.» → Casi no agrupa (0,43 % de los pares verdaderos). Se *sugieren* posibles duplicados.
- «Resiste una partición de 10 minutos.» → Se probó 5–20 s, por configuración, no por red.
- «Es seguro.» → Con los códigos de acceso activos, el tablero y la réplica exigen un código compartido (sin ellos, el nodo está abierto). Ese código no dice quién aprobó, viaja sin cifrar (sin TLS) y no tiene límite de intentos; la clave de integridad de las tramas es compartida y pública en el repositorio, así que quien llegue por red puede falsificar tramas (`/frame` está abierto a propósito).
- «Mejora el tiempo del coordinador.» → No hubo prueba con coordinadores. Lo medido es *elementos a revisar* con datos sintéticos.
- «El despachador resuelve el Reto 4.» → No: otros orígenes con otras palabras siguen sin agruparse; sólo el mismo texto se funde (y cuenta como una fuente).
- «Probado con despachadores / con radio real.» → Lo teclea una persona; no se probó con despachadores ni con radio.
- «Probado en teléfonos.» → Emulador de Android y simulador de iOS; ningún teléfono real ni radio real.

## Preguntas probables

- **¿Por qué los SOS sin detalle se agregan en una fila?** Porque son lo que más emitirá la app real (un toque y nada más) y se comerían la lista. Siguen contados y a un clic.
- **¿Qué pasa si dos personas aprueban cosas distintas?** Se conservan ambas; manda el rechazo y la discrepancia se ve hasta que una persona sustituya explícitamente una (`docs/resultados/b5.md` §2).
- **¿Y si cae el nodo dueño del trabajo del modelo?** El siguiente en el orden de *rendezvous* lo toma pasado un plazo (10 s por omisión); el ACK y las reglas nunca dependieron de él. Medido con dos nodos.
- **¿Por qué no usar un `429` para limitar a un dispositivo abusivo?** Porque la clave es compartida: alguien podría falsificar el identificador de una víctima y bloquear su SOS. Se *degrada* (se omite sólo el modelo) y nunca se rechaza un primer reporte.
- **¿Qué es la «huella»?** Un SHA-256 de lo que ve el coordinador (quién está con quién, urgencias, recomendaciones y estado de las aprobaciones) sin relojes ni identificadores internos. Si dos nodos tienen la misma, muestran lo mismo.
- **¿Se pueden reproducir las cifras?** Sí: `docs/resultados/b5.md` §8 lista cada comando.
