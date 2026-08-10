#!/bin/bash
# m0-run.sh — the M0 lid experiment, start to finish, on a real MacBook.
#
# This is the one measurement the whole product rests on. Everything else in this repository
# is derived from kernel source; nobody has ever armed the mechanism and closed a lid.
#
#   ./spike/m0-run.sh --short              2 minutes, mechanism A, go/no-go
#   ./spike/m0-run.sh --soak               8 hours,   mechanism A, the real evidence
#   ./spike/m0-run.sh --soak --mechanism b 8 hours,   mechanism B (needs sudo; see the warning)
#
# Safety contract:
#   * Mechanism A needs no root and writes nothing that survives a reboot.
#   * Mechanism B writes `pmset -a disablesleep 1`, which is root-owned and DOES survive a
#     reboot. The script restores it in an EXIT/INT/TERM trap and verifies the restore. If you
#     ever doubt the state of the machine: `sudo pmset -a disablesleep 0`.
#   * Every run ends with the machine as it was found, and prints the proof.
#
# Output: a directory under docs/m0/ containing the raw logs, the before/after snapshots and a
# verdict file. Commit the whole directory; the raw logs are the evidence, the verdict is not.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MECHANISM=a
DURATION=0
LABEL=""

usage() {
  sed -n '2,20p' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --short)      DURATION=120;   LABEL=short; shift ;;
    --soak)       DURATION=28800; LABEL=soak;  shift ;;
    --seconds)    DURATION="${2:?}"; LABEL="custom${2}"; shift 2 ;;
    --mechanism)  MECHANISM="${2:?}"; shift 2 ;;
    -h|--help)    usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ "$DURATION" -gt 0 ] || usage
case "$MECHANISM" in a|b) ;; *) echo "mechanism must be a or b" >&2; exit 2 ;; esac

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script measures a Mac. Run it on the MacBook." >&2
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/docs/m0/$LABEL-mech$MECHANISM-$STAMP"
mkdir -p "$OUT"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/run.log"; }

# ---------------------------------------------------------------- preconditions

say "=== M0, mechanism $MECHANISM, ${DURATION}s ==="
say "output: $OUT"

DISPLAYS="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true)"
say "displays reporting a resolution: $DISPLAYS"
if [ "${DISPLAYS:-0}" -gt 1 ]; then
  say "REFUSING: an external display appears to be attached."
  say "  macOS already keeps a lid-closed Mac awake with an external display on AC, so a pass"
  say "  here would prove nothing about the mechanism. Disconnect everything and re-run."
  exit 3
fi

if ! ioreg -r -c IOPMrootDomain -d 1 | grep -q '"AppleClamshellState"'; then
  say "REFUSING: no AppleClamshellState key. This machine has no lid, so it cannot answer the question."
  exit 3
fi

BATT_PCT="$(pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%' || echo 0)"
ON_AC="$(pmset -g batt | grep -c 'AC Power' || true)"
say "power: $([ "${ON_AC:-0}" -gt 0 ] && echo AC || echo battery), battery ${BATT_PCT}%"
if [ "$LABEL" = "soak" ] && [ "${ON_AC:-0}" -eq 0 ] && [ "${BATT_PCT:-0}" -lt 80 ]; then
  say "WARNING: an 8-hour battery soak starting at ${BATT_PCT}% will end on an empty battery."
  say "  That is a legitimate run (it measures the safety net too) but say so in the verdict."
fi

# ---------------------------------------------------------------- snapshots

snapshot() {
  local when="$1"
  pmset -g custom            > "$OUT/pmset-custom.$when.txt"  2>&1 || true
  pmset -g stats             > "$OUT/pmset-stats.$when.txt"   2>&1 || true
  pmset -g assertions        > "$OUT/pmset-assertions.$when.txt" 2>&1 || true
  ioreg -r -c IOPMrootDomain -d 1 > "$OUT/ioreg.$when.txt"    2>&1 || true
  sw_vers                    > "$OUT/sw_vers.$when.txt"       2>&1 || true
  sysctl -n hw.model kern.bootsessionuuid > "$OUT/machine.$when.txt" 2>&1 || true
}

sleep_count() { awk '/Sleep Count/{print $NF}' "$1" 2>/dev/null | head -1; }
dark_count()  { awk '/Dark Wake Count/{print $NF}' "$1" 2>/dev/null | head -1; }
sleep_disabled() {
  ioreg -r -c IOPMrootDomain -d 1 2>/dev/null \
    | awk -F'= ' '/"SleepDisabled"/ {gsub(/[^A-Za-z]/,"",$2); print $2; exit}'
}

snapshot before
BEFORE_SLEEP="$(sleep_count "$OUT/pmset-stats.before.txt")"
BEFORE_DARK="$(dark_count  "$OUT/pmset-stats.before.txt")"
say "before: Sleep Count=${BEFORE_SLEEP:-?} Dark Wake Count=${BEFORE_DARK:-?} SleepDisabled=$(sleep_disabled)"

if [ "$(sleep_disabled)" = "Yes" ]; then
  say "REFUSING: SleepDisabled is already Yes. A dirty baseline produces a fake pass."
  say "  Clear it with: sudo pmset -a disablesleep 0"
  exit 3
fi

# ---------------------------------------------------------------- teardown, armed first

ARMED_B=0
PROBE_PID=""

teardown() {
  local status=$?
  set +e
  if [ "$ARMED_B" -eq 1 ]; then
    say "TRAP: restoring disablesleep"
    sudo -n pmset -a disablesleep 0 >/dev/null 2>&1 || sudo pmset -a disablesleep 0 || true
    ARMED_B=0
  fi
  if [ -n "$PROBE_PID" ] && kill -0 "$PROBE_PID" 2>/dev/null; then
    say "TRAP: stopping wingprobe (it disarms itself on SIGTERM)"
    kill -TERM "$PROBE_PID" 2>/dev/null || true
    sleep 2
  fi
  # Belt and braces: clear the clamshell bit whatever happened above.
  [ -x "$OUT/wingprobe" ] && "$OUT/wingprobe" disarm >/dev/null 2>&1
  say "TRAP: final SleepDisabled=$(sleep_disabled) AppleClamshellCausesSleep=$(ioreg -r -c IOPMrootDomain -d 1 | awk -F'= ' '/"AppleClamshellCausesSleep"/{gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
  exit "$status"
}
trap teardown EXIT INT TERM

# ---------------------------------------------------------------- heartbeat

HEARTBEAT="$OUT/heartbeat.log"
: > "$HEARTBEAT"
(
  while :; do
    printf '%s uptime=%s load=%s\n' "$(date -u +%FT%TZ)" \
      "$(uptime | sed 's/.*up //;s/,.*users.*//')" \
      "$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')" >> "$HEARTBEAT"
    sleep 60
  done
) &
HEARTBEAT_PID=$!

# ---------------------------------------------------------------- a real workload
#
# An idle Mac and a busy Mac can behave differently, and the product exists to protect a busy
# one. One saturated core for the duration.
(
  END=$(( $(date +%s) + DURATION + 60 ))
  while [ "$(date +%s)" -lt "$END" ]; do :; done
) &
LOAD_PID=$!

cleanup_children() {
  kill "$HEARTBEAT_PID" "$LOAD_PID" 2>/dev/null || true
}
trap 'cleanup_children; teardown' EXIT INT TERM

# ---------------------------------------------------------------- arm

if [ "$MECHANISM" = a ]; then
  say "building wingprobe"
  swiftc -O -o "$OUT/wingprobe" "$HERE/wingprobe.swift" 2>&1 | tee -a "$OUT/build.log"
  "$OUT/wingprobe" verify | tee "$OUT/verify.txt"

  say "arming mechanism A (clamshell mask + idle assertion, no root)"
  "$OUT/wingprobe" arm "$DURATION" --log "$OUT/probe-heartbeat.log" > "$OUT/probe.log" 2>&1 &
  PROBE_PID=$!
else
  say "arming mechanism B (pmset -a disablesleep 1). THIS IS ROOT AND IT SURVIVES A REBOOT."
  sudo pmset -a disablesleep 1
  ARMED_B=1
  sleep 1
  if [ "$(sleep_disabled)" != "Yes" ]; then
    say "FAILED: SleepDisabled did not flip to Yes. Aborting."
    exit 3
  fi
  say "armed: SleepDisabled=Yes"
fi

sleep 3
say ""
say "  >>> CLOSE THE LID NOW. Leave it closed. <<<"
say "  The run ends by itself in ${DURATION}s and disarms whatever happens."
say ""

# ---------------------------------------------------------------- wait

if [ "$MECHANISM" = a ]; then
  set +e
  wait "$PROBE_PID"
  PROBE_STATUS=$?
  set -e
  PROBE_PID=""
  say "wingprobe exited with $PROBE_STATUS"
else
  END=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$END" ]; do sleep 30; done
  sudo pmset -a disablesleep 0
  ARMED_B=0
  sleep 1
  say "disarmed: SleepDisabled=$(sleep_disabled)"
  PROBE_STATUS=0
fi

cleanup_children

# ---------------------------------------------------------------- measure

snapshot after
AFTER_SLEEP="$(sleep_count "$OUT/pmset-stats.after.txt")"
AFTER_DARK="$(dark_count  "$OUT/pmset-stats.after.txt")"
pmset -g log > "$OUT/pmset-log.txt" 2>&1 || true

# The largest wall-clock gap between consecutive heartbeats. A sleep shows up as a gap; this
# is the measurement, and everything else in this script is scaffolding around it.
max_gap_of() {
  awk '
    BEGIN { prev = 0; max = 0 }
    /^#/ { next }
    NF == 0 { next }
    {
      cmd = "date -u -j -f %Y-%m-%dT%H:%M:%SZ " $1 " +%s 2>/dev/null"
      cmd | getline t
      close(cmd)
      if (t > 0) {
        if (prev > 0 && t - prev > max) max = t - prev
        prev = t
      }
    }
    END { print max + 0 }' "$1"
}

# Prefer wingprobe's own one-second log: on a two-minute run the sixty-second heartbeat has
# only two samples, and a gap measured from two samples is not a measurement.
if [ -s "$OUT/probe-heartbeat.log" ]; then
  MAX_GAP="$(max_gap_of "$OUT/probe-heartbeat.log")"
  GAP_SOURCE="wingprobe 1s heartbeat"
  GAP_BUDGET=5
else
  MAX_GAP="$(max_gap_of "$HEARTBEAT")"
  GAP_SOURCE="shell 60s heartbeat"
  GAP_BUDGET=90
fi

TICKS="$(grep -c . "$HEARTBEAT" || echo 0)"
EXPECTED_TICKS=$(( DURATION / 60 ))

SLEEP_DELTA="?"
DARK_DELTA="?"
if [ -n "${BEFORE_SLEEP:-}" ] && [ -n "${AFTER_SLEEP:-}" ]; then
  SLEEP_DELTA=$(( AFTER_SLEEP - BEFORE_SLEEP ))
fi
if [ -n "${BEFORE_DARK:-}" ] && [ -n "${AFTER_DARK:-}" ]; then
  DARK_DELTA=$(( AFTER_DARK - BEFORE_DARK ))
fi

# ---------------------------------------------------------------- verdict
#
# PASS needs all of: the 60 s heartbeat never gapped, the kernel's own Sleep Count did not
# move, and Dark Wake Count did not move. A short sleep that hides between two ticks is still
# a sleep, and both known holes in mechanism A only open after the machine has slept once.

VERDICT=PASS
REASONS=""
if [ "${MAX_GAP:-999}" -gt "$GAP_BUDGET" ]; then
  VERDICT=FAIL; REASONS="$REASONS heartbeat gapped ${MAX_GAP}s (budget ${GAP_BUDGET}s);"
fi
# wingprobe judges itself against the same three signals. If it disagrees with the arithmetic
# here, that disagreement is itself a reason not to trust the run.
if [ "$MECHANISM" = a ] && [ "${PROBE_STATUS:-0}" -ne 0 ]; then
  VERDICT=FAIL; REASONS="$REASONS wingprobe reported failure (exit $PROBE_STATUS);"
fi
if [ "$SLEEP_DELTA" != "0" ]; then
  VERDICT=FAIL; REASONS="$REASONS Sleep Count delta=$SLEEP_DELTA;"
fi
if [ "$DARK_DELTA" != "0" ]; then
  VERDICT=FAIL; REASONS="$REASONS Dark Wake Count delta=$DARK_DELTA;"
fi
if [ "$TICKS" -lt $(( EXPECTED_TICKS - 1 )) ]; then
  VERDICT=FAIL; REASONS="$REASONS only $TICKS of ~$EXPECTED_TICKS heartbeats;"
fi
[ "$VERDICT" = PASS ] && REASONS=" none"

{
  echo "verdict:        $VERDICT"
  echo "mechanism:      $MECHANISM"
  echo "duration_s:     $DURATION"
  echo "max_gap_s:      ${MAX_GAP:-?}   (from $GAP_SOURCE, budget ${GAP_BUDGET}s)"
  echo "heartbeats:     $TICKS of ~$EXPECTED_TICKS expected"
  echo "sleep_delta:    $SLEEP_DELTA"
  echo "darkwake_delta: $DARK_DELTA"
  echo "probe_exit:     $PROBE_STATUS"
  echo "failed_checks: $REASONS"
  echo "os:             $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "model:          $(sysctl -n hw.model)"
  echo "arch:           $(uname -m)"
  echo "final_sleepdisabled: $(sleep_disabled)"
} | tee "$OUT/verdict.txt"

say "=== $VERDICT ==="
if [ "$VERDICT" = FAIL ]; then
  say ""
  say "Before concluding the mechanism does not work, check these in the output:"
  say "  * verify.txt        - did the user client open at all?"
  say "  * probe.log         - did AppleClamshellCausesSleep flip to No within 2s?"
  say "  * pmset-log.txt     - what reason does the kernel give for the sleep?"
  say "  * ioreg.before/after- was the machine stock before the run started?"
  say "A run where the bit never took effect is a different result from one where it took"
  say "effect and the Mac slept anyway, and the second is the one that ends the product."
fi
say "Send the whole directory: $OUT"
[ "$VERDICT" = PASS ] && exit 0 || exit 1
