#!/bin/bash
# Every file the app resolves at runtime must be a file the build actually puts in the bundle.
#
# These two lists live in different files, were written weeks apart, and nothing connects them.
# A rename on one side produces an app that launches, looks fine, and silently has no watchdog —
# which is the one component whose absence means a Mac can be left unable to sleep.
#
# This is the packaging version of the lesson from audit round 4: feature A was correct when
# written, feature B made it wrong without touching it, and no test of either one notices.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 2; }

# Deliberately no `set -e`. Every value below is extracted with grep, and grep exits non-zero
# when it finds nothing - which is precisely the case each guard exists to report. Under `set -e`
# the script died at the failing extraction and exited 1 having printed nothing, so a real
# mismatch was indistinguishable from the script crashing. Found by its own positive control.
FAIL=0

# Reads one quoted value out of a Swift constant. Empty output means "not found", which callers
# must treat as a failure rather than as an empty match.
extract() {
  grep -oE "$2" "$1" 2>/dev/null | head -1 | grep -oE '"[a-z.-]+"' | tr -d '"'
}

expect_in_build() {
  local what="$1" why="$2"
  if grep -q "$what" Scripts/build.sh; then
    echo "  ok    build.sh installs '$what'  ($why)"
  else
    echo "  FAIL  nothing in build.sh installs '$what'  ($why)"
    FAIL=1
  fi
}

expect_signed() {
  local what="$1"
  if grep -q "$what" Scripts/sign.sh; then
    echo "  ok    sign.sh signs '$what'"
  else
    echo "  FAIL  sign.sh does not sign '$what' - notarization rejects an unsigned nested Mach-O"
    FAIL=1
  fi
}

echo "== bundle contract"

# The watchdog. Its absence is the one that matters: without it, a kill -9 while armed leaves a
# Mac that cannot sleep on lid close until reboot.
WATCHDOG="$(extract Sources/LidwingApp/WatchdogInstaller.swift 'appendingPathComponent\("lidwingd"\)')"
if [ -z "$WATCHDOG" ]; then
  echo "  FAIL  could not find the watchdog filename the app looks for"
  FAIL=1
else
  expect_in_build "Resources/$WATCHDOG" "the dead-man; without it a kill -9 strands the machine"
  expect_signed "Resources/$WATCHDOG"
fi

# The hook helper, named in the portable module because it is also written into third-party
# config files.
NOTIFY="$(extract Sources/LidwingCore/Constants.swift 'notifyHelperName = "[a-z-]+"')"
if [ -z "$NOTIFY" ]; then
  echo "  FAIL  could not find the notify helper name in Constants.swift"
  FAIL=1
else
  expect_in_build "Resources/$NOTIFY" "the path written into ~/.claude/settings.json"
  expect_signed "Resources/$NOTIFY"
fi

# The watchdog agent plist, whose filename is derived from the launchd label.
LABEL="$(extract Sources/LidwingCore/Constants.swift 'watchdogLabel = "[a-z.]+"')"
if [ -z "$LABEL" ]; then
  echo "  FAIL  could not find the watchdog label"
  FAIL=1
else
  if [ -f "Resources/$LABEL.plist" ]; then
    echo "  ok    Resources/$LABEL.plist exists"
  else
    echo "  FAIL  Resources/$LABEL.plist is missing; SMAppService would find nothing"
    FAIL=1
  fi
  expect_in_build "$LABEL.plist" "the launchd agent definition"
fi

# The bundle identifier appears in the build environment, the plist template and the code.
BUNDLE_ID="$(extract Sources/LidwingCore/Constants.swift 'bundleID = "[a-z.]+"')"
if [ -z "$BUNDLE_ID" ]; then
  # Without this guard an empty value turns the greps below into `grep "BUNDLE_ID: "`, which
  # matches any line at all and reports success for a check that did not happen.
  echo "  FAIL  could not extract the bundle identifier from Constants.swift"
  FAIL=1
else
  for file in .github/workflows/ci.yml .github/workflows/release.yml; do
    # Anchored, with the dots escaped: an unanchored substring match reports success for
    # `ai.flymy.lidwing2`, which is exactly the drift this check exists to catch.
    if grep -qE "BUNDLE_ID: ${BUNDLE_ID//./\\.}[[:space:]]*$" "$file"; then
      echo "  ok    $file uses $BUNDLE_ID"
    else
      echo "  FAIL  $file does not set BUNDLE_ID to $BUNDLE_ID"
      FAIL=1
    fi
  done
fi

if [ "$FAIL" -ne 0 ]; then
  echo "BUNDLE CONTRACT BROKEN"
  exit 1
fi
echo "bundle contract OK"
