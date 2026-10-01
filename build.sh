#!/bin/bash
# Runs the self-tests, then builds a universal, ad-hoc signed Cascade.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Cascade.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

echo "→ Self-tests"
swift run -c release CascadeSelfTest | tail -1

echo "→ Compiling Cascade $VERSION (arm64 + x86_64)"
BINS=()
for arch in arm64 x86_64; do
  swift build -c release --product Cascade --triple "$arch-apple-macosx13.0" >/dev/null
  BINS+=("$(swift build -c release --product Cascade --triple "$arch-apple-macosx13.0" --show-bin-path)/Cascade")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Cascade"
strip -x "$APP/Contents/MacOS/Cascade"
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

# An ad-hoc signature's default designated requirement is the binary's cdhash, which changes on every
# build. macOS ties the Accessibility grant to that requirement, so each rebuild would silently lose the
# permission (the app keeps asking even though System Settings shows it enabled). Pinning the requirement
# to the bundle identifier keeps the grant valid across rebuilds and updates.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Resources/Info.plist)
echo "→ Signing (ad-hoc, hardened runtime, stable requirement)"
codesign --force --options runtime --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --strict "$APP"

echo "→ Packaging"
(cd build && rm -f "Cascade-$VERSION.zip" && ditto -c -k --keepParent Cascade.app "Cascade-$VERSION.zip")
echo "✓ Built $APP and build/Cascade-$VERSION.zip"
