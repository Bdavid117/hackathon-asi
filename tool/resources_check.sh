#!/usr/bin/env bash
# Los recursos declarados EN VIVO, de punta a punta con nodos REALES (procesos, HTTP, disco, réplica):
#   · dos nodos AISLADOS declaran cosas DISTINTAS sobre la misma unidad (cada uno ignora lo del otro)
#   · kill -9 de uno de ellos y reinicio con el log en disco: la declaración sigue ahí
#   · al reconectarse los dos CONVERGEN en lo mismo: CONFLICTO, y la unidad queda NO DISPONIBLE (nunca se ofrece una unidad con la
#     que alguien discrepa), con las dos declaraciones vigentes
#   · una declaración que reemplaza a las dos lo resuelve, en los dos nodos
#   · lo mal formado, de otro tipo o demasiado grande no escribe nada
# Uso: bash tool/resources_check.sh      (usa los puertos 8197–8198; sólo mata a SUS nodos)
set -u
cd "$(dirname "$0")/.."
fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
expect() { local want="$1" got="$2" what="$3"; [ "$got" = "$want" ] && ok "$what ($got)" || bad "$what: esperaba $want y fue $got"; }
D=$(mktemp -d)
cleanup() { { for p in 8197 8198; do pkill -9 -f "sard_node.dart --id [A-Z0-9]* --port $p"; done; sleep 1; rm -rf "$D"; } 2>/dev/null; }
trap cleanup EXIT
for p in 8197 8198; do pkill -9 -f "sard_node.dart --id [A-Z0-9]* --port $p" 2>/dev/null; done; sleep 1

start() { # id puerto [pares]
  (cd apps/node && nohup dart run bin/sard_node.dart --id "$1" --port "$2" --data "$D/$1" --resources ../../config/recursos.json ${3:+--peers "$3"} > "$D/$1.log" 2>&1 & disown)
  for _ in $(seq 1 80); do curl -s "localhost:$2/api/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "el nodo $1 no arrancó"; cat "$D/$1.log"; exit 1
}
kill9() { { pkill -9 -f "sard_node.dart --id $1 --port $2"; sleep 1; } 2>/dev/null; }
events() { curl -s "localhost:$1/api/health" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["events"])'; }
unit() { # puerto id campo → el campo de esa unidad en /api/resources
  curl -s "localhost:$1/api/resources" | python3 -I -c 'import sys,json; u=[x for x in json.load(sys.stdin)["resources"] if x["id"]==sys.argv[1]][0]; print(json.dumps(u[sys.argv[2]]))' "$2" "$3"
}
all() { curl -s "localhost:$1/api/resources" | python3 -I -c 'import sys,json; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
post() { curl -s -w '\n%{http_code}' -X POST -H 'content-type: application/json' --data-binary @"$1" "localhost:$2/api/resources"; }
decl() { # archivo disponible etiqueta [supersedes-json]
  printf '{"id":"AMB-01","kind":"ambulancia","label":"%s","lat":5.0689,"lon":-75.5174,"available":%s,"who":"%s"%s}\n' "$3" "$2" "${5:-Ana}" "${4:+,\"supersedes\":$4}" > "$1"
}

echo "Dos nodos AISLADOS (A :8197, B :8198), cada uno con los 10 recursos de arranque"
start A 8197
start B 8198
expect '"AMB-01"' "$(curl -s localhost:8197/api/resources | python3 -I -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["resources"][0]["id"]))')" "A lista los recursos de arranque"
expect true "$(unit 8197 AMB-01 available)" "AMB-01 empieza disponible"

echo "Cada uno declara una cosa DISTINTA sobre AMB-01, sin verse"
decl "$D/a.json" false "AMB-01 sin gasolina" "" "Ana Gómez"
decl "$D/b.json" true  "AMB-01 lista" "" "Luis Pérez"
r=$(post "$D/a.json" 8197); expect 200 "${r##*$'\n'}" "A: AMB-01 NO disponible"
r=$(post "$D/b.json" 8198); expect 200 "${r##*$'\n'}" "B: AMB-01 disponible, otra etiqueta"
expect false "$(unit 8197 AMB-01 available)" "A la ve no disponible"
expect false "$(unit 8197 AMB-01 conflict)" "y todavía sin conflicto (no sabe lo de B)"
expect true  "$(unit 8198 AMB-01 available)" "B la ve disponible"

echo "kill -9 de A y reinicio con el log en disco"
kill9 A 8197
start A 8197
expect false "$(unit 8197 AMB-01 available)" "la declaración de A SIGUE ahí tras el reinicio"

echo "Se reconectan (cada uno replica del otro)"
kill9 A 8197; kill9 B 8198
start A 8197 http://localhost:8198
start B 8198 http://localhost:8197
for _ in $(seq 1 40); do [ "$(unit 8197 AMB-01 conflict)" = "true" ] && [ "$(unit 8198 AMB-01 conflict)" = "true" ] && break; sleep 1; done
expect true "$(unit 8197 AMB-01 conflict)" "A ve el CONFLICTO"
expect true "$(unit 8198 AMB-01 conflict)" "B ve el CONFLICTO"
expect false "$(unit 8197 AMB-01 available)" "A: en conflicto la unidad queda NO disponible"
expect false "$(unit 8198 AMB-01 available)" "B: lo mismo (aunque B la había declarado disponible)"
[ "$(all 8197)" = "$(all 8198)" ] && ok "A y B muestran EXACTAMENTE lo mismo en /api/resources" || bad "A y B difieren: $(all 8197) / $(all 8198)"
ids=$(unit 8197 AMB-01 declarationIds)
[ "$(echo "$ids" | python3 -I -c 'import sys,json; print(len(json.load(sys.stdin)))')" = "2" ] && ok "con las DOS declaraciones vigentes" || bad "declaraciones vigentes: $ids"

echo "Una declaración que reemplaza a las dos lo resuelve"
decl "$D/fix.json" true "AMB-01 resuelta" "$ids" "Ana Gómez"
r=$(post "$D/fix.json" 8197); expect 200 "${r##*$'\n'}" "A declara reemplazando a las dos"
for _ in $(seq 1 40); do [ "$(unit 8198 AMB-01 conflict)" = "false" ] && break; sleep 1; done
expect false "$(unit 8197 AMB-01 conflict)" "A: sin conflicto"
expect false "$(unit 8198 AMB-01 conflict)" "B: sin conflicto (replicó la resolución)"
expect '"AMB-01 resuelta"' "$(unit 8198 AMB-01 label)" "B muestra la declaración resuelta"
[ "$(all 8197)" = "$(all 8198)" ] && ok "A y B vuelven a coincidir" || bad "A y B difieren tras resolver"

echo "Lo mal formado, de otro tipo o demasiado grande no escribe nada"
n=$(events 8197)
expect 415 "$(code -X POST -H 'content-type: text/plain' --data-binary @"$D/a.json" localhost:8197/api/resources)" "texto plano"
expect 400 "$(code -X POST -H 'content-type: application/json' -d '{no es json' localhost:8197/api/resources)" "JSON roto"
expect 400 "$(code -X POST -H 'content-type: application/json' -d '{"id":"X","kind":"dron","label":"x","lat":1,"lon":1,"available":true,"who":"a"}' localhost:8197/api/resources)" "tipo desconocido"
expect 400 "$(code -X POST -H 'content-type: application/json' -d '{"id":"AMB-01","kind":"ambulancia","label":"x","lat":1,"lon":1,"available":true,"who":"a","supersedes":["no-existe"]}' localhost:8197/api/resources)" "reemplazar algo que no existe"
head -c 5000 /dev/zero | tr '\0' 'a' > "$D/enorme.bin"
expect 413 "$(code -X POST -H 'content-type: application/json' --data-binary @"$D/enorme.bin" localhost:8197/api/resources)" "cuerpo de 5 000 bytes"
[ "$(events 8197)" = "$n" ] && ok "nada de lo rechazado escribió un evento" || bad "un rechazo escribió"

[ "$fail" -eq 0 ] && echo "RECURSOS DECLARADOS: OK" || { echo "RECURSOS DECLARADOS: FALLÓ"; exit 1; }
