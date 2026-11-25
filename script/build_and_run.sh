#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="QingkongMac"
APP_BUNDLE="$ROOT_DIR/build/DerivedDataMacSigned/Build/Products/Debug/小晴空.app"
mkdir -p "$ROOT_DIR/artifacts"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
if ! xcodebuild -project "$ROOT_DIR/Qingkong.xcodeproj" -scheme "$APP_NAME" -destination 'platform=macOS' -derivedDataPath "$ROOT_DIR/build/DerivedDataMacSigned" build > "$ROOT_DIR/artifacts/build-mac.log" 2>&1; then
    tail -60 "$ROOT_DIR/artifacts/build-mac.log" >&2
    exit 1
fi
/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
    --debug) lldb -n "$APP_NAME" ;;
    --logs) /usr/bin/log stream --info --style compact --predicate 'process == "QingkongMac"' ;;
    --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "cn.geckoai.qingkong.mac"' ;;
    --verify) sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo 'Mac app process is running.' ;;
esac
