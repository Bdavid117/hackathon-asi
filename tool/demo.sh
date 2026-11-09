#!/usr/bin/env bash
# Demostración con UNA condición adversa, reproducible con un comando y una semilla (entregable 7).
#
#   bash tool/demo.sh [semilla]          # por omisión 42; PART=20 segundos de partición (PART=5 para algo más corto)
#
# Levanta dos nodos reales (procesos), los parte en dos (sin pares), mata a uno con kill -9 en pleno
# procesamiento, lo reinicia midiendo el RTO, reconecta la red y compara las proyecciones. Lo ejecuta
# DOS veces con la misma semilla y comprueba que la huella sea idéntica (T15).
set -euo pipefail
cd "$(dirname "$0")/.."
SEED="${1:-42}"
PART="${PART:-20}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

for run in 1 2; do
  echo "================ Ejecución $run de 2 (semilla $SEED) ================"
  dart run packages/sim/bin/demo.dart --seed "$SEED" --partition-seconds "$PART" --json "$OUT/r$run.json" | tee "$OUT/r$run.txt"
done

H1="$(grep '^HUELLA:' "$OUT/r1.txt" | awk '{print $2}')"
H2="$(grep '^HUELLA:' "$OUT/r2.txt" | awk '{print $2}')"
echo "================ Resultado ================"
echo "huella 1: $H1"
echo "huella 2: $H2"
if [ -n "$H1" ] && [ "$H1" = "$H2" ]; then
  echo "✓ misma semilla ⇒ misma huella (T15)"
else
  echo "✗ las huellas DIFIEREN: el recorrido no es reproducible"
  exit 1
fi
grep -q '^DEMO OK' "$OUT/r1.txt" && grep -q '^DEMO OK' "$OUT/r2.txt" || { echo "✗ alguna ejecución tuvo fallos"; exit 1; }
echo "RTO (kill -9 → el nodo responde): $(grep '^RTO_HEALTH_MS' "$OUT/r1.txt" | awk '{print $2}') ms y $(grep '^RTO_HEALTH_MS' "$OUT/r2.txt" | awk '{print $2}') ms"
echo "DEMOSTRACIÓN OK"
