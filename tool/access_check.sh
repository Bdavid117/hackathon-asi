#!/usr/bin/env bash
# Códigos de acceso de punta a punta, con dos nodos REALES: el tablero (coordinador) y la réplica (pares).
#   · sin código: 401 en lo del coordinador y en /api/events; /api/health, /frame y el tablero siguen abiertos
#   · con el código del coordinador: 200; con el de pares en lo del coordinador: 401 (no son intercambiables)
#   · la réplica A→B SIGUE funcionando con el código de pares, y un nodo C con otro código no replica nada
# Uso: bash tool/access_check.sh      (usa los puertos 8191–8193)
set -u
cd "$(dirname "$0")/.."
pkill -f "bin/sard_node.dart" 2>/dev/null; sleep 1
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
expect() { local want="$1" got="$2" what="$3"; [ "$got" = "$want" ] && ok "$what ($got)" || bad "$what: esperaba $want y fue $got"; }
D=$(mktemp -d)
start() { # id puerto coord par peers
  (cd apps/node && SARD_COORDINATOR_TOKEN="$3" SARD_PEER_TOKEN="$4" nohup dart run bin/sard_node.dart --id "$1" --port "$2" --data "$D/$1" --peers "$5" --web-root ../dashboard/build/web > "$D/$1.log" 2>&1 &)
  for _ in $(seq 1 80); do curl -s "localhost:$2/api/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "el nodo $1 no arrancó"; cat "$D/$1.log"; exit 1
}
start A 8191 coord-AAAA pares-1234 http://localhost:8192
start B 8192 coord-BBBB pares-1234 http://localhost:8191
start C 8193 coord-CCCC pares-9999 http://localhost:8191
# una trama real: el vector de oro «sos_min» del protocolo (firmada con la clave por omisión del nodo)
HEX=$(python3 -I -c "import json; print([x for x in json.load(open('packages/protocol/test/vectors/vectors.json')) if x['name']=='sos_min'][0]['hex'])")
echo "$HEX" | xxd -r -p > "$D/frame.bin"

echo "Sin código"
expect 401 "$(code localhost:8191/api/incidents)" "GET /api/incidents"
expect 401 "$(code localhost:8191/api/queue)" "GET /api/queue"
expect 401 "$(code localhost:8191/api/nodes)" "GET /api/nodes"
expect 401 "$(code -X POST -H 'content-type: application/json' -d '{}' localhost:8191/api/approval)" "POST /api/approval"
expect 401 "$(code 'localhost:8191/api/events?origin=A')" "GET /api/events"
expect 200 "$(code localhost:8191/api/health)" "GET /api/health (abierto)"
expect 200 "$(code localhost:8191/)" "tablero estático (abierto)"
echo "Con códigos"
expect 200 "$(code -H 'Authorization: Bearer coord-AAAA' localhost:8191/api/incidents)" "coordinador → /api/incidents"
expect 401 "$(code -H 'Authorization: Bearer pares-1234' localhost:8191/api/incidents)" "código de pares → /api/incidents"
expect 401 "$(code -H 'Authorization: Bearer coord-AAAA' 'localhost:8191/api/events?origin=A')" "código de coordinador → /api/events"
expect 200 "$(code -H 'Authorization: Bearer pares-1234' 'localhost:8191/api/events?origin=A')" "pares → /api/events"
expect 401 "$(code -H 'Authorization: Bearer coord-BBBB' localhost:8191/api/incidents)" "el código de OTRO nodo no vale"
echo "Un SOS entra por A (los ciudadanos no llevan código) y la réplica con código lo lleva a B, no a C"
ack=$(code -X POST --data-binary @"$D/frame.bin" localhost:8191/frame)
expect 200 "$ack" "POST /frame sin código"
n_b=0; for _ in $(seq 1 30); do n_b=$(curl -s localhost:8192/api/health | python3 -c 'import sys,json; print(json.load(sys.stdin)["events"])'); [ "$n_b" -ge 1 ] && break; sleep 1; done
[ "$n_b" -ge 1 ] && ok "B replicó el evento de A con el código de pares ($n_b eventos)" || bad "B no replicó (0 eventos tras 30 s)"
sleep 4; n_c=$(curl -s localhost:8193/api/health | python3 -c 'import sys,json; print(json.load(sys.stdin)["events"])')
[ "$n_c" = "0" ] && ok "C, con otro código de pares, no replicó nada (0 eventos)" || bad "C replicó $n_c eventos con un código distinto"
echo "C lo ve en /api/nodes: $(curl -s -H 'Authorization: Bearer coord-CCCC' localhost:8193/api/nodes | python3 -c 'import sys,json; d=json.load(sys.stdin); print([p.get("lastError") for p in d.get("peers",[])] or d)' 2>/dev/null | cut -c1-120)"
pkill -f "bin/sard_node.dart" 2>/dev/null
[ "$fail" -eq 0 ] && echo "CÓDIGOS DE ACCESO: OK" || { echo "CÓDIGOS DE ACCESO: FALLÓ"; exit 1; }
