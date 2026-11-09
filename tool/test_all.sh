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
  # T09/T10/T15: partición + kill -9 + reconexión, y la MISMA semilla debe dar la MISMA huella.
  run "Demostración adversa (partición, kill -9, huella reproducible)" env PART=4 bash tool/demo.sh 42
  # T12: el modelo (falso) cuelga, falla o devuelve basura y el ACK no se entera; reparto y relevo entre nodos.
  # (los resultados se escriben en un archivo temporal: el informe oficial se regenera a mano con más tramas)
  run "T12 modelo colgado/roto + relevo (100 tramas)" dart run packages/sim/bin/t12.dart --reports 100 --out "$OUT.t12.md"
  # Un modelo COLGADO + una ráfaga con el límite típico de 1 024 descriptores: el nodo debe seguir vivo y acusarlo todo
  # (sin el tope de consultas simultáneas moría con «Too many open files»: 2 726 de 5 000 tramas rechazadas).
  run "Ráfaga con el modelo colgado y ulimit 1024" bash -c 'ulimit -n 1024; dart run packages/sim/bin/burst.dart --reports 3000 --llm hang --max-seconds 240 --out "$0.burst.md"' "$OUT"
  # T14 estructural con una semilla: ningún P1 queda fuera de la vista inicial.
  run "T14 ningún P1 fuera de la vista (1 semilla)" dart run packages/sim/bin/t14.dart --seeds 401 --out "$OUT.t14.md"
  # El tablero COMPILADO, servido por un nodo real con un escenario fijo, abierto en Chrome sin cabeza.
  printf '%-34s' "Tablero web compilado (Chrome)"
  bash tool/web_smoke.sh > "$OUT" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then echo "OK    $(tail -1 "$OUT")"
  elif [ $rc -eq 77 ]; then echo "OMITIDA  $(tail -1 "$OUT")"
  else echo "FALLÓ"; tail -15 "$OUT"; fail=1; fi
  # Códigos de acceso con 3 nodos reales (puertos 8191–8193): 401 sin código, réplica con código de pares.
  printf '%-34s' "Códigos de acceso (3 nodos)"
  bash tool/access_check.sh > "$OUT" 2>&1; rc=$?
  if [ $rc -eq 0 ]; then echo "OK    $(tail -1 "$OUT")"; else echo "FALLÓ"; tail -20 "$OUT"; fail=1; fi
fi
rm -f "$OUT" "$OUT.t12.md" "$OUT.t14.md" "$OUT.burst.md"
[ "$fail" -eq 0 ] && echo "TODO EN VERDE" || { echo "HAY FALLOS"; exit 1; }
