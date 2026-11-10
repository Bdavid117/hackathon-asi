# Guion de la demostración y del pitch

Pensado para **8–10 minutos** (con 5 minutos se omiten los pasos 5 y 7). Cada paso dice qué se ve, qué decir, qué comando lo produce y **qué cifra respalda lo que se dice**. Todo está en el repositorio; nada depende de la red.

> **Las láminas** de este guion están en [`SARD-pitch.pdf`](SARD-pitch.pdf) (18 láminas; las notas del orador de cada una repiten lo que sigue). Las capturas son reales (tablero con el escenario de ejemplo y app en el emulador de Android), no maquetas.

> **Regla del guion:** se dice lo que está medido y se dice dónde termina. Cada «sí» lleva su «pero» (hay una lista al final). Un jurado que encuentra solo un límite que usted no mencionó deja de creer el resto.

> **Alcance, con las palabras del enunciado.** El §4.7 dice: «El recorrido puede ejecutarse con datos sintéticos y canales simulados. No se exige desplegar una red de radio real ni contar con acceso a infraestructura gubernamental.» Eso se dice **al principio, como alcance**, no al final como disculpa. Y cuidado con el vocabulario: el enunciado **no fija** metas numéricas ni rúbrica; el 95 %, el 1 % y los 10 minutos son metas **del propio diseño**. Se dice «nuestra meta», nunca «lo que pide el enunciado». (Atribuir al enunciado algo que no dice es justo el tipo de error que hace dudar de lo demás.)

## Antes de empezar (10 min antes)

> **Para una demostración con dos nodos, historia sembrada y zonas en silencio, siga [`demo-en-vivo.md`](demo-en-vivo.md)** (`bash tool/expo.sh`; incluye tiempos medidos y plan B por escena). Lo de abajo es la versión de un solo nodo.

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

Abra `http://localhost:8081/` en Chrome (1360 × 860). Tenga a mano una terminal con `bash tool/demo.sh 42` **ya ensayada** (con `PART=4` dura ≈ 45 s en total, porque la ejecuta dos veces para comprobar la huella). **Plan B** si falla la máquina: las capturas y las tablas están en `docs/resultados/b5.md` y en el PDF (§6.7 y §9), y el **video de respaldo** (se graba cuando los retos estén cumplidos; todavía no existe) enseñará la misma ejecución. El video respalda a `tool/demo.sh`, no lo sustituye.

## Cuánto dura la presentación: elija una ruta

Las **notas del orador de las 18 láminas suman más de 17 minutos** si se dicen todas (no se midió con reloj); los pasos de la demostración de abajo suman 8–10 minutos y se pueden alternar con las láminas. Rutas propuestas (los tiempos salen de las notas de cada lámina; ensáyelas con reloj, no son una medición):

| Duración | Láminas, en este orden | Se omite |
|---|---|---|
| **5 min** | portada (0:20) · recorrido (0:40) · arquitectura (1:00) · tablero (1:00) · caída de un nodo (1:30) · reproducir (0:30) | todo lo demás |
| **10 min** | portada (0:20) · problema (0:30) · recorrido (0:40) · arquitectura (1:00) · app (1:00) · protocolo (1:30) · tablero (1:30) · silencio (1:30) · caída (1:30) · reproducir (0:20) | agentes, trazas, modelo, verdad, despachador, réplica, ráfaga, fallos |
| **15 min** | las 18 láminas, sin demostración en vivo (o con 2 min de la app) | — |

Si hay demostración en vivo, sustituye a la lámina correspondiente (app, tablero, silencio o caída), no se suma.

## Los pasos

| # | Minutos | Qué se ve | Qué decir | Qué lo respalda |
|---|---|---|---|---|
| 1 | 0:00–1:30 | **La app, sin red.** Modo avión, un toque en SOS: «Guardado en tu teléfono». Se mata la app y se reabre: sigue ahí. Se devuelve la red: «Enviado a un nodo». | «Una persona asustada hace UNA cosa. Se guarda al instante y sale sola.» | T01: 6 golpes de `kill -9` sin perder nada de lo dado por guardado (`packages/client_core/test/t01_kill_test.dart`). En el emulador sale ≈ 1 s después de volver la señal. |
| 2 | 1:30–2:30 | **Después del SOS**, sin prisa: tocar «2–5» personas y escribir «mi mamá no puede salir del segundo piso». Los botones **no se mueven** al escribir. | «Lo urgente va primero; los detalles enriquecen el *mismo* reporte, no lo duplican.» | El SOS nunca lleva texto; 140 bytes cortados por bytes (una «ñ» pesa 2). `apps/mobile/test/details_test.dart`. |
| 3 | 2:30–4:30 | **El tablero.** La barra de triaje (1 P1 · 1 P2 · 6 P3), los contadores, la fila «3 SOS sin detalle». Abrir el P1: *por qué* (indicadores y citas), observaciones originales, recomendación «Enviar rescate + atención médica» con «antes de aprobar: confirmar con una segunda fuente». **Aprobar** con un nombre. | «La unidad es el incidente, no el mensaje. Nada se ejecuta solo: quien aprueba queda registrado con la versión que vio.» | T13: 0 acciones o recursos inventados, 0 aprobaciones automáticas. T14: 0 P1 fuera de la vista. Si el incidente cambia mientras se decide, **no se registra** (`detail_panel_test.dart`). |
| 4 | 4:30–6:30 | **Condición adversa** (terminal): `PART=4 bash tool/demo.sh 42`. Se ve la partición, el `kill -9` con la ráfaga a medias («A acusó 8 de 26; los otros 18 conmutaron a B»), el reinicio con su RTO, la reconexión y «huellas idénticas». | «Mato un nodo en pleno trabajo. Lo que acusó sigue ahí al volver; el otro nodo siguió sirviendo.» | T09: RTO 2,3–3,7 s (JIT). T10: convergencia 3,1–3,6 s. |
| 5 | 6:30–7:30 | En esa misma salida: **«dos coordinadores deciden a la vez, uno en cada nodo, y se contradicen»** → ambos nodos muestran el incidente «rechazada» con la discrepancia marcada. Y al final: «misma semilla ⇒ misma huella». | «Aislados, dos personas se contradijeron. No se pierde ninguna decisión; manda la más conservadora hasta que alguien la resuelva a propósito.» | T10 y T15. |
| 6 | 7:30–8:30 | **El modelo falla.** Mostrar la tabla de `docs/resultados/t12.md` (o `dart run packages/sim/bin/t12.dart --reports 100`, ≈ 1 min): con el modelo colgado, el ACK p95 pasa de 9 a 17 ms; todas acusadas. Y la ráfaga de 5 000 con el modelo colgado y el límite de 1 024 descriptores: **antes el nodo moría**, ahora 0 fallidas (con un tope de consultas simultáneas; a cambio, la mayoría de los reportes con texto se quedan sólo con reglas). Y el reparto/relevo entre dos nodos. | «Si el modelo se cuelga, el sistema sigue con reglas. Y el trabajo caro se reparte entre nodos; si el dueño cae, otro lo toma.» | T12. **El modelo es falso: dígalo.** |
| 7 | 8:30–9:30 | **Cómo se reproduce.** `bash tool/test_all.sh` (2 069 pruebas, ≈ 6 min; se muestra su última salida: `TODO EN VERDE`) y `bash tool/expo.sh` (la demostración con dos nodos y seis horas de historia). | «Cada cifra tiene su informe y el comando que la produce.» | `README.md`, `docs/resultados/`, [`demo-en-vivo.md`](demo-en-vivo.md). |

## Material de apoyo para preguntas: el juez de modelo en el Reto 4 (ya no tiene lámina)

**Hay dos rondas.** La segunda (semillas 706–713, umbral 0,85, criterio reescrito tras ver la primera: evidencia más débil) subió el recall de pares de 0,48 a 1,99 % con 175 de 178 uniones acertadas, pero la falsa fusión pasó de 0,00 a 0,92 %: bajo el 1 % absoluto y fuera de «reglas + 0,5 puntos»; no se adopta y la pregunta se cierra. Los 3 errores tienen justo 0,85.

No hay demostración en vivo (la API real cuesta y tarda ≈ 12 min): se enseña la lámina y, si preguntan, `docs/resultados/reto4-juez.md` y `t07-modelo.md`. Lo que se dice: el juez une más (recall de pares 0,8 % → 4,4 %; 97,7 % de sus uniones acertadas; en la corroboración de 5 fuentes reúne 4 y la confianza pasa de 0,60 a 0,97) **pero la falsa fusión sube de 1,2 % a 2,2 %** frente al límite de 1 %, y por eso **no está en el nodo**. Lo que respalda que no se midió a posteriori: el criterio de adopción está commiteado (`6ed2fe5`) antes de gastar y el código medido es `8e10d47`.

## Un paso más, si hay un minuto: el despachador (Escenario 2)

En el tablero, **«Registrar informe»** (arriba a la derecha): escribir lo que se «oyó por radio», de quién viene, marcar «Atrapado» y «Herido» y enviar. Aparece un incidente **P1**, marcado **«De segunda mano»** en la lista, con **una sola fuente y confianza 0,2**, «Sin ubicación» y «Todavía no se puede recomendar: falta saber la ubicación» (si quien registra escribe latitud y longitud, entra con calidad «manual», se le supone unos 3 km de imprecisión y la recomendación aparece pidiendo «confirmar la ubicación»; un texto que acaba cortado se marca «posible mensaje cortado»); la observación dice «Informe por teléfono · registrado 15:35 por Ana Gómez · origen: …». Qué decir: «Es información de segunda mano: se conserva, se prioriza por lo que indica, pero no se amplifica (el mismo texto de tres orígenes es **una** fuente) y no inventa el dónde.» Respaldo: T16, `bash tool/dispatch_check.sh` (tres nodos reales, ≈ 1 min), `docs/resultados/despachador.md`.

## Un paso más, si hay un minuto: lo último del tablero (contradicciones, recursos, ruta)

`dart run packages/sim/bin/seed_scenario.dart --now --extended` añade al escenario fijo tres casos: **una contradicción** (dos reportes del mismo sitio, uno dice «hay heridos» y el otro «sin heridos»: el tablero los muestra los dos, los cuenta en «Con contradicciones» y no los resuelve), **una vía bloqueada** en la ruta de la ambulancia (la propuesta del P1 pide «confirmar que la ruta esté libre») y **la ambulancia 2 no disponible** (icono «Recursos» de la barra: el panel lista las unidades, permite cambiarlas y resolver un conflicto; en el mapa son cuadrados bajo los incidentes). Qué decir: «Cambiar una unidad no despacha nada: sólo cambia lo que el agente 6 puede nombrar. Si la unidad propuesta deja de estar disponible, la aprobación vigente caduca.» Respaldo: `bash tool/resources_check.sh` (dos nodos reales: partición, `kill -9`, conflicto y resolución), `docs/resultados/t17-contradicciones.md`. Lo que NO hay que decir: que detecta contradicciones «de sentido» (sólo negación explícita y cantidad de personas; T17 es una medición modesta con datos del mismo autor).

## Frases que NO se deben decir (y por qué)

- «Funciona con el modelo de lenguaje.» → Sólo con cifras y límites: se midió contra la API real en **una** corrida con datos **sintéticos** (recall de P1 85,4 % → 96,0 % en reportes con texto, 10 falsos P1 en 750); T12 sigue con un servidor falso y no se probó con datos reales. «Resuelve el criterio de T06» es falso: el global sigue en ≈ 85 % (estimado) porque ≈ 38 % de los P1 no traen texto.
- «Agrupa los reportes duplicados.» → Casi no agrupa (0,43 % de los pares verdaderos con reglas). Se *sugieren* posibles duplicados. Un juez de modelo de lenguaje subió el recall de pares de 0,8 % a 4,4 % pero con más falsas fusiones (2,2 % frente a 1,2 %), y por eso **no está en el nodo** (`docs/resultados/reto4-juez.md`).
- «Resiste una partición de 10 minutos.» → La demostración (`demo.sh`) usa 5–20 s, por configuración. T18 sí midió 10 minutos con dos nodos y el enlace cortado por un proxy (converge en 2,5 s), y T19 un aislamiento de 30 s con tres nodos; **en una sola máquina, con modelos falsos y un corte total y simétrico**, así que no se dice «resiste una caída de red real». Los 10 minutos eran lo que **proponía nuestro diseño** para T10; el enunciado no fija ninguna duración.
- «Es seguro.» → Con los códigos de acceso activos, el tablero y la réplica exigen un código compartido (sin ellos, el nodo está abierto). Con un código compartido no se sabe quién aprobó; con `--coordinator-codes` cada código tiene dueño y el de otro no puede firmar a su nombre, pero sigue siendo «identificado por código», no autenticado: viaja sin cifrar (sin TLS), no tiene límite de intentos y los nodos pares replican el evento sin volver a comprobar el nombre; la clave de integridad de las tramas es compartida y pública en el repositorio, así que quien llegue por red puede falsificar tramas (`/frame` está abierto a propósito).
- «Mejora el tiempo del coordinador.» → No hubo prueba con coordinadores. Lo medido es *elementos a revisar* con datos sintéticos.
- «El despachador resuelve el Reto 4.» → No: otros orígenes con otras palabras siguen sin agruparse; sólo el mismo texto se funde (y cuenta como una fuente).
- «El modelo resuelve el Reto 4 / agrupa las 5 fuentes independientes.» → Se probó, una vez y con datos sintéticos: reúne 4 de las 5 fuentes (confianza 0,60 → 0,97), pero la falsa fusión sube y el criterio fijado antes de medir no se cumple; el nodo no lo usa.
- «El tablero avisa dónde hay problemas / dónde no hay.» → No: el interruptor «Silencio» marca sólo las zonas que **reportaron y callaron** (6 h de actividad, 30 min de silencio, celdas de ≈ 550 m: elecciones propias, no del enunciado). Una zona sin marca puede no tener teléfonos con batería y una marcada puede estar bien: **el silencio no es seguridad**, y no se probó con coordinadores (`docs/resultados/cobertura.md`).
- «Probado con despachadores / con radio real.» → Lo teclea una persona; no se probó con despachadores ni con radio.
- «Probado en teléfonos.» → Falso: es emulador de Android y simulador de iOS. **Qué decir en su lugar:** «Datos sintéticos y canales simulados, como permite el §4.7; la app corre en un emulador de Android y un simulador de iOS.» Eso no es una confesión: es el alcance. No se afirma nada de consumo real de energía ni de radio real, porque no se midió.
- «El enunciado pide 95 % de recall / 1 % de falsa fusión / particiones de 10 minutos.» → No: son metas propias (cap. 9 del PDF de arquitectura). El enunciado no fija umbrales.

## Preguntas probables

- **¿Por qué los SOS sin detalle se agregan en una fila?** Porque son lo que más emitirá la app real (un toque y nada más) y se comerían la lista. Siguen contados y a un clic.
- **¿Qué pasa si dos personas aprueban cosas distintas?** Se conservan ambas; manda el rechazo y la discrepancia se ve hasta que una persona sustituya explícitamente una (`docs/resultados/b5.md` §2).
- **¿Y si cae el nodo dueño del trabajo del modelo?** El siguiente en el orden de *rendezvous* lo toma pasado un plazo (10 s por omisión); el ACK y las reglas nunca dependieron de él. Medido con dos nodos.
- **¿Por qué no usar un `429` para limitar a un dispositivo abusivo?** Porque la clave es compartida: alguien podría falsificar el identificador de una víctima y bloquear su SOS. Se *degrada* (se omite sólo el modelo) y nunca se rechaza un primer reporte.
- **¿Qué es la «huella»?** Un SHA-256 de lo que ve el coordinador (quién está con quién, urgencias, recomendaciones y estado de las aprobaciones) sin relojes ni identificadores internos. Si dos nodos tienen la misma, muestran lo mismo.
- **¿Por qué no subieron el umbral del juez a 0,85 y lo volvieron a medir?** Porque los cinco errores están todos en 0,80 y esa idea sale de los mismos datos que se midieron: probarla exige semillas nuevas y un criterio nuevo escrito antes (≈ 6 USD, 12 min). Se dejó como hipótesis, no como resultado (`docs/resultados/reto4-juez.md`).
- **¿Se pueden reproducir las cifras?** Sí: `docs/resultados/b5.md` §8 lista cada comando.
- **¿Lo probaron en un teléfono real?** No, y el enunciado no lo exige: el §4.7 permite «datos sintéticos y canales simulados» y el objetivo 10 pide pruebas *reproducibles*, que es justo lo que da un canal simulado con semilla. La app se verificó en un emulador de Android y un simulador de iOS (ubicación y batería simuladas desde su consola). Lo que **no** se afirma es consumo real de energía ni comportamiento de una radio real.
- **¿De dónde sale el 95 %?** De nuestro propio diseño (cap. 9 del PDF de arquitectura), no del enunciado, que no trae umbrales. Lo medimos contra esa vara y dijimos que no la cumplimos.
- **¿Qué pasa si el sistema operativo mata la app?** La cola está en SQLite y no se pierde, pero no sale hasta reabrir la app: no hay servicio en primer plano de Android. Es un límite de despliegue declarado, fuera del alcance del §4.7.
