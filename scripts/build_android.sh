#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT_DIR/scripts/fetch_models.py"
cd "$ROOT_DIR/mobile"
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
APK_DIR="${CLASSSWEEP_APK_DIR:-$HOME/apks}"
mkdir -p "$APK_DIR"
install -m 644 "$ROOT_DIR/mobile/build/app/outputs/flutter-apk/app-debug.apk" "$APK_DIR/ClassSweep-debug.apk"
echo "APK: $APK_DIR/ClassSweep-debug.apk"
