#!/bin/bash
# LidwingCore is the half of this product that builds and unit-tests on Linux in seconds.
# That property is load-bearing for the whole development loop, and it is exactly one careless
# `import AppKit` away from being lost. This script is the guard, and it is meant to be run
# locally as well as in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE="Sources/LidwingCore"
FAIL=0

# Frameworks that would tie the core to Darwin. Foundation is portable and is the only
# dependency the core is allowed.
FORBIDDEN='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(AppKit|Cocoa|IOKit|CoreAudio|AudioToolbox|CoreGraphics|Darwin|SwiftUI|UserNotifications|ServiceManagement|CoreFoundation|Security|SystemConfiguration)\b'

if grep -rEn "$FORBIDDEN" "$CORE"; then
  echo "FAIL: LidwingCore imports a platform-specific framework (above)."
  FAIL=1
fi

# Shelling out to pmset or ioreg for a control decision is banned everywhere but the
# read-only diagnostics panel; in the core it is banned outright.
if grep -rEn '(Process\(\)|posix_spawn|/usr/bin/pmset|/usr/sbin/ioreg|NSTask)' "$CORE"; then
  echo "FAIL: LidwingCore spawns a process. All system access goes through SystemFacade."
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  # Assert on real output, never on the absence of an error: prove we actually looked at files.
  COUNT=$(find "$CORE" -name '*.swift' | wc -l | tr -d ' ')
  if [ "$COUNT" -lt 1 ]; then
    echo "FAIL: found no Swift files under $CORE — this check proved nothing."
    exit 1
  fi
  echo "core purity OK ($COUNT files scanned)"
fi

exit "$FAIL"
