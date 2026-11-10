# Plan: capa de «silencio» en el mapa (la ausencia de reportes no es seguridad) y dos menores cerrados

> Ejecución nativa, sin subagentes (el usuario no los pidió). Pasos en orden rojo → verde, mutaciones y `bash tool/test_all.sh` verde antes de empujar.

**Por qué.** El Escenario 2 del enunciado («el silencio digital») habla de despachadores «en completa oscuridad informativa»: pasadas las 6 horas el 95 % de los teléfonos está apagado, y lo que no llega no dice nada de lo que pasa. Hoy el tablero sólo dibuja lo que SÍ llegó; nada avisa de las zonas que reportaron y callaron. Es el ítem «mapa de cobertura» que el README tenía como opcional y pospuesto.

**Qué NO es.** No predice emergencias ni dice dónde «debería» haber reportes. No dice que una zona sin marca esté a salvo. Sólo marca las celdas donde SÍ hubo reportes con ubicación en la ventana de actividad y NINGUNO en la ventana reciente, y repite en la propia interfaz que el silencio no es seguridad.

## Decisiones (propias del diseño, no del enunciado)

- Rejilla fija de **0,005°** (≈ 550 m): el identificador de celda sale de `floor((lat+90)/0,005)` y `floor((lon+180)/0,005)`; no depende del orden ni de los datos.
- **Ventana de actividad 6 h** y **ventana de silencio 30 min**, contadas desde la hora de recepción del propio nodo (`receivedAtMs`, el primer acuse), no la del teléfono (su reloj puede estar mal). Una hora de recepción en el futuro (reloj del nodo atrasado) cuenta como ahora.
- Sólo cuentan reportes con **coordenadas utilizables** (`hasUsableCoordinates`); los que no las tienen se cuentan aparte y se dicen («N reportes sin ubicación no entran»). Las revisiones posteriores de un reporte no cuentan como actividad (sólo el primer acuse): límite declarado.
- Es una **proyección pura de lo que el nodo ya tiene**, servida aparte (`GET /api/coverage`, tras el código de acceso como todo `/api/`): no entra en la cola, la lista, el resumen ni la huella.
- Hasta **400 celdas** (las de más reportes), con el total real y cuántas se muestran.
- En el mapa es una capa **debajo** de los marcadores, sin toques, y con un **interruptor**; su leyenda dice «Silencio no es seguridad». Sin cambiar el tamaño del lienzo ni del estado.

## Tarea 1 · nodo: `coverage.dart` y `GET /api/coverage`

- Crear `apps/node/lib/src/coverage.dart`: `class CoverageReport { double lat, lon; int receivedAtMs; int urgencyRank; }` (compacto y enviable entre isolates), `class CoverageCell`, `Map<String, Object?> buildCoverage(List<CoverageReport> reports, {required int nowMs, required int withoutLocation, double cellDeg = 0.005, Duration activity = 6 h, Duration silence = 30 min, int maxCells = 400})` (pura), constantes `kCoverageCellDeg`, `kCoverageActivityWindow`, `kCoverageSilenceWindow`.
- Modificar `incidents.dart` (`Projection.coverage`, `projectionFromEvents` lo llena), `queue_service.dart` (`QueueRead.coverage`), `api.dart` (`GET /api/coverage`), `sard_node.dart` (exportar).
- Pruebas (`apps/node/test/coverage_test.dart`): una celda con reportes hace 2 h y ninguno hace 30 min es **silenciosa**; con uno reciente **no**; reportes fuera de la ventana de 6 h no cuentan; dos reportes a 100 m caen en la MISMA celda y a 2 km en otra; el resultado no depende del orden de entrada; un reporte sin coordenadas utilizables no entra y se cuenta; hora de recepción en el futuro cuenta como ahora; con más de 400 celdas se devuelven 400 y el total real; los extremos exactos de las ventanas (6 h y 30 min); celdas con coordenadas negativas (hemisferio y meridiano) y en el borde de la rejilla; `cellsTotal`/`shown`; `GET /api/coverage` pide el código de acceso y no está en la cola ni en la lista; la huella no cambia.
- Mutaciones: ventanas, signo del piso, orden, tope, conteo sin ubicación, futuro.

## Tarea 2 · tablero: modelo, cliente, capa e interruptor

- `models.dart`: `CoverageCell`, `CoverageInfo.fromJson` tolerante (nulo si el nodo es anterior: 404); `api.dart`: `coverage()`; `fake_api.dart`.
- `incident_map.dart`: parámetro `coverage`; capa de celdas silenciosas bajo los marcadores (`IgnorePointer`), con etiqueta accesible («Zona que reportó 5 veces en 6 h y no reporta desde hace 47 min; el silencio no es seguridad»); interruptor «Silencio» junto a «Reencuadrar»; leyenda y conteo («N zonas en silencio · M reportes sin ubicación no entran») en un rótulo propio sobre el lienzo (como el de unidades), sin tocar el estado de los incidentes.
- `dashboard_screen.dart`: lee la cobertura sólo con el interruptor encendido (no gasta red si no se pide); un 401 bloquea como el resto; un nodo anterior no rompe nada.
- Pruebas: celdas dentro del encuadre se dibujan y las de fuera se cuentan; la capa no captura toques ni tapa un P1; el lienzo no cambia de tamaño con la capa; interruptor apagado = ni se pide ni se dibuja; 360 px; etiqueta accesible; nodo anterior; la leyenda dice que el silencio no es seguridad.
- Mutaciones y comprobación en Chrome contra un nodo real.

## Tarea 3 · cerrar dos menores del plan anterior

- T19 mide DIRECTAMENTE cuántos reportes de la ráfaga eran de C por rendezvous (`rendezvousOwner` sobre los tres) e informa cuántos cubrió el relevo; se repite la corrida y se corrige el informe.
- `detailWithHistory`: medir cuánto cuesta con un incidente de 2 000 miembros y, si pasa de un presupuesto razonable, topar los miembros consultados diciéndolo; si no, dejarlo medido y documentado.

## Tarea 4 · documentación y cierre

- README, PDF §6.7, `docs/resultados/cobertura.md` (qué hace, decisiones, límites), guion, lámina del tablero (nota), batería completa verde, push, memoria.

## Qué mirar con lupa (Review Focus)

1. **Una celda con un solo reporte viejo** es «silencio» aunque fuera un mensaje suelto: se informa el número de reportes de la celda para que se lea con eso.
2. **Reloj del nodo atrasado o adelantado:** la recepción en el futuro cuenta como ahora; si el reloj del nodo está atrasado, todo parece reciente y la capa calla: límite declarado, no se corrige.
3. **Un nodo recién reiniciado o sin datos:** sin reportes en 6 h no hay celdas y la capa dice «sin zonas»; no se interpreta como «todo en calma».
4. **El interruptor apagado no cuesta red ni altura.**
