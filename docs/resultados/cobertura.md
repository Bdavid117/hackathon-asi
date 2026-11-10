# Capa «Silencio»: las zonas que reportaron y callaron

**Qué es.** Un interruptor del mapa del tablero que marca, sobre el mapa, las zonas donde **sí** llegaron reportes con ubicación en las últimas 6 h y **ninguno** en los últimos 30 min. Responde a lo que el Escenario 2 del enunciado describe («despachadores […] en completa oscuridad informativa»): lo que no llega no dice nada de lo que pasa, y hasta ahora el tablero sólo dibujaba lo que sí llegó.

**Qué NO es.** No predice emergencias, no dice dónde «debería» haber reportes y **no dice que una zona sin marca esté a salvo**. Una zona marcada puede estar bien, sin teléfonos con batería o sin señal; una zona sin marca puede estar igual de callada si nunca reportó. Por eso el rótulo de la capa **empieza** por «El silencio no es seguridad.» (si el texto se recorta, se pierde un detalle y no la advertencia).

**Alcance.** Todo lo de este documento sale del propio diseño, no del enunciado: la rejilla, las dos ventanas y el tope no están en el enunciado ni se calibraron con casos reales. Los datos son sintéticos (lo que el §4.7 permite) y **no se midió si la capa ayuda a decidir mejor**: no hubo coordinadores que la usaran.

## Cómo funciona

| Pieza | Decisión (propia del diseño) |
|---|---|
| Rejilla | Celdas fijas de **0,005°** (≈ 550 m). El identificador sale de `floor((lat+90)/0,005)` y `floor((lon+180)/0,005)` (con una tolerancia de 1e-9 para que un límite exacto no caiga en la celda vecina por coma flotante); no depende del orden ni de los datos. |
| Ventana de actividad | **6 h**: sólo cuentan reportes recibidos en ese lapso. |
| Ventana de silencio | **30 min**: una celda con actividad y sin ningún reporte en este lapso está «en silencio». |
| Reloj | La hora de **recepción del nodo** (el primer acuse), no la del teléfono (puede estar mal). «Hace cuánto calló» se calcula con el reloj del **nodo**, no el de la pantalla. Una recepción en el futuro (reloj del nodo atrasado) cuenta como ahora. |
| Qué cuenta | Reportes con **coordenadas utilizables**. Los que no las tienen **se cuentan aparte y se dicen** («N reportes sin ubicación no entran»). Sólo el primer acuse de cada reporte cuenta como actividad: una revisión posterior no. |
| Orden y tope | Las celdas con reportes urgentes (P1/P2 por reglas) primero, luego las de más reportes; hasta **400**, con el total real (`silentTotal`) y cuántas se dibujan. |
| Dónde vive | `GET /api/coverage`, aparte de la cola, la lista y el resumen (tras el código de acceso como todo `/api/`): **no entra en la huella de proyección** (T15) ni cambia lo que un coordinador ya ve. Es una proyección pura de lo que el nodo tiene (`apps/node/lib/src/coverage.dart`). |

## Cómo se ve (tablero)

- Interruptor **«Silencio»** en una franja bajo el mapa, **apagado por omisión**. Apagado no se pide nada al nodo; encendido sólo se lee con el mapa a la vista (una lectura en vuelo a la vez) y al apagar se olvida lo leído, para no enseñar una lectura vieja al volver a encender.
- Las zonas se dibujan **debajo** de los incidentes, rayadas y de trazo discontinuo (la forma dice «sin información»; el color solo no), no reciben toques y cada una dice en voz alta cuántos reportes tuvo, cuántos urgentes y cuánto hace que calló.
- Un nodo anterior (404), un fallo de red o una respuesta mal formada **no rompen el tablero**: la franja lo dice («Este nodo no calcula las zonas en silencio», «No se pudo leer el silencio», «No se pudo actualizar; se muestra la última lectura») y **no afirma ningún recuento** que no tenga. Un 401 bloquea como cualquier otra lectura.

**Un defecto propio, visto en una captura y corregido antes de commitear.** La primera versión ponía el rótulo y el interruptor **encima** del lienzo; en una captura contra un nodo real, el rótulo de cuatro líneas tapaba un P3 del borde superior y la píldora rozaba otro marcador. Una capa de ayuda no puede esconder un incidente: pasaron a una franja **fuera del lienzo y de altura constante** (encender la capa no mueve ningún marcador; hay una prueba que lo fija, y otra que comprueba que ni rótulo ni interruptor solapan un marcador).

## Pruebas

- Nodo: 20 pruebas (`apps/node/test/coverage_test.dart`): ventanas y sus extremos exactos, celdas con coordenadas negativas, fronteras de la rejilla donde la coma flotante cae por debajo, independencia del orden, tope de 400 con el total real, recepción en el futuro, coordenadas no finitas, sin ubicación, la ruta con y sin código y que no aparezca en la cola ni en la lista.
- Tablero: 38 pruebas (modelo y cliente, mapa y pantalla) con respuestas retenidas para los casos de carrera: una sola lectura en vuelo, una lectura que llega **después** de apagar, y olvidar lo leído al perder el acceso.
- **Mutaciones** (cada una cambia una línea y se comprueba que alguna prueba falla): 19 en el nodo, 21 en el mapa (diseño final) y 14 en la pantalla; todas detectadas **tras cerrar los huecos** que mostraron las primeras pasadas (el borde de la rejilla, la recepción en el futuro, la zona demasiado pequeña, la lectura tardía, la guarda de petición en vuelo…). Una de las mutaciones —el peso de la letra del interruptor— no se puede detectar en las pruebas (la fuente de prueba mide igual todos los pesos) y se sustituyó por otra del grosor del borde, que sí. El mensaje del commit del tablero habla de «28 mutaciones»: era una cuenta aproximada; las cifras buenas son éstas.
- Comprobado además en Chrome contra un nodo real con ocho reportes sembrados (un nodo temporal con el reloj una hora adelantado, para que los reportes recién llegados parecieran viejos): siete zonas en silencio, 1 reporte sin ubicación fuera, y la misma disposición en 1280 y en 360 px de ancho.

## Límites (lo que esto no resuelve)

1. **Una celda con un solo reporte viejo** cuenta como «en silencio» aunque fuera un mensaje suelto; por eso cada zona dice cuántos reportes tuvo.
2. **El silencio depende del reloj del nodo.** Si está atrasado, todo parece reciente y la capa calla; si está adelantado, todo parece viejo. No se corrige ni se detecta.
3. **La rejilla es fija:** un foco de reportes a caballo de dos celdas se reparte entre ambas.
4. **No distingue por qué se calló** (sin batería, sin señal, sin nadie, o todo en orden). Esa lectura es de la persona.
5. **Cada nodo la calcula de su propio registro**: con dos nodos aislados cada uno ve su propio silencio, y vuelve a coincidir cuando se reúnen (los reportes son eventos replicados; la capa no se replica).
6. **No medida con personas:** no sabemos si ayuda a decidir ni si alguien la sobreinterpretaría como «zona segura».
7. Los umbrales (6 h, 30 min, 550 m, 400 celdas) son una elección, no un resultado.
