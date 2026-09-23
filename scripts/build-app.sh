#!/bin/bash
# Package DiskManager.app into the build/ directory
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DiskManager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/DiskManager "$APP/Contents/MacOS/DiskManager"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# App icon: build the .icns from scripts/AppIcon.png (1024x1024)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size scripts/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double scripts/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Full Disk Access is tied to the app's code signature. An ad-hoc signature (-) changes on every build,
# so macOS silently drops the grant each time the app is rebuilt. Signing with a real identity
# (Apple Development / Developer ID) keeps the designated requirement stable and the grant survives.
# Override with CODESIGN_IDENTITY=... ; falls back to ad-hoc when no identity is installed.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E 'Developer ID Application|Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')}"
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --timestamp=none -s "$IDENTITY" "$APP"
else
    echo "No signing identity found; using ad-hoc signature (Full Disk Access must be re-granted after every build)"
    codesign --force -s - "$APP"
fi

echo "Done: $APP"
