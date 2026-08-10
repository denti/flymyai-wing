#!/bin/bash
# Builds the universal binaries and assembles Lidwing.app.
#
# Uses only documented SwiftPM surface. `swift build --arch` is a **hidden** flag: absent from
# `swift build --help`, present only in `--help-hidden`, and with no deprecation contract. It
# works today, but the universal-binary story is load-bearing for this product and is not built
# on a flag Apple has never blessed. Two single-arch builds plus `lipo` produce byte-equivalent
# output and use nothing undocumented.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_NAME:-Lidwing}"
BUNDLE="${BUNDLE_ID:-ai.flymy.lidwing}"
MIN="${MACOS_MIN:-12.0}"
VER="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"
# Zero-padded to ten digits: a code-signing requirement compares this as a string, and
# unpadded "1.10" sorts below "1.9".
BUILD="$(printf '%010d' "$(git rev-list --count HEAD 2>/dev/null || echo 1)")"

PRODUCTS=(Lidwing lidwingd lidwing-notify)
ARCHS=(arm64 x86_64)

for product in "${PRODUCTS[@]}"; do
  for arch in "${ARCHS[@]}"; do
    echo "== $product ($arch)"
    swift build -c release --scratch-path ".b-$arch" --product "$product" \
      -Xswiftc -target -Xswiftc "$arch-apple-macos$MIN" \
      -Xcc     -target -Xcc     "$arch-apple-macos$MIN"
  done
done

rm -rf dist
mkdir -p "dist/$APP.app/Contents/"{MacOS,Resources,Library/LaunchAgents}

lipo -create -output "dist/$APP.app/Contents/MacOS/$APP" \
  ".b-arm64/release/Lidwing" ".b-x86_64/release/Lidwing"
lipo -create -output "dist/$APP.app/Contents/Resources/lidwingd" \
  ".b-arm64/release/lidwingd" ".b-x86_64/release/lidwingd"
lipo -create -output "dist/$APP.app/Contents/Resources/lidwing-notify" \
  ".b-arm64/release/lidwing-notify" ".b-x86_64/release/lidwing-notify"

sed -e "s/@VERSION@/$VER/g" -e "s/@BUILD@/$BUILD/g" -e "s/@BUNDLE_ID@/$BUNDLE/g" \
    -e "s/@APP@/$APP/g"     -e "s/@MIN@/$MIN/g" \
    Resources/Info.plist.in > "dist/$APP.app/Contents/Info.plist"
printf 'APPL????' > "dist/$APP.app/Contents/PkgInfo"

cp Resources/ai.flymy.lidwing.watchdog.plist "dist/$APP.app/Contents/Library/LaunchAgents/"

# The app icon, generated from the same wing geometry the menu-bar glyph uses, so the two
# cannot drift apart.
swiftc -O -o "$(pwd)/.b-arm64/make-icon" Scripts/make-icon.swift Sources/LidwingCore/WingGeometry.swift
"$(pwd)/.b-arm64/make-icon" dist/icon_1024.png

if [ -f dist/icon_1024.png ]; then
  rm -rf /tmp/LidwingIcon.iconset
  mkdir -p /tmp/LidwingIcon.iconset
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" dist/icon_1024.png \
      --out "/tmp/LidwingIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" dist/icon_1024.png \
      --out "/tmp/LidwingIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns /tmp/LidwingIcon.iconset -o "dist/$APP.app/Contents/Resources/AppIcon.icns"
fi

echo "built dist/$APP.app  version=$VER build=$BUILD min=$MIN"
