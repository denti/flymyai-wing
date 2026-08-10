#!/bin/bash
# Fault injection against the real binaries, on a real Mac.
#
# The unit tests cover the *logic* of dying mid-transition. This covers the *processes*: what
# actually happens to the machine when the app is SIGKILLed while armed, when the watchdog is
# killed, when the ledger is corrupt, and when both die at once.
#
# The single most valuable assertion in this file is F1. It is what stands between a user and
# a laptop that cannot sleep in a backpack.
#
#   ./Scripts/fault-injection.sh /Applications/Lidwing.app
#
# Every scenario restores the machine before the next one starts, and an EXIT trap restores it
# if the script is interrupted. Exit code is the number of failed scenarios.

set -u -o pipefail

APP="${1:-/Applications/Lidwing.app}"
BINARY="$APP/Contents/MacOS/Lidwing"
WATCHDOG="$APP/Contents/Resources/lidwingd"
SUPPORT="$HOME/Library/Application Support/Lidwing"
PASS=0
FAIL=0

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This exercises real processes on a real Mac. Run it there." >&2
  exit 200
fi
if [ ! -x "$BINARY" ]; then
  echo "FATAL: $BINARY not found or not executable" >&2
  exit 201
fi

ok()   { PASS=$((PASS + 1)); echo "RESULT PASS $1 ${2:-}"; }
bad()  { FAIL=$((FAIL + 1)); echo "RESULT FAIL $1 ${2:-}"; }
note() { echo "NOTE  $*"; }

# The authoritative read. `pmset -g custom` does not carry this key at all.
causes_sleep() {
  ioreg -r -c IOPMrootDomain -d 1 2>/dev/null \
    | awk -F'= ' '/"AppleClamshellCausesSleep"/ {gsub(/[^A-Za-z]/,"",$2); print $2; exit}'
}

# Waits for the machine to agree, rather than sleeping a fixed amount and hoping.
wait_for_causes_sleep() {
  local want="$1" limit="${2:-30}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    [ "$(causes_sleep)" = "$want" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

kill_everything() {
  pkill -x Lidwing 2>/dev/null
  pkill -x lidwingd 2>/dev/null
  launchctl bootout "gui/$(id -u)/ai.flymy.lidwing.watchdog" 2>/dev/null
  sleep 1
}

restore() {
  note "TRAP: restoring"
  kill_everything
  # Belt and braces. If everything above failed, this clears the bit directly.
  if [ -x /tmp/wingprobe ]; then /tmp/wingprobe disarm >/dev/null 2>&1; fi
}
trap restore EXIT INT TERM

# A direct way to clear the bit if every process is gone. Built once, up front.
if [ ! -x /tmp/wingprobe ] && [ -f spike/wingprobe.swift ]; then
  swiftc -O -o /tmp/wingprobe spike/wingprobe.swift 2>/dev/null
fi

echo "=== fault injection against $APP"
kill_everything

BASELINE="$(causes_sleep)"
note "baseline AppleClamshellCausesSleep=$BASELINE"
if [ "$BASELINE" != "Yes" ]; then
  echo "FATAL: the machine does not start in a stock state (got '$BASELINE')." >&2
  echo "       A dirty baseline produces a fake pass. Restart, or run: /tmp/wingprobe disarm" >&2
  exit 202
fi

# ----------------------------------------------------------------- F1: SIGKILL while armed

note "F1: SIGKILL the app while armed"
open -a "$APP"
sleep 3
# Arming is a user action, so drive it through the URL the menu item uses. Until that ships,
# this scenario needs the tester to click the menu item once when prompted.
echo ""
echo "  >>> Turn Lidwing ON from the menu now, then press Return. <<<"
read -r _
if ! wait_for_causes_sleep No 10; then
  bad f1.armed "the app did not arm; nothing to inject a fault into"
else
  APP_PID="$(pgrep -x Lidwing | head -1)"
  note "app pid $APP_PID; sending SIGKILL"
  kill -9 "$APP_PID" 2>/dev/null
  if wait_for_causes_sleep Yes 30; then
    ok f1.crash-safe "the watchdog restored lid-close sleep after SIGKILL"
  else
    bad f1.crash-safe "SIGKILLED WHILE ARMED AND THE MACHINE STAYED AWAKE - safety critical"
  fi
fi
kill_everything

# ----------------------------------------------------------------- F2: the recovery record

note "F2: the user is told what happened"
if [ -f "$SUPPORT/recovered.json" ]; then
  ok f2.recovery-record "recovered.json written: $(cat "$SUPPORT/recovered.json")"
else
  bad f2.recovery-record "no recovery record; the user would never learn why their Mac slept"
fi

# ----------------------------------------------------------------- F3: corrupt ledger

note "F3: a corrupt ledger must produce a repair prompt, never a silent clear"
mkdir -p "$SUPPORT"
printf '{not json' > "$SUPPORT/ledger.json"
open -a "$APP"
sleep 4
if pgrep -x Lidwing >/dev/null; then
  ok f3.survives-corrupt-ledger "the app launched and is running"
else
  bad f3.survives-corrupt-ledger "the app died on a corrupt ledger"
fi
if [ "$(causes_sleep)" = "Yes" ]; then
  ok f3.no-silent-change "a corrupt ledger changed nothing on the machine"
else
  bad f3.no-silent-change "the machine changed state because of a ledger file"
fi
kill_everything
rm -f "$SUPPORT/ledger.json"

# ----------------------------------------------------------------- F4: watchdog killed

note "F4: killing the watchdog while armed must make the app stand down"
open -a "$APP"
sleep 3
echo ""
echo "  >>> Turn Lidwing ON from the menu now, then press Return. <<<"
read -r _
if ! wait_for_causes_sleep No 10; then
  bad f4.armed "the app did not arm"
else
  WD_PID="$(pgrep -x lidwingd | head -1)"
  if [ -z "$WD_PID" ]; then
    bad f4.watchdog-running "no watchdog process while armed - invariant I2 is not being kept"
  else
    note "watchdog pid $WD_PID; sending SIGKILL"
    kill -9 "$WD_PID" 2>/dev/null
    # launchd KeepAlive should bring it straight back; either way the machine must not be
    # left armed with no dead-man.
    if wait_for_causes_sleep Yes 30; then
      ok f4.stands-down "the app released the machine when its dead-man died"
    elif pgrep -x lidwingd >/dev/null; then
      ok f4.watchdog-relaunched "launchd restarted the watchdog and protection continued"
    else
      bad f4.stands-down "armed with no watchdog and no recovery"
    fi
  fi
fi
kill_everything

# ----------------------------------------------------------------- F5: nothing left behind

note "F5: a clean quit leaves the machine stock"
if [ "$(causes_sleep)" = "Yes" ]; then
  ok f5.stock "AppleClamshellCausesSleep is back to Yes"
else
  bad f5.stock "the machine is still not sleeping on lid close"
fi

RESIDUE="$(find "$HOME/Library" -iname '*lidwing*' -maxdepth 3 2>/dev/null | grep -v 'Application Support/Lidwing$' | head -5)"
note "residue check: ${RESIDUE:-none beyond the support directory}"

echo "SUMMARY pass=$PASS fail=$FAIL"
exit "$FAIL"
