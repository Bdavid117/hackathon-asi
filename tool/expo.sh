#!/usr/bin/env bash
# Demostración EN VIVO: dos nodos que se replican (A :8081, B :8082), el tablero compilado servido por los dos y el escenario de EXPOSICIÓN
# (datos sintéticos, seis horas de historia, con zonas que callaron) ya cargado en A y replicado a B. Se queda en primer plano; Ctrl+C
# apaga los dos nodos y borra los datos temporales. No usa el modelo de lenguaje ni la red (no gasta API).
#   bash tool/expo.sh [--build] [--seed 7] [--empty]
#     --build   recompila el tablero web antes (hace falta si cambió la interfaz: los nodos sirven lo compilado)
#     --seed N  otra historia sintética (por omisión 7: la del guion)
#     --empty   nodos vacíos, sin escenario
# Variables: PORT_A (8081), PORT_B (8082).
set -u
cd "$(dirname "$0")/.."
PORT_A="${PORT_A:-8081}"; PORT_B="${PORT_B:-8082}"
SEED=7; BUILD=0; EMPTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1 ;;
    --seed) SEED="${2:?--seed pide un número}"; shift ;;
    --empty) EMPTY=1 ;;
    *) echo "opción desconocida: $1"; exit 64 ;;
  esac
  shift
done

for port in "$PORT_A" "$PORT_B"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "El puerto $port ya está en uso (¿otra demostración o una prueba corriendo?). Ciérrela o use PORT_A/PORT_B."
    exit 1
  fi
done

if [ "$BUILD" = 1 ] || [ ! -f apps/dashboard/build/web/index.html ]; then
  echo "Compilando el tablero web (1–2 min)…"
  (cd apps/dashboard && flutter build web --no-web-resources-cdn >/tmp/sard_expo_build.log 2>&1) || { echo "FALLÓ la compilación (ver /tmp/sard_expo_build.log)"; exit 1; }
fi

D=$(mktemp -d "${TMPDIR:-/tmp}/sard-expo.XXXXXX")
POINTER="${TMPDIR:-/tmp}/sard-expo.current"
cleanup() {
  # El nodo es hijo del lanzador `dart run`: se apaga el que ESCUCHA y el lanzador (aunque se haya reiniciado con expo_ctl.sh).
  for port in "$PORT_A" "$PORT_B"; do kill $(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null) 2>/dev/null; done
  for x in A B; do [ -f "$D/$x.pid" ] && kill "$(cat "$D/$x.pid")" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$D" "$POINTER"
  echo; echo "Nodos apagados y datos temporales borrados."
}
trap cleanup EXIT INT TERM

mkdir -p "$D/A" "$D/B"
printf 'D=%s\nPORT_A=%s\nPORT_B=%s\n' "$D" "$PORT_A" "$PORT_B" >"$POINTER"
if [ "$EMPTY" = 0 ]; then
  echo "Sembrando el escenario de exposición (semilla $SEED)…"
  (cd apps/node && dart run tool/seed_expo.dart --data "$D/A" --id A --seed "$SEED" 2>&1 | grep -v "build hooks") || { echo "FALLÓ la siembra"; exit 1; }
fi

(cd apps/node && dart run bin/sard_node.dart --id A --port "$PORT_A" --data "$D/A" --peers "http://localhost:$PORT_B" --web-root ../dashboard/build/web --resources ../../config/recursos.json >"$D/A.log" 2>&1 & echo $! >"$D/A.pid")
(cd apps/node && dart run bin/sard_node.dart --id B --port "$PORT_B" --data "$D/B" --peers "http://localhost:$PORT_A" --web-root ../dashboard/build/web --resources ../../config/recursos.json >"$D/B.log" 2>&1 & echo $! >"$D/B.pid")
sleep 1

for port in "$PORT_A" "$PORT_B"; do
  for _ in $(seq 1 120); do curl -s "localhost:$port/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -s "localhost:$port/api/health" >/dev/null 2>&1 || { echo "el nodo en :$port no arrancó (ver $D/*.log)"; exit 1; }
done

events() { curl -s "localhost:$1/api/nodes" | python3 -c "import sys,json; print(json.load(sys.stdin)['self']['events'])" 2>/dev/null; }
for _ in $(seq 1 60); do
  [ "$(events "$PORT_A")" = "$(events "$PORT_B")" ] && [ -n "$(events "$PORT_A")" ] && break
  sleep 1
done
EA=$(events "$PORT_A"); EB=$(events "$PORT_B")
SILENT=$(curl -s "localhost:$PORT_A/api/coverage" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['silentTotal'])" 2>/dev/null)

cat <<MSG

══════════════ SARD · demostración en vivo ══════════════
 Nodo A  http://localhost:$PORT_A   ($EA eventos)
 Nodo B  http://localhost:$PORT_B   ($EB eventos)   ← se replican entre sí
 Zonas en silencio ahora: ${SILENT:-?}  (en el tablero: Mapa → «Silencio»)

 Abra DOS ventanas del navegador, una por nodo (cada una depende del nodo que la sirve).
 La app en el simulador:
   cd apps/mobile && flutter run -d <simulador> --dart-define=NODES=http://localhost:$PORT_A,http://localhost:$PORT_B
   (emulador de Android: http://10.0.2.2:$PORT_A,http://10.0.2.2:$PORT_B)
 Matar el nodo A:      bash tool/expo_ctl.sh kill A      (kill -9 de verdad: el servidor y su lanzador)
 Volver a levantarlo:  bash tool/expo_ctl.sh start A     (con su mismo disco)
 Estado de los dos:    bash tool/expo_ctl.sh status
 Guion, tiempos y plan B: docs/pitch/demo-en-vivo.md
 Ctrl+C apaga todo.
══════════════════════════════════════════════════════════
MSG
# Los nodos son nietos de esta shell (subshells): `wait` no los vería. Se queda aquí hasta Ctrl+C, que dispara la limpieza.
while true; do sleep 1; done
