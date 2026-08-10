#!/bin/bash
# Tests the M0 verdict logic, without a Mac, a lid, or eight hours.
#
# `spike/m0-run.sh` produces the single result this whole product is built on. It runs exactly
# once or twice, on somebody else's machine, and by the time anyone reads its verdict the
# machine has been put away. So the arithmetic that turns measurements into PASS or FAIL is
# extracted here and run against synthetic inputs, including the ones nobody wants to stage on
# real hardware: a Mac that slept, a counter that could not be read, and a lid that was never
# closed at all.
#
# The last of those is why this file exists. Until this was written, the script printed
# "CLOSE THE LID NOW", measured for two minutes, and reported PASS whether or not anybody did.
# A lid left open produces a Mac that stays awake for the most ordinary reason there is, clean
# counters, and a confident PASS - and the architecture would have rested on an experiment in
# which the thing under test never happened.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 2; }

SRC="spike/m0-run.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

# Extract the verdict block verbatim, so this tests the shipped logic rather than a copy of it
# that can drift. If the markers ever move, that is a failure rather than a silent skip.
START="$(grep -n '^VERDICT=PASS' "$SRC" | head -1 | cut -d: -f1)"
END="$(grep -n '^\[ "\$VERDICT" = PASS \] && REASONS=" none"' "$SRC" | head -1 | cut -d: -f1)"
if [ -z "$START" ] || [ -z "$END" ] || [ "$END" -le "$START" ]; then
  echo "FAIL  could not find the verdict block in $SRC - this test proved nothing"
  exit 1
fi
sed -n "${START},${END}p" "$SRC" > "$WORK/block.sh"
LINES="$(grep -c . "$WORK/block.sh")"
if [ "$LINES" -lt 20 ]; then
  echo "FAIL  the extracted verdict block is only $LINES lines - it did not extract"
  exit 1
fi
echo "== M0 verdict logic ($LINES lines extracted from $SRC)"

# Every case starts from a flawless run and changes one thing.
verdict_with() {
  MAX_GAP=1 GAP_BUDGET=5 MECHANISM=a PROBE_STATUS=0 SLEEP_DELTA=0 DARK_DELTA=0 \
  TICKS=2 EXPECTED_TICKS=2 GAP_SAMPLES=120 LID_SAMPLES=24 LID_CLOSED=24 LID_CLOSED_PCT=100 \
    env "$@" bash -c "set -u; source '$WORK/block.sh'; printf '%s|%s' \"\$VERDICT\" \"\$REASONS\"" 2>&1
}

# `expect <PASS|FAIL> <name> [--because <substring>] [VAR=value ...]`
#
# The `--because` clause matters more than it looks. Several guards overlap - a run with no lid
# samples also has a closed-percentage of zero - so a test that only checks PASS/FAIL cannot
# tell which guard fired, and deleting one of them leaves the suite green. Asserting on the
# reason is what makes each case test its own guard. Found by a positive control that stayed
# green after the sample guard was disabled.
expect() {
  local want="$1" name="$2"; shift 2
  local because=""
  if [ "${1:-}" = "--because" ]; then because="$2"; shift 2; fi
  local got; got="$(verdict_with "$@")"
  local verdict="${got%%|*}" reason="${got#*|}"
  if [ "$verdict" != "$want" ]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %-42s wanted %s, got %s (%s)\n' "$name" "$want" "$verdict" "$reason"
    return
  fi
  if [ -n "$because" ] && [[ "$reason" != *"$because"* ]]; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %-42s right verdict, wrong guard: wanted "%s", got "%s"\n' \
      "$name" "$because" "$reason"
    return
  fi
  PASS=$((PASS + 1))
  printf '  ok    %-42s %s\n' "$name" "$([ "$want" = FAIL ] && echo "$reason" || echo "")"
}

# The one case that must pass. If this fails, every FAIL below is meaningless - they would all
# be failing for some unrelated reason.
expect PASS "a flawless run"

# The defect this file was written for.
expect FAIL "the lid was never closed"          --because "did not test a closed lid" LID_CLOSED=0 LID_CLOSED_PCT=0
expect FAIL "the lid was shut for half the run" --because "only 50%" LID_CLOSED=12 LID_CLOSED_PCT=50
expect FAIL "the lid was shut for 79%"          LID_CLOSED=19 LID_CLOSED_PCT=79
expect PASS "the lid was shut for 80%"          LID_CLOSED=20 LID_CLOSED_PCT=80
expect FAIL "the lid was never sampled"         --because "never sampled" LID_SAMPLES=0 LID_CLOSED=0 LID_CLOSED_PCT=0

# A maximum over no samples is not a small maximum.
expect FAIL "a gap of 0 from an empty log"      --because "not a measurement" GAP_SAMPLES=0 MAX_GAP=0
expect FAIL "a gap from a single sample"        --because "not a measurement" GAP_SAMPLES=1 MAX_GAP=0

# The signals that were already there, kept under test so a future edit cannot quietly drop one.
expect FAIL "the Mac slept once"                --because "Sleep Count delta=1" SLEEP_DELTA=1
expect FAIL "a dark wake happened"              --because "Dark Wake Count delta=1" DARK_DELTA=1
expect FAIL "the sleep counter was unreadable"  SLEEP_DELTA=?
expect FAIL "the dark-wake counter unreadable"  DARK_DELTA=?
expect FAIL "the heartbeat gapped"              --because "heartbeat gapped" MAX_GAP=90
expect FAIL "wingprobe itself failed"           --because "wingprobe reported failure" PROBE_STATUS=3
expect FAIL "too few heartbeats"                --because "heartbeats" TICKS=0
# Mechanism B does not run wingprobe, so its exit status must not be consulted there.
expect PASS "mechanism b ignores probe status"  MECHANISM=b PROBE_STATUS=3

echo "SUMMARY pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -ge 16 ] || { echo "FAIL  only $PASS cases ran"; exit 1; }
