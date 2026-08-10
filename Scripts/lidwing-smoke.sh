#!/bin/bash
# lidwing-smoke.sh — unattended compatibility and safety smoke test.
#
# Run it over ssh on any Mac in the matrix:
#   ssh mac 'bash -s -- --app /Applications/Lidwing.app' < Scripts/lidwing-smoke.sh
#
# Contract:
#   * **Read-only. Always.** It never writes a system setting, never asks for root, and never
#     arms anything. Tier 1 needs no privilege, so this needs none either.
#   * **SKIP is never PASS.** A green run on a Mac mini proves the bundle and the API surface
#     and nothing about a lid, and the summary says so out loud. A cell that cannot be covered
#     here is reported in every run rather than quietly omitted.
#   * Exit code is the number of FAILED assertions. Codes >= 200 are harness aborts.
#
# Machine-readable: every assertion emits one line
#   RESULT <PASS|FAIL|SKIP> <id> <text>
# and the run ends with
#   SUMMARY pass=<n> fail=<n> skip=<n> chassis=<...> os=<...> arch=<...>

set -u -o pipefail

APP=""
MIN_OS="12.0"
WATCHDOG_LABEL="ai.flymy.lidwing.watchdog"
PASS=0; FAIL=0; SKIP=0

usage() { echo "usage: $0 --app /path/to/Lidwing.app"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 200 ;;
  esac
done

ok()   { PASS=$((PASS + 1)); echo "RESULT PASS $1 ${2:-}"; }
bad()  { FAIL=$((FAIL + 1)); echo "RESULT FAIL $1 ${2:-}"; }
skip() { SKIP=$((SKIP + 1)); echo "RESULT SKIP $1 ${2:-}"; }
note() { echo "NOTE  $*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "FATAL: this measures a Mac" >&2
  exit 200
fi

# ---------------------------------------------------------------- fingerprint

OS_VER="$(sw_vers -productVersion 2>/dev/null)"
OS_BUILD="$(sw_vers -buildVersion 2>/dev/null)"
ARCH="$(uname -m)"
MODEL="$(sysctl -n hw.model 2>/dev/null)"
TRANSLATED="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"

has_clamshell() {
  ioreg -r -c IOPMrootDomain -d 1 2>/dev/null | grep -q '"AppleClamshellState"'
}

chassis() {
  case "$MODEL" in VirtualMac*) echo vm; return ;; esac
  if has_clamshell; then echo portable; return; fi
  [ -n "$MODEL" ] && { echo desktop; return; }
  echo unknown
}
CHASSIS="$(chassis)"

echo "=== lidwing-smoke.sh ==="
echo "HOSTFP os=$OS_VER build=$OS_BUILD arch=$ARCH model=$MODEL translated=$TRANSLATED chassis=$CHASSIS"

# An x86_64 shell under Rosetta invalidates every architecture conclusion below it.
if [ "$TRANSLATED" = "1" ]; then
  bad arch.not-translated "running under Rosetta 2; re-run natively"
else
  ok arch.not-translated "native execution"
fi

vercmp_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
if vercmp_ge "$OS_VER" "$MIN_OS"; then
  ok os.floor "$OS_VER >= $MIN_OS"
else
  bad os.floor "$OS_VER < $MIN_OS - Lidwing must refuse to run here"
fi

# ---------------------------------------------------------------- canaries
#
# These are the facts the whole product rests on. If one of them ever changes in a macOS point
# release, this is what tells us before a user does.

# The user client must be openable by an ordinary user. This is selector 12's whole story:
# `RootDomainUserClient` sets `kIOUserClientEntitlementsKey = false` and the selector-12
# dispatch entry has no privilege check.
if [ -x /tmp/wingprobe ]; then
  PROBE_OUT="$(/tmp/wingprobe verify 2>&1)"
  if printf '%s' "$PROBE_OUT" | grep -q 'user client openable : yes'; then
    ok canary.userclient-openable "IOPMrootDomain user client opens as uid $(id -u)"
  else
    bad canary.userclient-openable "cannot open the user client - the mechanism is gone on $OS_VER"
  fi
else
  skip canary.userclient-openable "build it first: swiftc -O -o /tmp/wingprobe spike/wingprobe.swift"
fi

# `AppleClamshellCausesSleep` is the only acceptance signal an arm has. Without it the app
# cannot verify its own state and refuses to claim it is protecting anything.
if ioreg -r -c IOPMrootDomain -d 1 2>/dev/null | grep -q '"AppleClamshellCausesSleep"'; then
  ok canary.clamshell-causes-sleep-key "AppleClamshellCausesSleep is readable"
else
  skip canary.clamshell-causes-sleep-key "key absent - stale until the first clamshell event"
fi

# We never write this. It is read so that launch reconciliation can tell the user when
# something else has.
if ioreg -r -c IOPMrootDomain -d 1 2>/dev/null | grep -q '"SleepDisabled"'; then
  SD="$(ioreg -r -c IOPMrootDomain -d 1 | awk -F'= ' '/"SleepDisabled"/{gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
  note "SleepDisabled = $SD (Lidwing never writes this)"
fi

if has_clamshell; then
  ok chassis.clamshell "AppleClamshellState present (portable)"
else
  skip chassis.clamshell "lidless hardware - every lid assertion below is UNPROVEN here"
fi

# ---------------------------------------------------------------- bundle integrity

if [ -z "$APP" ]; then
  note "no --app given; skipping the bundle suite"
  for assertion in a.universal a.minver a.codesign a.hardened a.no-network-entitlement \
                   a.no-usage-descriptions a.no-privileged-helper a.watchdog-agent \
                   a.notify-helper a.single-instance; do
    skip "$assertion" "no --app"
  done
elif [ ! -d "$APP" ]; then
  echo "FATAL: $APP not found" >&2
  exit 201
else
  PLIST="$APP/Contents/Info.plist"
  EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null)"
  BIN="$APP/Contents/MacOS/$EXEC_NAME"

  ARCHS="$(lipo -archs "$BIN" 2>/dev/null)"
  case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ok a.universal "archs: $ARCHS" ;;
    *) bad a.universal "expected universal, got: '${ARCHS:-none}'" ;;
  esac

  MINV="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null)"
  if [ "$MINV" = "$MIN_OS" ]; then
    ok a.minver "LSMinimumSystemVersion=$MINV"
  else
    bad a.minver "LSMinimumSystemVersion='${MINV:-absent}' expected $MIN_OS"
  fi

  if codesign --verify --strict --deep "$APP" >/dev/null 2>&1; then
    ok a.codesign "signature valid (strict, deep)"
  else
    bad a.codesign "codesign --verify --strict --deep failed"
  fi

  if codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    ok a.hardened "hardened runtime enabled"
  else
    bad a.hardened "hardened runtime absent (notarization would be rejected)"
  fi

  # The structural proof of the no-telemetry claim, checkable offline on the downloaded
  # binary, before it is ever run.
  ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
  if printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.network.client'; then
    bad a.no-network-entitlement "the app claims a network entitlement - the no-telemetry claim is false"
  else
    ok a.no-network-entitlement "no network-client entitlement"
  fi

  if plutil -p "$PLIST" 2>/dev/null | grep -qi UsageDescription; then
    bad a.no-usage-descriptions "Info.plist declares a permission Lidwing does not need"
  else
    ok a.no-usage-descriptions "zero *UsageDescription keys"
  fi

  # Tier 1 installs no privileged helper at all. A LaunchDaemon inside the bundle would mean a
  # root daemon came back without this file being updated.
  if [ -d "$APP/Contents/Library/LaunchDaemons" ]; then
    bad a.no-privileged-helper "the bundle contains a LaunchDaemon - Tier 1 has no root component"
  else
    ok a.no-privileged-helper "no LaunchDaemon in the bundle"
  fi

  if [ -f "$APP/Contents/Library/LaunchAgents/$WATCHDOG_LABEL.plist" ]; then
    ok a.watchdog-agent "the watchdog agent plist is present"
  else
    bad a.watchdog-agent "no watchdog plist - the dead-man would never start"
  fi

  if [ -x "$APP/Contents/Resources/lidwingd" ]; then
    ok a.notify-helper "lidwingd is present and executable"
  else
    bad a.notify-helper "lidwingd missing from the bundle"
  fi

  if /usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$PLIST" 2>/dev/null \
     | grep -qx true; then
    ok a.single-instance "a second instance is prohibited"
  else
    bad a.single-instance "two instances could race to set and clear the same bit"
  fi
fi

# ---------------------------------------------------------------- no legacy artefacts

if [ -e "/Library/LaunchDaemons/ai.flymy.lidwing.helper.plist" ] \
   || [ -e "/Library/PrivilegedHelperTools/ai.flymy.lidwing.helper" ] \
   || [ -d "/Library/Application Support/ai.flymy.lidwing" ]; then
  bad system.no-root-residue "privileged artefacts on disk - Lidwing installs none"
else
  ok system.no-root-residue "nothing of Lidwing's in any system directory"
fi

# ---------------------------------------------------------------- the uncoverable cell
#
# Printed in every run, on every machine, so the gap is visible rather than implied.

if has_clamshell; then
  skip lid.endurance "needs a human to close the lid - see docs/M0-spike.md"
else
  skip lid.endurance "lidless hardware: this cell can never be covered here at any price"
fi

echo "SUMMARY pass=$PASS fail=$FAIL skip=$SKIP chassis=$CHASSIS os=$OS_VER arch=$ARCH"
if [ "$SKIP" -gt 0 ]; then
  echo "NOTE  $SKIP assertion(s) were SKIPPED. A skip is not a pass."
fi
exit "$FAIL"
