#!/usr/bin/env bash
# Códigos de acceso de punta a punta, con dos nodos REALES: el tablero (coordinador) y la réplica (pares).
#   · sin código: 401 en lo del coordinador y en /api/events; /api/health, /frame y el tablero siguen abiertos
#   · con el código del coordinador: 200; con el de pares en lo del coordinador: 401 (no son intercambiables)
#   · la réplica A→B SIGUE funcionando con el código de pares, y un nodo C con otro código no replica nada
#   · IDENTIDAD (nodo D con --coordinator-codes): el código de Luis no firma como Ana ni aprobando, ni informando, ni declarando
#     un recurso (403 y el log no crece); sin «who» se firma a nombre del dueño del código; /api/whoami lo dice
# Uso: bash tool/access_check.sh      (usa los puertos 8191–8194)
set -u
cd "$(dirname "$0")/.."
pkill -f "bin/sard_node.dart" 2>/dev/null; sleep 1
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
expect() { local want="$1" got="$2" what="$3"; [ "$got" = "$want" ] && ok "$what ($got)" || bad "$what: esperaba $want y fue $got"; }
D=$(mktemp -d)
# El tablero compilado (apps/dashboard/build/web) lo ignora git: si no está, se omite sólo esa comprobación.
WEB=""; [ -f apps/dashboard/build/web/index.html ] && WEB="--web-root ../dashboard/build/web"
start() { # id puerto coord par peers
  (cd apps/node && SARD_COORDINATOR_TOKEN="$3" SARD_PEER_TOKEN="$4" nohup dart run bin/sard_node.dart --id "$1" --port "$2" --data "$D/$1" --peers "$5" $WEB > "$D/$1.log" 2>&1 &)
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
expect 401 "$(code localhost:8191/api/resources)" "GET /api/resources"
expect 401 "$(code -X POST -H 'content-type: application/json' -d '{}' localhost:8191/api/resources)" "POST /api/resources"
expect 401 "$(code 'localhost:8191/api/events?origin=A')" "GET /api/events"
expect 200 "$(code localhost:8191/api/health)" "GET /api/health (abierto)"
if [ -n "$WEB" ]; then expect 200 "$(code localhost:8191/)" "tablero estático (abierto)"; else echo "  - tablero estático: OMITIDO (no hay apps/dashboard/build/web)"; fi
echo "Con códigos"
expect 200 "$(code -H 'Authorization: Bearer coord-AAAA' localhost:8191/api/incidents)" "coordinador → /api/incidents"
expect 401 "$(code -H 'Authorization: Bearer pares-1234' localhost:8191/api/incidents)" "código de pares → /api/incidents"
expect 200 "$(code -H 'Authorization: Bearer coord-AAAA' localhost:8191/api/resources)" "coordinador → /api/resources"
expect 401 "$(code -H 'Authorization: Bearer pares-1234' localhost:8191/api/resources)" "código de pares → /api/resources"
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

echo "Identidad: nodo D con dos códigos de coordinador (sin --coordinator-token)"
(cd apps/node && SARD_COORDINATOR_CODES="Ana Gómez=ana-codigo-26,Luis Torres=luis-codigo-26" SARD_PEER_TOKEN=pares-1234 nohup dart run bin/sard_node.dart --id D --port 8194 --data "$D/D" > "$D/D.log" 2>&1 &)
for _ in $(seq 1 80); do curl -s "localhost:8194/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
ANA='Authorization: Bearer ana-codigo-26'; LUIS='Authorization: Bearer luis-codigo-26'; J='content-type: application/json'
events() { curl -s localhost:8194/api/health | python3 -c 'import sys,json; print(json.load(sys.stdin)["events"])'; }
body() { curl -s "$@"; }
expect 401 "$(code localhost:8194/api/incidents)" "D: sin código → 401 (los códigos protegen aunque no haya token)"
expect 401 "$(code -H 'Authorization: Bearer pares-1234' localhost:8194/api/incidents)" "D: el código de pares no abre lo del coordinador"
expect 200 "$(code -H "$LUIS" localhost:8194/api/incidents)" "D: Luis → /api/incidents"
[ "$(body -H "$ANA" localhost:8194/api/whoami)" = '{"who":"Ana Gómez"}' ] && ok "D: /api/whoami dice «Ana Gómez» con su código" || bad "D: /api/whoami no dice Ana"
APPR='{"recommendationId":"a1b2c3d4e5f60718","incidentId":"aa-1","members":["aa-1"],"decision":"granted","note":""'
UNIT='{"id":"AMB-01","kind":"ambulancia","label":"Ambulancia 1","lat":5.07,"lon":-75.51,"available":false'
DISP='{"id":"a1b2c3d4e5f6a7b8","text":"edificio con gente atrapada","medium":"telefono"'
n0=$(events)
expect 403 "$(code -X POST -H "$LUIS" -H "$J" -d "$APPR,\"who\":\"Ana Gómez\"}" localhost:8194/api/approval)" "D: el código de Luis NO aprueba como Ana"
expect 403 "$(code -X POST -H "$LUIS" -H "$J" -d "$DISP,\"who\":\"Ana Gómez\"}" localhost:8194/api/dispatch)" "D: el código de Luis NO registra un informe como Ana"
expect 403 "$(code -X POST -H "$LUIS" -H "$J" -d "$UNIT,\"who\":\"Ana Gómez\"}" localhost:8194/api/resources)" "D: el código de Luis NO declara un recurso como Ana"
[ "$(events)" = "$n0" ] && ok "D: los tres 403 no añadieron ningún evento" || bad "D: un 403 dejó un evento en el log"
expect 200 "$(code -X POST -H "$LUIS" -H "$J" -d "$APPR}" localhost:8194/api/approval)" "D: Luis aprueba SIN «who»"
expect 200 "$(code -X POST -H "$ANA" -H "$J" -d "$UNIT}" localhost:8194/api/resources)" "D: Ana declara un recurso SIN «who»"
ev=$(curl -s -H "$ANA" localhost:8194/api/resources | python3 -c 'import sys,json; print(json.load(sys.stdin)["resources"][0].get("declaredBy"))' 2>/dev/null)
[ "$ev" = "Ana Gómez" ] && ok "D: la unidad quedó declarada por «Ana Gómez» (el dueño del código)" || bad "D: declaredBy fue «$ev»"
pkill -f "bin/sard_node.dart" 2>/dev/null
[ "$fail" -eq 0 ] && echo "CÓDIGOS DE ACCESO: OK" || { echo "CÓDIGOS DE ACCESO: FALLÓ"; exit 1; }
