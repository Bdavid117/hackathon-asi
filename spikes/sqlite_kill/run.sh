#!/usr/bin/env bash
# Prueba técnica A: mata con kill -9 un escritor de SQLite y comprueba que lo confirmado sobrevive.
set -u
cd "$(dirname "$0")"
DB=/tmp/sard-spike-kill.db
OUT=/tmp/sard-spike-kill.out
rm -f "$DB" "$DB-wal" "$DB-shm" "$OUT"

dart run bin/writer.dart "$DB" > "$OUT" 2>&1 &
PID=$!

# Espera hasta ver `committed 200` (máx. 60 s).
for _ in $(seq 1 600); do
  grep -q '^committed 200$' "$OUT" 2>/dev/null && break
  sleep 0.1
done
grep -q '^committed 200$' "$OUT" || { echo "FAIL: el escritor no llegó a 200 (¿falló la compilación de sqlite3?)"; tail -5 "$OUT"; exit 1; }

# kill -9 del PID y de todos sus hijos (dart run puede dejar un proceso hijo).
pkill -9 -P "$PID" 2>/dev/null
kill -9 "$PID" 2>/dev/null
sleep 0.5

# Comprobación de que no queda nadie escribiendo: un falso PASS sería peor que un FAIL.
if pgrep -f "bin/writer.dart" > /dev/null; then echo "FAIL: sigue vivo un proceso del escritor"; pgrep -fl "bin/writer.dart"; exit 1; fi
if lsof "$DB" > /dev/null 2>&1; then echo "FAIL: algún proceso mantiene abierta la base"; lsof "$DB"; exit 1; fi

LAST=$(grep -E '^committed [0-9]+$' "$OUT" | tail -1 | awk '{print $2}')
RES=$(dart run bin/verify.dart "$DB" 2>&1 | tail -1)
echo "último confirmado impreso: $LAST | verificación: $RES"
COUNT=$(echo "$RES" | sed -E 's/.*count=([0-9]+).*/\1/')
MAX=$(echo "$RES" | sed -E 's/.*max=([0-9]+).*/\1/')
if [ -z "$COUNT" ] || [ -z "$MAX" ] || ! [ "$COUNT" -eq "$COUNT" ] 2>/dev/null; then echo "FAIL: salida de verify no interpretable"; exit 1; fi
if [ "$MAX" -lt "$LAST" ]; then echo "FAIL: se perdió lo confirmado (max=$MAX < $LAST)"; exit 1; fi
if [ "$COUNT" -ne "$MAX" ]; then echo "FAIL: hay huecos (count=$COUNT max=$MAX)"; exit 1; fi
echo "PASS"
