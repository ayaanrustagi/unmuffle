#!/usr/bin/env bash
# Builds Unmuffle.app into ./build. Needs Xcode or the Command Line Tools (Swift 5.9+).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Unmuffle
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Unmuffle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Unmuffle" "$APP/Contents/MacOS/Unmuffle"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS can attach the audio permission to the app.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
