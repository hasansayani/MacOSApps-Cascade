#!/bin/bash
# Builds Cascade.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Cascade.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    Sources/main.swift -o "build/Cascade-$arch"
done
lipo -create build/Cascade-arm64 build/Cascade-x86_64 -output "$APP/Contents/MacOS/Cascade"
rm build/Cascade-arm64 build/Cascade-x86_64
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Rendering icon"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon_1024.png

echo "→ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
echo "✓ Built $APP"
