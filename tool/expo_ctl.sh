#!/usr/bin/env bash
# Maneja los nodos de la demostración en vivo (`tool/expo.sh` debe estar corriendo en otra terminal).
#   bash tool/expo_ctl.sh kill A|B     kill -9 del nodo: el servidor que escucha y su lanzador, sin avisarle (como un corte)
#   bash tool/expo_ctl.sh start A|B    lo vuelve a levantar con SU MISMO disco y espera a que responda
#   bash tool/expo_ctl.sh status       eventos, pares y estado de cada nodo
set -u
cd "$(dirname "$0")/.."
POINTER="${TMPDIR:-/tmp}/sard-expo.current"
[ -f "$POINTER" ] || { echo "No hay una demostración en marcha (falta $POINTER): arranque primero  bash tool/expo.sh"; exit 1; }
# shellcheck disable=SC1090
. "$POINTER"
cmd="${1:-status}"; node="${2:-}"
port_of() { [ "$1" = A ] && echo "$PORT_A" || echo "$PORT_B"; }
peer_port_of() { [ "$1" = A ] && echo "$PORT_B" || echo "$PORT_A"; }
now() { date +%H:%M:%S; }

case "$cmd" in
  kill)
    case "$node" in A|B) ;; *) echo "uso: expo_ctl.sh kill A|B"; exit 64 ;; esac
    port=$(port_of "$node")
    pids=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null)
    [ -n "$pids" ] || { echo "El nodo $node no está escuchando en :$port (¿ya está muerto?)"; exit 1; }
    [ -f "$D/$node.pid" ] && pids="$pids $(cat "$D/$node.pid")"
    kill -9 $pids 2>/dev/null
    echo "[$(now)] Nodo $node muerto con kill -9 (puerto $port, procesos: $(echo $pids))."
    ;;
  start)
    case "$node" in A|B) ;; *) echo "uso: expo_ctl.sh start A|B"; exit 64 ;; esac
    port=$(port_of "$node"); peer=$(peer_port_of "$node")
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "El nodo $node ya está escuchando en :$port"; exit 1; fi
    t0=$(date +%s)
    (cd apps/node && dart run bin/sard_node.dart --id "$node" --port "$port" --data "$D/$node" --peers "http://localhost:$peer" --web-root ../dashboard/build/web --resources ../../config/recursos.json >>"$D/$node.log" 2>&1 & echo $! >"$D/$node.pid")
    for _ in $(seq 1 120); do curl -s "localhost:$port/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
    curl -s "localhost:$port/api/health" >/dev/null 2>&1 || { echo "el nodo $node no arrancó (ver $D/$node.log)"; exit 1; }
    echo "[$(now)] Nodo $node de vuelta en $(( $(date +%s) - t0 )) s, con su mismo disco."
    ;;
  status)
    for x in A B; do
      port=$(port_of "$x")
      if out=$(curl -s --max-time 2 "localhost:$port/api/nodes" 2>/dev/null) && [ -n "$out" ]; then
        echo "$out" | python3 -c "
import sys, json
d = json.load(sys.stdin)
peers = ', '.join('%s %s' % (p['url'].split('//')[-1], p['state']) for p in d['peers']) or 'sin pares'
print('Nodo %s  %s eventos  ·  %s' % (d['self']['id'], d['self']['events'], peers))"
      else
        echo "Nodo $x  (no responde en :$port)"
      fi
    done
    ;;
  *) echo "uso: expo_ctl.sh kill|start A|B  ·  expo_ctl.sh status"; exit 64 ;;
esac
