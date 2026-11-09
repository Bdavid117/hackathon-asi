# T11 · Cola bajo ráfaga — ejecuciones

Una sección por ejecución, para comparar entre etapas. Datos sintéticos; un solo nodo; ver «Qué mide y qué no» en `b5.md`.

## Ráfaga · Etapa 0 · línea base ANTES de optimizar (n=10 000)

- Fecha: 2026-11-08T21:42:30.271185 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 515.6 s (19 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 730 ms / 1742 ms / 2058 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 842 ms / 1730 ms / 1985 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 4.1 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 8.9 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 4.1 s |
| Eventos en el log del nodo | 35951 |

## Ráfaga · Etapa 0 · tras sacar la auditoría de la ruta del ACK y un solo lote por trama (n=10 000)

- Fecha: 2026-11-08T21:46:35.229248 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 8.9 s (1124 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 11 ms / 27 ms / 143 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 14 ms / 57 ms / 143 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 1.8 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 1.8 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 4.9 s |
| Eventos en el log del nodo | 34549 |

## Ráfaga · Etapa 1 · con personas y evidencia en la cola (n=10 000)

- Fecha: 2026-11-08T22:24:26.477311 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 10.2 s (982 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 13 ms / 32 ms / 297 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 16 ms / 36 ms / 209 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 2.3 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 2.3 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 4.9 s |
| Eventos en el log del nodo | 33767 |

## Ráfaga · Etapa 3 · con incidentes, recomendaciones y estado de nodos (n=10 000)

- Fecha: 2026-11-08T22:51:05.180485 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 10.1 s (990 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 12 ms / 30 ms / 173 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 16 ms / 40 ms / 123 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 2.8 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 2.8 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 5.1 s |
| Incidentes tras la ráfaga: `/api/incidents` | 9758 filas, 7742 KB, 51 ms; suma de tamaños 10002 (reportes acusados: 10002) |
| Detalle de un incidente: `/api/incidents/<id>` | 5 KB, 5 ms (el mayor tiene 5 reportes) |
| Eventos en el log del nodo | 33868 |

## Ráfaga · Etapa 3 · vista corta de incidentes (n=10 000)

- Fecha: 2026-11-08T22:56:50.710066 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 9.6 s (1042 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 12 ms / 31 ms / 123 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 17 ms / 47 ms / 108 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 2.4 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 2.4 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 5.0 s |
| Vista corta `/api/incidents` (lo que pide el tablero) | 4463 filas, 3985 KB, 17 ms · de 9758 incidentes (1751 «SOS sin detalle» agregados, 3544 en seguimiento fuera de la vista) |
| ¿Algún P1 fuera de la vista corta? | 1909 de 1909 P1 dentro |
| Una página completa `?view=all&limit=1000` | 975 KB, 20 ms |
| Detalle `/api/incidents/<id>` | 4 KB, 5 ms (el mayor de la primera página tiene 3 reportes) |
| Eventos en el log del nodo | 33959 |

## Ráfaga · Etapa 5 · con reparto del trabajo caro entre nodos (n=10 000, un nodo)

- Fecha: 2026-11-08T23:44:35.331067 · reportes pedidos: 10000 · concurrencia: 16 · semilla: 1 · tope: 900 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real).

- Ráfaga completa en 10.1 s (992 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 10002 / 0 |
| Latencia del ACK p50 / p95 / máx | 12 ms / 32 ms / 209 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 17 ms / 70 ms / 129 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 2.6 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 2.6 s |
| Reportes en la cola al final / acusados | 10002 / 10002 |
| Tiempo extra hasta ver todo tras la última trama | 5.3 s |
| Vista corta `/api/incidents` (lo que pide el tablero) | 4463 filas, 3985 KB, 30 ms · de 9758 incidentes (1751 «SOS sin detalle» agregados, 3544 en seguimiento fuera de la vista) |
| ¿Algún P1 fuera de la vista corta? | 1909 de 1909 P1 dentro |
| Una página completa `?view=all&limit=1000` | 975 KB, 18 ms |
| Detalle `/api/incidents/<id>` | 4 KB, 6 ms (el mayor de la primera página tiene 3 reportes) |
| Eventos en el log del nodo | 33922 |

## Ráfaga · Etapa 6 · 5 000 tramas con el modelo COLGADO, ulimit 1024, con tope de consultas

- Fecha: 2026-11-09T00:22:23.940462 · reportes pedidos: 5000 · concurrencia: 16 · semilla: 1 · tope: 300 s
- Nodo: un proceso real (`dart run`, JIT) con pares ninguno; reportes sintéticos con texto en la rev 0 (más pesados que un SOS real). **Modelo FALSO en modo `hang`** (el nodo arranca con `--llm on`): peticiones recibidas por el servidor falso al terminar: 16.

- Ráfaga completa en 1.6 s (3176 tramas/s).

| Medida | Valor |
|---|---|
| Tramas acusadas / fallidas | 5002 / 0 |
| Latencia del ACK p50 / p95 / máx | 3 ms / 9 ms / 91 ms |
| Capacidad de respuesta del nodo (`/api/health` durante la ráfaga) p50 / p95 / máx | 4 ms / 71 ms / 71 ms |
| Un **P1** plantado a mitad de la ráfaga aparece en la cola tras | 0.6 s |
| Un **P4** plantado a la vez aparece en la cola tras (antigüedad atendida) | 0.6 s |
| Reportes en la cola al final / acusados | 5002 / 5002 |
| Tiempo extra hasta ver todo tras la última trama | 2.1 s |
| Vista corta `/api/incidents` (lo que pide el tablero) | 2288 filas, 2024 KB, 8 ms · de 4866 incidentes (847 «SOS sin detalle» agregados, 1731 en seguimiento fuera de la vista) |
| ¿Algún P1 fuera de la vista corta? | 909 de 909 P1 dentro |
| Una página completa `?view=all&limit=1000` | 951 KB, 5 ms |
| Detalle `/api/incidents/<id>` | 4 KB, 1 ms (el mayor de la primera página tiene 3 reportes) |
| Eventos en el log del nodo | 17663 |
| Modelo (consultas / usadas / omitidas por el tope / respaldos) | 16 / 0 / 3973 / {} |

