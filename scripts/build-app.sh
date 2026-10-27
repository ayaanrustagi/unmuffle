#!/usr/bin/env bash
# Builds Unmuffle.app into ./build. Needs Xcode or the Command Line Tools (Swift 5.9+).
# UNIVERSAL=1 builds for both Apple Silicon and Intel (needs full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product Unmuffle ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

APP="build/Unmuffle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Unmuffle" "$APP/Contents/MacOS/Unmuffle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS can attach the audio permission to the app.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
