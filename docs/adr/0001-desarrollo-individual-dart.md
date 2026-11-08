# ADR-0001 · Desarrollo individual, Dart de punta a punta y corte de alcance

- **Estado:** propuesta, validada técnicamente en B0/B1 · 8 de noviembre de 2026. Confirmados por el usuario: trabajar solo y con Flutter. **Validado:** SQLite ante `kill -9`, workspace con app + nodo + tablero Web + paquetes puros, códec en VM y Chrome, recorrido H1 (ver `docs/resultados/h1.md`). **Android validado en B2** (emulador): compila, ejecuta y `package:sqlite3` funciona. Sigue pendiente probar en hardware real.
- **Contexto de diseño:** [`docs/SARD-arquitectura-app-movil.pdf`](../SARD-arquitectura-app-movil.pdf) (versión 0.2)

## Contexto

El proyecto lo desarrolla **una sola persona** que domina **Flutter**. Dispone de un emulador de Android (`MediumAndroid`) y de un runtime de iOS 27 (todavía sin simulador creado). El plazo de la hackathon no se conoce. El enunciado evalúa un recorrido completo de ocho pasos con evidencia reproducible, no una aplicación aislada.

## Decisión

1. **Dart de punta a punta.** App móvil en Flutter, nodos supervivientes en Dart puro (`dart run`), tablero en Flutter Web. Un solo lenguaje y un solo paquete de protocolo compartido.
2. **Paquetes compartidos en Dart puro** (`protocol`, `client_core`, `agents`, `sim`): no importan `package:flutter`. Así los nodos corren sin Flutter y las pruebas no necesitan dispositivo.
3. **Android es la plataforma principal;** iOS (simulador) es la segunda. Los emuladores no prueban batería ni radio reales: esa limitación se declara en el informe de pruebas.
4. **Corte de alcance:** el plan es la columna «Mantener» del capítulo 10.3 del PDF. La profundización de los retos 4 a 6 y todo lo de «Posponer» queda como trabajo futuro y se declara como limitación.
5. **Modelo de lenguaje fuera de los primeros bloques.** Los agentes de B1 son sólo reglas; el puerto de modelo entra en B3. Dart no tiene SDK oficial de Claude: se usará HTTP directo.

## Consecuencias

- **A favor:** la curva de aprendizaje es nula; hay un único lenguaje para app, nodo, tablero y simulador; el códec se prueba una vez.
- **En contra:** el ecosistema de servidores en Dart es menor que el de Node; hay que vigilar que `int` es de 53 bits cuando Dart se compila a Web (el tablero comparte el protocolo).
- **Riesgos que se validan antes de construir** (bloque B0): SQLite durable ante `kill -9` con `package:sqlite3`, y el *workspace* con app Flutter + paquete puro + Flutter Web. Si alguna prueba falla, **es lo único que cambiaría esta decisión**.

## Alternativas descartadas

- Node.js + TypeScript para nodos y tablero: obligaría a mantener dos lenguajes y a reimplementar el códec.
- React Native: sin ventaja frente a Flutter para quien ya domina Flutter.
