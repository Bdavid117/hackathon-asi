#!/usr/bin/env bash
# Ejecuta toda la batería del proyecto: pruebas de cada paquete (VM y Chrome para el
# protocolo), análisis estático y el recorrido de punta a punta H1 con pérdida de nodo.
#   bash tool/test_all.sh            # todo
#   bash tool/test_all.sh --sin-e2e  # sin el recorrido H1 (más rápido)
set -u
cd "$(dirname "$0")/.."
fail=0
OUT=$(mktemp)
run() {
  local name="$1"; shift
  printf '%-34s' "$name"
  if "$@" > "$OUT" 2>&1; then
    echo "OK    $(grep -E 'All tests passed|No issues found|H1 OK' "$OUT" | tail -1 | sed -E 's/^[0-9:]+ //')"
  else
    echo "FALLÓ"; tail -15 "$OUT"; fail=1
  fi
}
run "protocol (VM + Chrome)"  bash -c 'cd packages/protocol && dart test -p vm,chrome'
run "client_core"             bash -c 'cd packages/client_core && dart test'
run "agents"                  bash -c 'cd packages/agents && dart test'
run "sim"                     bash -c 'cd packages/sim && dart test'
run "node"                    bash -c 'cd apps/node && dart test'
run "mobile (widgets)"        bash -c 'cd apps/mobile && flutter test'
run "dashboard (widgets)"     bash -c 'cd apps/dashboard && flutter test'
for d in packages/protocol packages/client_core packages/agents packages/sim apps/node; do
  run "analyze $d" bash -c "cd $d && dart analyze"
done
for d in apps/mobile apps/dashboard; do
  run "analyze $d" bash -c "cd $d && flutter analyze"
done
if [ "${1:-}" != "--sin-e2e" ]; then
  run "H1 recorrido E2E (seed 42)" dart run packages/sim/bin/e2e_skeleton.dart --seed 42
  # Con más de 300 reportes el nodo calcula la cola en otro isolate: se recorre esa rama con nodos REALES.
  run "H1 con cola grande: rama del isolate (350 reportes)" dart run packages/sim/bin/e2e_skeleton.dart --seed 7 --reports 350
fi
rm -f "$OUT"
[ "$fail" -eq 0 ] && echo "TODO EN VERDE" || { echo "HAY FALLOS"; exit 1; }
