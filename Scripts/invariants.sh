#!/bin/bash
# Assertions about the built artifact. Every one of these must pass or the build fails.
#
# These exist because "it compiled" and "CI was green" are both compatible with shipping a
# thinned binary, a wrong deployment target, a weakly linked concurrency runtime that crashes
# on the first `await` at macOS 11, or an Info.plist that quietly declares a permission the app
# does not need. Each check below has a specific failure it prevents.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_NAME:-Lidwing}"
MIN="${MACOS_MIN:-12.0}"
BUNDLE="dist/$APP.app"
BINARY="$BUNDLE/Contents/MacOS/$APP"
FAIL=0
CHECKS=0

# The number of invariants this script is expected to run. It exists so the script can apply
# this project's own rule to itself: a run that checked nothing must not report success. An
# early `exit` on a missing file, or a `for` loop over nested binaries that found none, would
# otherwise print a short list of passes and a cheerful final line.
#
# Overridable so the guard can be *proven* rather than asserted: CI runs this script a second
# time with an impossible number and requires it to fail. A gate nobody has watched fail is a
# gate of unknown value, and this one cannot be exercised from Linux - there is no `lipo`,
# `codesign` or `plutil` here, so the script dies long before it reaches this line.
EXPECTED_CHECKS="${EXPECTED_CHECKS:-15}"

check() {
  CHECKS=$((CHECKS + 1))
  if [ "$1" -eq 0 ]; then
    echo "  ok    $2"
  else
    echo "  FAIL  $2"
    FAIL=1
  fi
}

echo "== artifact invariants for $BUNDLE"

if [ -x "$BINARY" ]; then check 0 "the executable exists and is executable"
else check 1 "the executable exists and is executable"; fi

# A thinned binary ships to half the users and works for the other half, which is the worst
# possible way to find out.
ARCHS="$(lipo -archs "$BINARY" 2>/dev/null || echo "")"
echo "  archs: $ARCHS"
echo "$ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ' | grep -q 'arm64 x86_64'
check $? "universal: both arm64 and x86_64 slices present"

# Two load commands, one per slice.
MINOS_COUNT="$(otool -l "$BINARY" | grep -c "minos $MIN" || true)"
if [ "$MINOS_COUNT" -eq 2 ]; then check 0 "minos $MIN on both slices (found $MINOS_COUNT)"
else check 1 "minos $MIN on both slices (found $MINOS_COUNT)"; fi

# The one that produces a random-looking EXC_BAD_ACCESS on exactly the old OS versions a low
# deployment target exists to reach.
if otool -L "$BINARY" | grep -i 'libswift_Concurrency' | grep -qi weak; then
  check 1 "concurrency runtime is hard-linked, not weak"
else
  check 0 "concurrency runtime is hard-linked, not weak"
fi

for nested in Resources/lidwingd Resources/lidwing-notify; do
  path="$BUNDLE/Contents/$nested"
  if [ -f "$path" ]; then
    lipo -archs "$path" | tr ' ' '\n' | sort | tr '\n' ' ' | grep -q 'arm64 x86_64'
    check $? "$nested is universal"
  else
    check 1 "$nested is present"
  fi
done

codesign --verify --deep --strict --verbose=2 "$BUNDLE" >/dev/null 2>&1
check $? "signature verifies (deep, strict)"

PLIST="$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>/dev/null | grep -qx true
check $? "LSUIElement is true (menu-bar only, no Dock icon)"

/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null | grep -qx "$MIN"
check $? "LSMinimumSystemVersion is $MIN"

/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$PLIST" 2>/dev/null | grep -qx true
check $? "a second instance is prohibited"

# The build number is compared as a string inside a code-signing requirement. Ten digits makes
# lexicographic order equal numeric order.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "")"
echo "$BUILD_NUMBER" | grep -Eq '^[0-9]{10}$'
check $? "CFBundleVersion is zero-padded to ten digits (got '$BUILD_NUMBER')"

# Zero usage descriptions. This is a claim any user can check in one command, and it is the
# difference between a permission dialog they believe and one they do not.
if plutil -p "$PLIST" | grep -qi UsageDescription; then
  check 1 "Info.plist declares no *UsageDescription keys"
else
  check 0 "Info.plist declares no *UsageDescription keys"
fi

# The structural proof of the no-telemetry claim, checkable offline on the downloaded binary.
# Lidwing is signed with no entitlements at all, so this output is empty rather than merely
# free of the network key.
ENTITLEMENTS="$(codesign -d --entitlements - "$BUNDLE" 2>/dev/null || true)"
if printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.network.client'; then
  check 1 "no network-client entitlement"
else
  check 0 "no network-client entitlement"
fi
if printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security'; then
  echo "  note  the bundle declares entitlements: $(printf '%s' "$ENTITLEMENTS" | tr -d '\n')"
else
  check 0 "the bundle declares no entitlements at all"
fi

# The legacy privileged-helper layout. Its presence would mean someone reintroduced a root
# daemon without updating this file.
if [ -e "/Library/LaunchDaemons/ai.flymy.lidwing.helper.plist" ] \
   || [ -e "/Library/PrivilegedHelperTools/ai.flymy.lidwing.helper" ]; then
  check 1 "no legacy privileged-helper artifacts on this machine"
else
  check 0 "no legacy privileged-helper artifacts on this machine"
fi

echo "SUMMARY invariants=$CHECKS fail=$FAIL"

# Empty is never success. If fewer checks ran than this artifact has invariants, something
# returned early and the passes above describe a fraction of the bundle.
if [ "$CHECKS" -lt "$EXPECTED_CHECKS" ]; then
  echo "INVARIANTS INCOMPLETE: ran $CHECKS of $EXPECTED_CHECKS - this proved less than it claims"
  exit 1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "INVARIANTS FAILED"
  exit 1
fi
echo "invariants OK"
