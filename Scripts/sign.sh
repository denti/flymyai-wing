#!/bin/bash
# Inside-out signing. Never `--deep`.
#
# `man codesign` marks --deep "(DEPRECATED for signing as of macOS 13.0)" and warns that it
# applies every option to all nested content, "almost never what you want". It is fine for
# --verify and nowhere else.
#
# Order matters: nested Mach-Os first, the app last. Nothing may touch Info.plist after the
# final signature - doing so invalidates it, and the app then dies instantly on Apple silicon
# with no useful error anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_NAME:-Lidwing}"
IDENTITY="${1:--}"
CONTENTS="dist/$APP.app/Contents"

if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc. An unsigned arm64 Mach-O is SIGKILLed by the kernel on launch, so even with no
  # account this is mandatory, not optional. A secure timestamp needs a real identity.
  TIMESTAMP=(--timestamp=none)
  echo "== ad-hoc signing (development only; Gatekeeper will refuse this build)"
else
  TIMESTAMP=(--timestamp)
  echo "== signing with: $IDENTITY"
fi

for macho in "$CONTENTS/Resources/lidwingd" "$CONTENTS/Resources/lidwing-notify"; do
  [ -f "$macho" ] || continue
  codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$macho"
done

# No --entitlements, and that is the point: Lidwing requests nothing.
#
# An empty entitlements plist would be equivalent, except that it is a file someone can add a
# line to. With no file at all, `codesign -d --entitlements - Lidwing.app` prints nothing, and
# the absence of `com.apple.security.network.client` - which is what makes the no-telemetry
# claim checkable offline on the downloaded binary - is a property of the artifact rather than
# a promise in a document. Scripts/invariants.sh asserts it.
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "dist/$APP.app"

codesign --verify --deep --strict --verbose=2 "dist/$APP.app"
echo "signed"
