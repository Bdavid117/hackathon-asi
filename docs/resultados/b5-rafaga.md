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

