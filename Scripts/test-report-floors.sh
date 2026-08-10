#!/bin/bash
# Tests the "did enough of this actually run" floors in the Mac-only scripts.
#
# `fault-injection.sh` and `lidwing-smoke.sh` cannot run here - they refuse anything that is not
# Darwin, which is correct - and they do not run in CI either, because they need a real Mac with
# the app installed. So the one piece of logic in them that decides whether a run counts would
# otherwise ship having never executed anywhere.
#
# The failure it guards against is specific: a script that stops after two of its six scenarios
# prints `SUMMARY pass=2 fail=0` and exits 0. Read quickly, that is a pass. `invariants.sh` had
# exactly this hole, and these two had it after it was fixed there.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSES=0
FAILURES=0

# Pulls the floor out of a script verbatim, so this tests the shipped logic and not a copy.
extract_floor() {
  local src="$1" out="$2"
  local start end
  start="$(grep -n '^RAN=\$(( PASS + FAIL' "$src" | head -1 | cut -d: -f1)"
  end="$(grep -n '^fi$' "$src" | awk -F: -v s="$start" '$1 > s {print $1; exit}')"
  if [ -z "$start" ] || [ -z "$end" ]; then
    echo "  FAIL  could not find the floor in $src - this test proved nothing"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  sed -n "${start},${end}p" "$src" > "$out"
  grep -q "INCOMPLETE" "$out"
}

# `check <script> <expected-exit> <name> <PASS> <FAIL> <SKIP> <EXPECTED_ASSERTIONS>`
check() {
  local block="$1" want="$2" name="$3" p="$4" f="$5" k="$6" e="$7"
  PASS="$p" FAIL="$f" SKIP="$k" EXPECTED_ASSERTIONS="$e" \
    bash -c "set -u; source '$block'; exit 0" > "$WORK/out.txt" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    PASSES=$((PASSES + 1))
    printf '  ok    %-46s exit %s\n' "$name" "$got"
  else
    FAILURES=$((FAILURES + 1))
    printf '  FAIL  %-46s wanted exit %s, got %s: %s\n' \
      "$name" "$want" "$got" "$(tr '\n' ' ' < "$WORK/out.txt")"
  fi
}

echo "== report floors"

if extract_floor Scripts/fault-injection.sh "$WORK/fault.sh"; then
  check "$WORK/fault.sh" 0 "fault injection: a complete run"        6 0 0 6
  check "$WORK/fault.sh" 0 "fault injection: a complete run, failing" 4 2 0 6
  check "$WORK/fault.sh" 3 "fault injection: stopped after two"      2 0 0 6
  check "$WORK/fault.sh" 3 "fault injection: nothing ran at all"     0 0 0 6
fi

if extract_floor Scripts/lidwing-smoke.sh "$WORK/smoke.sh"; then
  # The observed real run on the owner's Mac was pass=6 fail=0 skip=18, so skips count towards
  # a complete run: on this script most assertions are legitimately skipped, and requiring
  # passes would make the floor unreachable.
  check "$WORK/smoke.sh" 0 "smoke: the observed real run (6/0/18)"   6 0 18 20
  check "$WORK/smoke.sh" 3 "smoke: stopped a third of the way in"    2 0 4 20
  check "$WORK/smoke.sh" 3 "smoke: nothing ran at all"               0 0 0 20
  check "$WORK/smoke.sh" 0 "smoke: exactly at the floor"             1 1 18 20
fi

echo "SUMMARY pass=$PASSES fail=$FAILURES"
[ "$FAILURES" -eq 0 ] || exit 1
[ "$PASSES" -ge 8 ] || { echo "FAIL  only $PASSES cases ran"; exit 1; }
