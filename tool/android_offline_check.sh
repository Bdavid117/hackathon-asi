#!/usr/bin/env bash
# Verifica en el emulador de Android el escenario central del enunciado:
#   SOS sin conexión → queda guardado → no llega nada al nodo → al volver la red sale solo.
# Apaga y enciende la red del emulador con adb; SIEMPRE la deja encendida al terminar.
#   bash tool/android_offline_check.sh [ID_EMULADOR]    (por defecto emulator-5554)
set -u
cd "$(dirname "$0")/.."
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
DEV="${1:-emulator-5554}"
OUT=$(mktemp)
restore() { "$ADB" -s "$DEV" shell svc wifi enable >/dev/null 2>&1; "$ADB" -s "$DEV" shell svc data enable >/dev/null 2>&1; pkill -f "sard-A-offline" 2>/dev/null; }
trap restore EXIT

pkill -f "bin/sard_node.dart" 2>/dev/null; sleep 1; rm -rf /tmp/sard-A-offline
(cd apps/node && nohup dart run bin/sard_node.dart --id A --port 8081 --data /tmp/sard-A-offline > /dev/null 2>&1 &)
for _ in $(seq 1 60); do curl -s localhost:8081/api/health >/dev/null 2>&1 && break; sleep 0.5; done

"$ADB" -s "$DEV" shell svc wifi disable; "$ADB" -s "$DEV" shell svc data disable; sleep 3
"$ADB" -s "$DEV" shell dumpsys connectivity | grep -q "Active default network: none" || { echo "✗ no se pudo dejar el emulador sin red"; exit 2; }
echo "· emulador sin red"

(cd apps/mobile && flutter test integration_test/offline_test.dart -d "$DEV" --dart-define=NODES=http://10.0.2.2:8081 > "$OUT" 2>&1 &)
for _ in $(seq 1 240); do
  grep -q "SOS_TAPPED" "$OUT" && break
  grep -q "Some tests failed" "$OUT" && { echo "✗ la prueba falló antes de tocar SOS"; tail -15 "$OUT"; exit 1; }
  sleep 1
done
grep -q "SOS_TAPPED" "$OUT" || { echo "✗ la app no llegó a tocar SOS"; exit 1; }
echo "· SOS tocado sin red; esperando 12 s…"
sleep 12
events=$(curl -s 'localhost:8081/api/events?origin=A&after=0' | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
[ "$events" = "0" ] && echo "✓ sin red no llegó nada al nodo (0 eventos)" || { echo "✗ el nodo recibió $events eventos sin red"; exit 1; }

T0=$(date +%s)
"$ADB" -s "$DEV" shell svc wifi enable; "$ADB" -s "$DEV" shell svc data enable
echo "· red devuelta"
for _ in $(seq 1 120); do
  n=$(curl -s localhost:8081/api/queue | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)
  [ "$n" = "1" ] && break; sleep 1
done
[ "${n:-0}" = "1" ] && echo "✓ el reporte llegó al nodo $(( $(date +%s) - T0 )) s después de volver la red" || { echo "✗ el reporte nunca llegó"; exit 1; }
for _ in $(seq 1 90); do grep -q "All tests passed\|Some tests failed" "$OUT" && break; sleep 1; done
grep -q "All tests passed" "$OUT" && echo "✓ la prueba de integración pasó (la app mostró «Enviado a un nodo»)" || { echo "✗ la prueba de integración falló"; tail -15 "$OUT"; exit 1; }
rm -f "$OUT"
