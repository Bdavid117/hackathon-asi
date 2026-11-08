# Prueba técnica A · SQLite ante `kill -9`

**Pregunta:** ¿`package:sqlite3` en la VM de Dart, con `journal_mode=WAL` y `synchronous=FULL`, conserva todo lo confirmado cuando matan al proceso?

**Cómo:** `bash run.sh` lanza `bin/writer.dart` (una transacción por fila, imprime `committed N` después del COMMIT), espera a la fila 200, mata con `kill -9` el PID y sus hijos, comprueba que no queda ningún proceso ni descriptor abierto sobre la base, y reabre con `bin/verify.dart`.

**Resultado (8 nov 2026, macOS arm64, Dart 3.11.5, `sqlite3` 3.5.2 — la versión del `pubspec.lock` del workspace, la misma que usan el nodo y la app):** `PASS` en 3 de 3 ejecuciones (también 3 de 3 con la 3.9.1 antes de unir la prueba al workspace). `count == max` y `max >= último confirmado impreso`; en dos ejecuciones la base contenía una fila más que la última impresa (COMMIT hecho, `kill -9` antes del `print`), que es el orden correcto: se imprime sólo lo ya confirmado. La biblioteca nativa se compila sola mediante *build hooks*.

**Alcance:** demuestra consistencia ante la **muerte del proceso**. No prueba `fsync` ni cortes de energía; esa garantía es la de `synchronous=FULL` de SQLite y no se verifica aquí.
