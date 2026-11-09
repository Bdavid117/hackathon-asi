#!/usr/bin/env bash
# El canal del despachador de punta a punta, con nodos REALES (procesos, HTTP, disco):
#   · un informe entra por POST /api/dispatch, pasa por los agentes y aparece en /api/incidents como fuente «radio»
#   · un reintento no duplica; el mismo id con otro contenido es 409; lo que no es JSON, 415; roto, 400; enorme, 413
#   · conviven con las tramas de la app (POST /frame)
#   · kill -9 y reinicio con el log en disco: el nodo ARRANCA (un report.received sin frame_seq lo tumbaba) y lo conserva
#   · con --coordinator-token: sin código 401 y nada escrito; con él, 200
#   · la réplica lleva el informe a otro nodo, que lo muestra con su fuente
# Uso: bash tool/dispatch_check.sh      (usa los puertos 8194–8196; sólo mata a SUS nodos)
set -u
cd "$(dirname "$0")/.."
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
expect() { local want="$1" got="$2" what="$3"; [ "$got" = "$want" ] && ok "$what ($got)" || bad "$what: esperaba $want y fue $got"; }
D=$(mktemp -d)
cleanup() { { for p in 8194 8195 8196; do pkill -9 -f "sard_node.dart --id [A-Z0-9]* --port $p"; done; sleep 1; rm -rf "$D"; } 2>/dev/null; }
trap cleanup EXIT
for p in 8194 8195 8196; do pkill -9 -f "sard_node.dart --id [A-Z0-9]* --port $p" 2>/dev/null; done; sleep 1

start() { # id puerto [código-del-coordinador] [pares]
  (cd apps/node && env ${3:+SARD_COORDINATOR_TOKEN="$3"} nohup dart run bin/sard_node.dart --id "$1" --port "$2" --data "$D/$1" ${4:+--peers "$4"} > "$D/$1.log" 2>&1 & disown)
  for _ in $(seq 1 80); do curl -s "localhost:$2/api/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "el nodo $1 no arrancó"; cat "$D/$1.log"; exit 1
}
kill9() { { pkill -9 -f "sard_node.dart --id $1 --port $2"; sleep 1; } 2>/dev/null; }
events() { curl -s "localhost:$1/api/health" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["events"])'; }
total() { curl -s "localhost:$1/api/incidents" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["total"])'; }
first_obs() { # puerto → la observación de fuente «radio» (de cualquier incidente), como JSON
  python3 -I - "$1" <<'PY'
import sys, json, urllib.request, urllib.parse
base = f"http://localhost:{sys.argv[1]}"
get = lambda path: json.load(urllib.request.urlopen(base + path))
for it in get("/api/incidents")["items"]:
    for o in get("/api/incidents/" + urllib.parse.quote(it["id"], safe=""))["observations"]:
        if o.get("source") == "radio":
            print(json.dumps(o)); sys.exit(0)
print("{}")
PY
}
field() { python3 -I -c 'import sys,json; print(json.load(sys.stdin).get(sys.argv[1]))' "$1" 2>/dev/null; }

cat > "$D/informe.json" <<'EOF'
{"id":"chk0123456789ab","text":"hay un edificio caído con gente atrapada en el barrio centro","medium":"radio","origin":"Estación 3","who":"Ana Gómez","flags":["atrapado"],"people":2}
EOF
sed 's/hay un edificio caído/OTRA COSA distinta/' "$D/informe.json" > "$D/otro-contenido.json"
HEX=$(python3 -I -c "import json; print([x for x in json.load(open('packages/protocol/test/vectors/vectors.json')) if x['name']=='sos_min'][0]['hex'])")
echo "$HEX" | xxd -r -p > "$D/frame.bin"
post() { curl -s -w '\n%{http_code}' -X POST -H 'content-type: application/json' --data-binary @"$1" "localhost:$2/api/dispatch" "${@:3}"; }

echo "Un nodo sin códigos (A, :8194)"
start A 8194
r=$(post "$D/informe.json" 8194); expect 200 "${r##*$'\n'}" "POST /api/dispatch"
[ "$(echo "${r%$'\n'*}" | field duplicate)" = "False" ] && ok "responde duplicate=false" || bad "no responde duplicate=false: $r"
expect 1 "$(total 8194)" "el informe aparece como UN incidente en /api/incidents"
o=$(first_obs 8194)
[ "$(echo "$o" | field source)" = "radio" ] && ok "su fuente es «radio»" || bad "fuente: $o"
[ "$(echo "$o" | field registeredBy)" = "Ana Gómez" ] && ok "dice quién lo registró (Ana Gómez)" || bad "registrador: $o"
[ "$(echo "$o" | field origin)" = "Estación 3" ] && ok "dice de quién viene (Estación 3)" || bad "origen: $o"
[ "$(echo "$o" | field lat)" = "None" ] && ok "sin ubicación (no se inventa)" || bad "tiene ubicación: $o"
n=$(events 8194)
r=$(post "$D/informe.json" 8194); expect 200 "${r##*$'\n'}" "el REINTENTO (mismo id, mismo contenido)"
[ "$(echo "${r%$'\n'*}" | field duplicate)" = "True" ] && ok "el reintento responde duplicate=true" || bad "reintento: $r"
[ "$(events 8194)" = "$n" ] && ok "el reintento no escribe nada ($n eventos)" || bad "el reintento escribió: $n → $(events 8194)"
r=$(post "$D/otro-contenido.json" 8194); expect 409 "${r##*$'\n'}" "el mismo id con OTRO contenido"
[ "$(events 8194)" = "$n" ] && ok "el conflicto no escribe nada" || bad "el conflicto escribió"
expect 415 "$(code -X POST -H 'content-type: text/plain' --data-binary @"$D/informe.json" localhost:8194/api/dispatch)" "texto plano (un formulario de otra página)"
expect 400 "$(code -X POST -H 'content-type: application/json' -d '{no es json' localhost:8194/api/dispatch)" "JSON roto"
expect 400 "$(code -X POST -H 'content-type: application/json' -d '{"id":"chk0123456789zz","text":"","medium":"radio","who":"Ana"}' localhost:8194/api/dispatch)" "texto vacío"
head -c 9000 /dev/zero | tr '\0' 'a' > "$D/enorme.bin"
expect 413 "$(code -X POST -H 'content-type: application/json' --data-binary @"$D/enorme.bin" localhost:8194/api/dispatch)" "cuerpo de 9 000 bytes"
[ "$(events 8194)" = "$n" ] && ok "nada de lo rechazado escribió un evento" || bad "un rechazo escribió"

echo "Conviven con las tramas de la app"
expect 200 "$(code -X POST --data-binary @"$D/frame.bin" localhost:8194/frame)" "POST /frame"
expect 2 "$(total 8194)" "ahora hay 2 incidentes (el informe y el SOS de la app)"

echo "kill -9 y reinicio con el log en disco"
kill9 A 8194
start A 8194
ok "el nodo ARRANCÓ otra vez con un informe sin frame_seq en el log"
expect 2 "$(total 8194)" "tras el reinicio siguen los 2 incidentes"
r=$(post "$D/informe.json" 8194); [ "$(echo "${r%$'\n'*}" | field duplicate)" = "True" ] && ok "el reintento tras el reinicio sigue siendo un reintento" || bad "reintento tras reinicio: $r"

echo "Con --coordinator-token (B, :8195)"
start B 8195 coord-check-1
r=$(post "$D/informe.json" 8195); expect 401 "${r##*$'\n'}" "sin código"
r=$(post "$D/informe.json" 8195 -H 'Authorization: Bearer otro-codigo'); expect 401 "${r##*$'\n'}" "con un código equivocado"
[ "$(events 8195)" = "0" ] && ok "lo no autorizado no escribió nada" || bad "se escribió algo sin autorización"
r=$(post "$D/informe.json" 8195 -H 'Authorization: Bearer coord-check-1'); expect 200 "${r##*$'\n'}" "con el código del coordinador"
expect 401 "$(code localhost:8195/api/incidents)" "y leer la cola sigue pidiendo código"

echo "La réplica lleva el informe a otro nodo (C, :8196, replica de A)"
start C 8196 "" http://localhost:8194
for _ in $(seq 1 30); do [ "$(total 8196)" = "2" ] && break; sleep 1; done
expect 2 "$(total 8196)" "C tiene los 2 incidentes replicados de A"
o=$(first_obs 8196)
[ "$(echo "$o" | field source)" = "radio" ] && [ "$(echo "$o" | field origin)" = "Estación 3" ] && ok "C muestra el informe con su fuente y su origen" || bad "C no muestra la fuente: $o"
kill9 C 8196
start C 8196 "" http://localhost:8194
expect 2 "$(total 8196)" "C reinicia con el evento replicado en su log y sigue mostrándolos"

[ "$fail" -eq 0 ] && echo "INFORME DE DESPACHADOR: OK" || { echo "INFORME DE DESPACHADOR: FALLÓ"; exit 1; }
