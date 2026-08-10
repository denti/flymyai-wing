#!/bin/bash
# .dmg as the primary artifact, .zip for scripted installs.
#
# Never .pkg: it cannot be ad-hoc signed at all, so the no-account path would have no
# artifact. And no `brew install create-dmg` - a minute of runner time for a background image
# nobody looks at in a menu-bar utility.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_NAME:-Lidwing}"
VER="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "dist/$APP.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ \
  "dist/$APP-$VER.dmg"
ditto -c -k --sequesterRsrc --keepParent "dist/$APP.app" "dist/$APP-$VER.zip"

if [ "${SIGN_ID:-}" != "" ] && [ "${SIGN_ID}" != "-" ]; then
  codesign --force --sign "$SIGN_ID" --timestamp "dist/$APP-$VER.dmg"
  # Staple the disk image too: the ticket then survives an offline first launch, which is
  # exactly the case stapling exists for.
  xcrun stapler staple "dist/$APP-$VER.dmg"
fi

shasum -a 256 "dist/$APP-$VER.dmg" "dist/$APP-$VER.zip" | tee "dist/SHA256SUMS.txt"
