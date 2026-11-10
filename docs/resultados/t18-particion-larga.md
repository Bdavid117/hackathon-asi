# T18 · partición larga real con dos nodos

Fecha: 2026-11-10T00:26:20.116717 · commit `80a13f3` (árbol limpio) · semilla 42 · 90 reportes con texto (más el goteo del corte: 80 adicionales) · corte de **600 s** · `--takeover 6`.

Dos nodos reales (procesos `dart run`), cada uno con su modelo FALSO y los dos configurados como pares del otro a través de un proxy con interruptor. A usa un modelo `ok` (sube a P1 lo que dice «encerrados») y B uno `cautious` (nunca sube nada): contestan DISTINTO a propósito. Se corta el enlace de verdad (el replicador sigue intentando y recibe errores de conexión), cada lado recibe reportes que el otro no ve, dos coordinadores deciden a la vez y se contradicen, y a mitad del corte se mata a B con `kill -9` y se reinicia con su mismo disco. Después se restablece el enlace.

## Criterio (propio del diseño, no del enunciado; commiteado antes de ejecutar)

1. huellas de A y B idénticas en ≤ 60 s tras restablecer; 2. 0 reportes acusados perdidos; 3. las decisiones contradictorias se conservan y ambos muestran «denegada» con discrepancia; 4. ningún nodo muere por su cuenta durante el corte; 5. el replicador registró errores de conexión durante el corte.

## Resultado

- ✓ huellas de A y B idénticas en 2,5 s tras restablecer el enlace (criterio 1: ≤ 60 s)
- ✓ cero reportes acusados perdidos: 170 acusados, 170 en la cola de A y 170 en la de B (criterio 2)
- ✓ las dos decisiones contradictorias se conservan y ambos nodos muestran «denegada» con la discrepancia marcada (criterio 3)
- ✓ ningún proceso murió por su cuenta durante el corte (sólo el kill -9 deliberado de B) (criterio 4)
- ✓ el replicador de cada nodo registró errores de conexión durante el corte: el corte fue real, no «sin pares» (criterio 5)

**Veredicto: cumple los cinco criterios.**

## Lo que se mide sin criterio

- Tiempo real hasta converger tras restablecer: **2,5 s** (la réplica sondea cada 3 s).
- Reportes con juicio del modelo: 170; con juicio de LOS DOS nodos (cómputo duplicado): **7**; de ellos, con urgencia distinta: **7**.
- Lo que cada nodo veía del otro durante el corte — a mitad: A ve a B: sin_respuesta (último error: ClientException: Connection closed before full header was received, uri=http://localhost:65339/api/health) · B ve a A: sin_respuesta (último error: ClientException: Connection closed before full header was received, uri=http://localhost:65340/api/health); al final: A ve a B: sin_respuesta · B ve a A: desconocido.

## Lo que esto NO demuestra

- Nodos y modelos locales y sintéticos: no hay red, radio ni modelo reales. El corte es total y simétrico (no hay cortes parciales ni asimétricos) y se mató a un solo nodo una vez.
- Una sola corrida por semilla; los criterios y el montaje son del mismo autor que el sistema.
- Que un corte de 10 minutos converja no dice nada de uno de horas (el log de cada nodo crece sin tope mientras tanto).

## Cómo reproducirlo

```bash
dart run packages/sim/bin/t18_particion_larga.dart --partition-seconds 600 --reports 90 --seed 42   # desde la raíz, con el árbol limpio y la máquina sin carga
```

---

## Lectura (escrita a mano; regenerar el informe con el script la borra si no se vuelve a pegar)

**Los cinco criterios, fijados antes de ejecutar (commit `6433c30`), se cumplen.** Lo que dice y lo que no:

- **El corte fue real y largo.** Durante 600 s cada nodo siguió intentando replicar contra un par configurado y recibió errores de conexión (los proxies rechazaron 200 y 199 conexiones, sólo 3 pasaron antes del corte); el estado de pares fue `sin_respuesta` con su último error. La demostración `demo.dart` no ejercita esto (arranca sin pares).
- **Converge en 2,5 s tras restablecer**, menos que un periodo de sondeo de 3 s más el cálculo: 10 minutos de aislamiento no dejaron deuda que tardara más en saldarse que 3 minutos o 20 s (T10 midió 3,1–3,6 s con particiones de 5–20 s). Con una sola corrida **no** se puede decir que sea independiente de la duración; sí que a 10 minutos no se degradó.
- **Siete reportes tuvieron juicio de los DOS modelos, y los siete con urgencia distinta** (A `ok` sube a P1 lo que dice «encerrados»; B `cautious` no sube nada). Aun así las huellas de los dos nodos son idénticas: la proyección combina los juicios de forma que no depende del orden (queda la urgencia más grave, las señales se unen y, si los juicios difieren, se marca `juicios_discrepantes`; es lo que dice `queue_view.dart`, no se auditó aquí que esos siete lo muestren).
- **Las dos decisiones contradictorias**, tomadas cada una en su lado y mantenidas 10 minutos, se conservaron y ambos nodos acabaron en «denegada» con la discrepancia a la vista, también tras el `kill -9` y reinicio de B.
- **El `kill -9` de B a mitad del corte** no perdió nada de lo acusado (170 acusados, 170 en la cola de cada nodo).

**Lo que NO demuestra:** nodos y modelos locales y sintéticos; un corte total y simétrico (no parcial); una sola muerte; una sola corrida (los siete duplicados y los 2,5 s podrían ser otros en otra); y que 10 minutos converjan no dice nada de horas. Los criterios y el montaje son del mismo autor que el sistema.
