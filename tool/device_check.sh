#!/usr/bin/env bash
# Ejecuta en un dispositivo las pruebas de integración que usan el main() real contra un nodo real:
#   app_test (SOS → nodo → reabrir), main_test (agentes en el nodo), gps_test (ubicación real) y
#   details_test (SOS → «2–5 personas» → una frase → el nodo muestra personas, texto y triaje).
#   bash tool/device_check.sh android emulator-5554
#   bash tool/device_check.sh ios <UDID del simulador>
set -u
cd "$(dirname "$0")/.."
PLATFORM="${1:?uso: device_check.sh android|ios ID_DISPOSITIVO}"; DEV="${2:?falta el ID del dispositivo}"
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
case "$PLATFORM" in
  android) HOST=10.0.2.2; "$ADB" -s "$DEV" emu geo fix -75.5138 5.0703 >/dev/null 2>&1
           grant() { "$ADB" -s "$DEV" shell pm grant com.example.sard_mobile android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 \
                     && "$ADB" -s "$DEV" shell pm grant com.example.sard_mobile android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1; } ;;
  ios)     HOST=localhost; xcrun simctl location "$DEV" set 5.0703,-75.5138 >/dev/null 2>&1
           grant() { xcrun simctl privacy "$DEV" grant location com.example.sardMobile >/dev/null 2>&1; } ;;
  *) echo "plataforma desconocida: $PLATFORM"; exit 64 ;;
esac
fail=0
for t in app_test main_test gps_test details_test; do
  pkill -f "bin/sard_node.dart" 2>/dev/null; sleep 1; D=$(mktemp -d)
  (cd apps/node && nohup dart run bin/sard_node.dart --id A --port 8081 --data "$D" > /dev/null 2>&1 &)
  for _ in $(seq 1 60); do curl -s localhost:8081/api/health >/dev/null 2>&1 && break; sleep 0.5; done
  # Concede el permiso de forma continua: la instalación de la app lo borra y el momento exacto varía.
  ( while true; do grant; sleep 0.5; done ) & G=$!
  OUT=$(mktemp)
  if (cd apps/mobile && flutter test "integration_test/$t.dart" -d "$DEV" --dart-define=NODES=http://$HOST:8081 > "$OUT" 2>&1); then
    printf '✓ %-10s %s\n' "$t" "$(grep -E 'All tests passed' "$OUT" | tail -1 | sed -E 's/^[0-9:]+ //')"
  else
    printf '✗ %-10s FALLÓ\n' "$t"; tail -12 "$OUT"; fail=1
  fi
  kill $G 2>/dev/null; rm -f "$OUT"; rm -rf "$D"
done
pkill -f "bin/sard_node.dart" 2>/dev/null
[ "$fail" -eq 0 ] && echo "DISPOSITIVO $PLATFORM EN VERDE" || { echo "HAY FALLOS EN $PLATFORM"; exit 1; }
