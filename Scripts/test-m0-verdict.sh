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

# ---------------------------------------------------------------- the teardown
#
# Denis interrupted a real run at 36 s of a 120 s window and the harness could not say whether
# the machine had been left stock. `AppleClamshellCausesSleep` read `No` afterwards, which meant
# nothing either way - the key is stale between kernel events. An interrupted run is the normal
# case, not the exceptional one, so what it leaves behind has to be provable.

TD_START="$(grep -n '^teardown() {' spike/m0-run.sh | head -1 | cut -d: -f1)"
TD_END="$(grep -n '^}$' spike/m0-run.sh | awk -F: -v s="$TD_START" '$1 > s {print $1; exit}')"
if [ -z "$TD_START" ] || [ -z "$TD_END" ]; then
  echo "  FAIL  could not extract teardown from spike/m0-run.sh - this proved nothing"
  FAIL=$((FAIL + 1))
else
  sed -n "${TD_START},${TD_END}p" spike/m0-run.sh > "$WORK/teardown.sh"

  # `disarm_rc` decides what the fake wingprobe returns, so both branches are exercised.
  teardown_says() {
    local exit_status="$1" disarm_rc="$2" build_probe="$3"
    local out="$WORK/td"; rm -rf "$out"; mkdir -p "$out"
    if [ "$build_probe" = yes ]; then
      printf '#!/bin/sh\necho "cleared the mask"\nexit %s\n' "$disarm_rc" > "$out/wingprobe"
      chmod +x "$out/wingprobe"
    fi
    OUT="$out" ARMED_B=0 PROBE_PID="" \
      bash -c "set -uo pipefail
               say() { :; }
               sleep_disabled() { echo No; }
               source '$WORK/teardown.sh'
               ( teardown $exit_status ) 2>&1" 2>&1
  }

  td_expect() {
    local name="$1" want="$2"; shift 2
    local got; got="$(teardown_says "$@")"
    if printf '%s' "$got" | grep -q "$want"; then
      PASS=$((PASS + 1))
      printf '  ok    %-42s %s\n' "$name" "$want"
    else
      FAIL=$((FAIL + 1))
      printf '  FAIL  %-42s wanted "%s" in: %s\n' "$name" "$want" "$(printf '%s' "$got" | tr '\n' ' ')"
    fi
  }

  echo "== M0 teardown"
  td_expect "an interrupted run says so"        "interrupted:     yes" 130 0 yes
  td_expect "a clean run says so"               "interrupted:     no"  0   0 yes
  td_expect "a successful force-clear proves it" "PROVABLY STOCK"      130 0 yes
  td_expect "a failed force-clear admits it"     "COULD NOT PROVE STOCK" 130 3 yes
  td_expect "a failed force-clear names the fix" "reboot"              130 3 yes
  td_expect "nothing armed, nothing claimed"     "NOTHING WAS EVER ARMED" 130 0 no
  td_expect "the stale key is labelled as such"  "NOT proof of anything" 0 0 yes
fi

echo "SUMMARY pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -ge 23 ] || { echo "FAIL  only $PASS cases ran"; exit 1; }
