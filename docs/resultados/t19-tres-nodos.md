# T19 · tres nodos: relevo del modelo y convergencia

Fecha: 2026-11-10T00:36:00.225323 · commit `6505dc9` (árbol limpio) · semilla 43 · 90 reportes acusados (ráfaga de 30) · `--takeover 6`.

Tres nodos reales (procesos `dart run`) en malla completa a través de seis proxies con interruptor, cada uno con su modelo FALSO (A `ok`, B `cautious`, C `ok`). Se mide el relevo del trabajo del modelo con TRES nodos (T12 lo midió con dos), el aislamiento de uno de ellos y la convergencia de los tres al reunirse.

## Criterio (propio del diseño, no del enunciado; commiteado antes de ejecutar)

1. huellas de A, B y C idénticas en ≤ 90 s tras reiniciar C y restablecer los enlaces; 2. la ráfaga de 30 reportes con texto acaba con juicio del modelo en ≤ 60 s desde el `kill -9` de C aunque C fuera dueño de parte; 3. 0 reportes acusados perdidos; 4. las decisiones contradictorias se conservan y los tres nodos muestran «denegada» con discrepancia; 5. ningún nodo muere por su cuenta.

## Resultado

- ✓ huellas de A, B y C idénticas en 2,9 s tras reiniciar C y restablecer los enlaces (criterio 1: ≤ 90 s)
- ✓ relevo: 30 de 30 reportes de la ráfaga con juicio del modelo en 8,1 s tras matar a C (criterio 2: ≤ 60 s)
- ✓ cero reportes acusados perdidos: 90 acusados y la cola de cada nodo tiene 90 / 90 / 90 (criterio 3)
- ✓ las dos decisiones contradictorias se conservan y los TRES nodos muestran «denegada» con la discrepancia marcada (criterio 4)
- ✓ ningún proceso murió por su cuenta (sólo el kill -9 deliberado de C) (criterio 5)

**Veredicto: cumple los cinco criterios.**

## Lo que se mide sin criterio

- Tiempo hasta cubrir la ráfaga tras matar a C: **8,1 s**.
- Tiempo real hasta converger los tres: **2,9 s**.
- Juicios del modelo por nodo de origen: A=45, C=16, B=46. Reportes juzgados por MÁS DE UN nodo (cómputo duplicado): **17**; de ellos, con urgencia distinta: **7**.

## Lo que esto NO demuestra

- Nodos y modelos locales y sintéticos. El relevo se mide con UNA muerte; el aislamiento de B es total (no parcial); sólo una corrida por semilla; criterios y montaje del mismo autor que el sistema.
- El orden de relevo con más de tres nodos no se midió.

## Cómo reproducirlo

```bash
dart run packages/sim/bin/t19_tres_nodos.dart --reports 90 --burst 30 --seed 43   # desde la raíz, con el árbol limpio y la máquina sin carga
```

---

## Lectura (escrita a mano; regenerar el informe con el script la borra si no se vuelve a pegar)

**Los cinco criterios, fijados antes de ejecutar (commit `40aeba5`), se cumplen.**

- **Hubo dos corridas.** La primera dio los mismos veredictos, pero su reparto por nodo salió multiplicado por tres (A=135, B=138, C=48 para 90 reportes): un error mío de contabilidad (cada juicio se contaba una vez por cada nodo consultado, y los tres ya habían convergido). Lo corregí con una prueba (`NodeProbe.uniqueById`) y repetí la corrida; este informe es el de la repetición. El reparto correcto cuadra: 107 juicios = 90 reportes + 17 con juicio de más de un nodo.
- **Relevo con tres nodos:** los 30 reportes de la ráfaga tuvieron juicio del modelo 8,1 s después de matar a C, cerca del `--takeover 6` más un ciclo de réplica de 3 s. Eso cuadra con un relevo, pero **no se midió cuántos de los 30 eran de C** (el reparto por rendezvous no se imprimió): se sabe que la ráfaga se cubrió, no cuánta de esa cobertura fue relevo.
- **Cómputo duplicado:** 17 reportes los juzgaron dos o más nodos (el aislamiento de B y la muerte de C los dejaron como dueños únicos de lo suyo) y en 7 los juicios difieren en la urgencia, porque los modelos contestan distinto a propósito (A y C `ok`, B `cautious`). Aun así los tres nodos muestran lo mismo (huellas idénticas): es la misma regla que T18 (queda la urgencia más grave y, si difieren, se marca la discrepancia).
- **Convergencia en 2,9 s** al reiniciar C con su disco y restablecer todos los enlaces; las dos decisiones contradictorias (Ana en A, Luis en B aislado) se conservaron y los tres nodos acabaron en «denegada» con la discrepancia a la vista.

**Lo que NO demuestra:** una sola muerte y un solo aislamiento, de 30 s (T18 cubre el largo con dos nodos); aislamiento total, no parcial; nodos y modelos locales y sintéticos; el orden de relevo con más de tres nodos no se midió; una corrida por semilla; criterios y montaje del mismo autor que el sistema.
