#!/usr/bin/env bash
# Prueba de humo del tablero COMPILADO: lo sirve un nodo real, con un escenario fijo, y se abre en Chrome
# sin cabeza; se comprueba en la captura que la barra de triaje se pintó con los contadores del nodo.
#   bash tool/web_smoke.sh [--no-build]
# Sale con 0 si pasa, 1 si falla y 77 si no hay Chrome (se omite, y se dice).
set -u
cd "$(dirname "$0")/.."
PORT=8099
CHROME="${CHROME:-}"
if [ -z "$CHROME" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then CHROME="$c"; break; fi
  done
fi
[ -n "$CHROME" ] || { echo "SIN CHROME: se omite la prueba de humo del tablero web (defina CHROME=ruta)"; exit 77; }

if [ "${1:-}" != "--no-build" ]; then
  (cd apps/dashboard && flutter build web --no-web-resources-cdn >/tmp/web_smoke_build.log 2>&1) || { echo "FALLÓ la compilación del tablero (ver /tmp/web_smoke_build.log)"; exit 1; }
fi
[ -f apps/dashboard/build/web/index.html ] || { echo "no hay apps/dashboard/build/web: compile primero"; exit 1; }

D=$(mktemp -d); SHOT=$(mktemp -u).png
cleanup() { [ -n "${NP:-}" ] && kill "$NP" 2>/dev/null; wait "$NP" 2>/dev/null; rm -rf "$D" "$SHOT"; }
trap cleanup EXIT
(cd apps/node && dart run bin/sard_node.dart --id A --port $PORT --data "$D" --web-root ../dashboard/build/web --resources ../../config/recursos.json >/dev/null 2>&1 & echo $! >"$D/pid")
sleep 1; NP=$(cat "$D/pid" 2>/dev/null)
for _ in $(seq 1 60); do curl -s localhost:$PORT/api/health >/dev/null 2>&1 && break; sleep 0.5; done
curl -s localhost:$PORT/api/health >/dev/null 2>&1 || { echo "el nodo no arrancó"; exit 1; }
dart run packages/sim/bin/seed_scenario.dart --node http://localhost:$PORT >/dev/null || { echo "no se pudo poblar el nodo"; exit 1; }
TITLE=$(curl -s localhost:$PORT/ | grep -o '<title>[^<]*</title>')
[ "$TITLE" = "<title>SARD · Tablero del coordinador</title>" ] || { echo "título inesperado: $TITLE"; exit 1; }
"$CHROME" --headless=new --disable-gpu --use-angle=swiftshader --enable-unsafe-swiftshader --hide-scrollbars \
  --window-size=1360,860 --virtual-time-budget=12000 --screenshot="$SHOT" "http://localhost:$PORT/" >/dev/null 2>&1
[ -s "$SHOT" ] || { echo "Chrome no produjo la captura"; exit 1; }
python3 -I tool/web_smoke_check.py "$SHOT"
