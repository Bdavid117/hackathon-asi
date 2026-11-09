#!/usr/bin/env bash
# APK de la app ciudadana (Android, modo release) con la dirección del nodo ya puesta.
#
#   bash tool/build_apk.sh              # para el CELULAR: la IP de esta Mac en la Wi-Fi (y localhost, para adb reverse por USB)
#   bash tool/build_apk.sh emulador     # para el emulador de Android: http://10.0.2.2:8081
#   bash tool/build_apk.sh 192.168.1.7  # para el celular con otra IP
#
# El APK queda en dist/ (fuera de git). La dirección se compila DENTRO de la app (--dart-define=NODES): si la IP de la Mac
# cambia (otra Wi-Fi), hay que generarlo otra vez. Va firmado con la clave de depuración: sirve para instalarlo a mano,
# no para publicarlo en una tienda.
set -eu
cd "$(dirname "$0")/.."
destino="${1:-celular}"
case "$destino" in
  emulador)
    NODES="http://10.0.2.2:8081"
    salida="SARD-emulador.apk"
    ;;
  celular)
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    [ -n "$ip" ] || { echo "No encuentro la IP de esta Mac en la Wi-Fi: pásala como argumento (bash tool/build_apk.sh 192.168.1.7)."; exit 1; }
    NODES="http://$ip:8081,http://localhost:8081"
    salida="SARD-celular.apk"
    ;;
  *)
    NODES="http://$destino:8081,http://localhost:8081"
    salida="SARD-celular.apk"
    ;;
esac
echo "Nodos que llevará la app: $NODES"
(cd apps/mobile && flutter build apk --release --dart-define=NODES="$NODES")
mkdir -p dist
cp apps/mobile/build/app/outputs/flutter-apk/app-release.apk "dist/$salida"
echo "Listo: dist/$salida ($(du -h "dist/$salida" | cut -f1))"
