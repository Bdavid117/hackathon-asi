#!/usr/bin/env bash
# Fija el nivel de batería del emulador (100, 15 y 3 %) y comprueba que el main() real, leyendo
# la batería con el plugin, cambia entre modo normal, ahorro y sólo SOS. Siempre restablece la
# batería del emulador al terminar.
#   bash tool/android_battery_check.sh [ID_EMULADOR]
set -u
cd "$(dirname "$0")/.."
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
DEV="${1:-emulator-5554}"
restore() {
  "$ADB" -s "$DEV" shell dumpsys battery reset >/dev/null 2>&1
  "$ADB" -s "$DEV" emu power ac on >/dev/null 2>&1
  "$ADB" -s "$DEV" emu power capacity 100 >/dev/null 2>&1
}
trap restore EXIT
fail=0
for pair in "100:normal" "15:saver" "3:sosOnly"; do
  level="${pair%%:*}"; mode="${pair##*:}"
  # La consola del emulador cambia la batería emulada (la que lee el plugin); `dumpsys battery
  # set` sólo altera el broadcast y no basta.
  "$ADB" -s "$DEV" emu power ac off >/dev/null 2>&1
  "$ADB" -s "$DEV" emu power capacity "$level" >/dev/null 2>&1
  sleep 2
  OUT=$(mktemp)
  if (cd apps/mobile && flutter test integration_test/battery_test.dart -d "$DEV" --dart-define=EXPECT="$mode" > "$OUT" 2>&1); then
    printf '✓ batería %3s %% → modo %-8s\n' "$level" "$mode"
  else
    printf '✗ batería %3s %% → modo %-8s FALLÓ\n' "$level" "$mode"; tail -12 "$OUT"; fail=1
  fi
  rm -f "$OUT"
done
[ "$fail" -eq 0 ] && echo "BATERÍA REAL EN VERDE" || { echo "HAY FALLOS"; exit 1; }
