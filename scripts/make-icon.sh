#!/usr/bin/env bash
# Regenerates the app icon (needs Xcode, for Icon Composer's ictool):
#   Resources/AppIcon.icon   Icon Composer document, compiled by actool at build time
#   Resources/AppIcon.icns   flat fallback for builds with only the Command Line Tools
#   docs/icon.png            README image
set -euo pipefail
cd "$(dirname "$0")/.."

xcrun swift scripts/make-icon.swift "$PWD" >/dev/null

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
render() {  # render <points> <scale> <output>
  "$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$3" --platform macOS \
    --rendition Default --width "$1" --height "$1" --scale "$2" >/dev/null
}

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  render "$size" 1 "$ICONSET/icon_${size}x${size}.png"
  render "$size" 2 "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
render 256 1 docs/icon.png
echo "Icon updated"
