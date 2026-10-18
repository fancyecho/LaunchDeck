#!/usr/bin/env bash
# Compiles LaunchDeck with swiftc and wraps it into build/LaunchDeck.app.
# Calls swiftc directly instead of SwiftPM so it works with only the Command Line
# Tools installed (some CLT releases ship a PackageDescription that fails to link).
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH="$(uname -m)"
# The macOS 27 SDK turns @State into a macro whose plugin only ships with Xcode,
# so prefer a 26.x SDK when building with the Command Line Tools alone.
SDK="$(xcrun --show-sdk-path --sdk macosx)"
CLT_SDKS=/Library/Developer/CommandLineTools/SDKs
if [[ "$SDK" == "$CLT_SDKS"/* ]]; then
  for candidate in "$CLT_SDKS"/MacOSX26.5.sdk "$CLT_SDKS"/MacOSX26.sdk; do
    if [[ -d "$candidate" ]]; then SDK="$candidate"; break; fi
  done
fi
OUT="build/$CONFIG"
mkdir -p "$OUT"

FLAGS=(-swift-version 5 -target "$ARCH-apple-macos26.0" -sdk "$SDK" -module-name LaunchDeck)
if [[ "$CONFIG" == "release" ]]; then
  FLAGS+=(-O -whole-module-optimization)
else
  FLAGS+=(-Onone -g -D DEBUG)
fi

find Sources/LaunchDeck -name '*.swift' -print0 | xargs -0 xcrun swiftc "${FLAGS[@]}" -o "$OUT/LaunchDeck"

APP="build/LaunchDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/LaunchDeck" "$APP/Contents/MacOS/LaunchDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
