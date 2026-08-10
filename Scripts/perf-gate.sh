#!/bin/bash
# Measures the numbers this product publishes about itself.
#
# An app that promises to save your battery must not burn it, and "it's lightweight" is a
# claim while "0.0% CPU, 2 idle wake-ups per second" is a proof. These are gates, not goals:
# the script exits non-zero when a budget is exceeded, and the numbers it prints are the ones
# that go in the README.
#
#   ./Scripts/perf-gate.sh                 # 60-second sample, app must already be running
#   ./Scripts/perf-gate.sh --soak 240      # longer sample, for memory and descriptor growth
#
# Nothing here needs root except the optional energy sample, which is skipped rather than
# prompting.

set -u -o pipefail

SAMPLE_SECONDS=60
SOAK=0
FAIL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --soak) SAMPLE_SECONDS="${2:-240}"; SOAK=1; shift 2 ;;
    --seconds) SAMPLE_SECONDS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "These are measurements of a running Mac app. Run it there." >&2
  exit 200
fi

# Budgets, from the craft specification. Changing one of these is a product decision, not a
# convenience.
readonly MAX_IDLE_CPU=0.1        # per cent, averaged with the menu closed
readonly MAX_IDLE_WAKEUPS=2      # per second
readonly MAX_APP_RSS_MB=40
readonly MAX_WATCHDOG_RSS_MB=8
readonly MIN_TIMER_PERIOD=5      # seconds; nothing may repeat faster while idle

APP_PID="$(pgrep -x Lidwing | head -1 || true)"
WD_PID="$(pgrep -x lidwingd | head -1 || true)"

if [ -z "$APP_PID" ]; then
  echo "FATAL: Lidwing is not running. Start it, leave the menu closed, and re-run." >&2
  exit 201
fi
echo "app pid $APP_PID, watchdog pid ${WD_PID:-none}"
echo "sampling for ${SAMPLE_SECONDS}s with the menu closed"

check() {
  local name="$1" value="$2" budget="$3" unit="$4"
  if awk -v v="$value" -v b="$budget" 'BEGIN{exit !(v>b)}'; then
    echo "FAIL  $name = $value$unit  (budget $budget$unit)"
    FAIL=$((FAIL + 1))
  else
    echo "ok    $name = $value$unit  (budget $budget$unit)"
  fi
}

# ------------------------------------------------------------------ CPU, wake-ups, memory

TOPLOG="$(mktemp)"
trap 'rm -f "$TOPLOG"' EXIT
top -l "$SAMPLE_SECONDS" -s 1 -stats pid,cpu,idlew,mem -pid "$APP_PID" > "$TOPLOG" 2>/dev/null

# `top`'s first sample is a since-boot average and is meaningless here; skip it.
CPU="$(awk -v pid="$APP_PID" '$1==pid {n++; if (n>1) {s+=$2; c++}} END{printf "%.2f", (c?s/c:0)}' "$TOPLOG")"
IDLEW="$(awk -v pid="$APP_PID" '$1==pid {n++; if (n>1) {s+=$3; c++}} END{printf "%.1f", (c?s/c:0)}' "$TOPLOG")"
SAMPLES="$(awk -v pid="$APP_PID" '$1==pid {n++} END{print n+0}' "$TOPLOG")"

if [ "$SAMPLES" -lt 5 ]; then
  echo "FAIL  collected only $SAMPLES samples - the measurement did not happen"
  FAIL=$((FAIL + 1))
else
  echo "      $SAMPLES samples collected"
  check "idle CPU" "$CPU" "$MAX_IDLE_CPU" "%"
  check "idle wake-ups" "$IDLEW" "$MAX_IDLE_WAKEUPS" "/s"
fi

rss_mb() {
  ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%.1f", $1/1024}'
}
check "app resident memory" "$(rss_mb "$APP_PID")" "$MAX_APP_RSS_MB" " MB"
if [ -n "$WD_PID" ]; then
  check "watchdog resident memory" "$(rss_mb "$WD_PID")" "$MAX_WATCHDOG_RSS_MB" " MB"
else
  echo "SKIP  watchdog resident memory - the watchdog is not running"
fi

# ------------------------------------------------------------------ growth over the sample
#
# A leak shows up as monotonic growth, not as a single large number. Only meaningful over a
# long sample, so it is reported rather than failed on a 60-second run.

if [ "$SOAK" -eq 1 ]; then
  FD_START="$(lsof -p "$APP_PID" 2>/dev/null | wc -l | tr -d ' ')"
  RSS_START="$(rss_mb "$APP_PID")"
  sleep "$SAMPLE_SECONDS"
  FD_END="$(lsof -p "$APP_PID" 2>/dev/null | wc -l | tr -d ' ')"
  RSS_END="$(rss_mb "$APP_PID")"
  echo "      file descriptors: $FD_START -> $FD_END"
  echo "      resident memory:  $RSS_START MB -> $RSS_END MB"
  if [ "$FD_END" -gt $((FD_START + 5)) ]; then
    echo "FAIL  file descriptors grew by $((FD_END - FD_START)) over ${SAMPLE_SECONDS}s"
    FAIL=$((FAIL + 1))
  fi
fi

# ------------------------------------------------------------------ assertion hygiene
#
# When Lidwing is off, `pmset -g assertions` must show nothing from Lidwing at all. This is the
# check a suspicious user runs, and it has to pass for them too.

ASSERTIONS="$(pmset -g assertions 2>/dev/null)"
if printf '%s' "$ASSERTIONS" | grep -qi lidwing; then
  echo "NOTE  Lidwing holds an assertion right now:"
  printf '%s\n' "$ASSERTIONS" | grep -i lidwing | sed 's/^/      /'
  echo "      (expected while it is ON; run again with it OFF to check hygiene)"
else
  echo "ok    no Lidwing assertion held"
fi

# ------------------------------------------------------------------ ground truth

CAUSES_SLEEP="$(ioreg -r -c IOPMrootDomain -d 1 2>/dev/null \
  | awk -F'= ' '/"AppleClamshellCausesSleep"/ {gsub(/[^A-Za-z]/,"",$2); print $2; exit}')"
echo "      AppleClamshellCausesSleep = ${CAUSES_SLEEP:-absent}"

# ------------------------------------------------------------------ timers
#
# `timerfires` is not on every system, so its absence is a SKIP and never a silent pass.

if command -v timerfires >/dev/null 2>&1; then
  TIMERLOG="$(mktemp)"
  timerfires -p "$APP_PID" > "$TIMERLOG" 2>/dev/null &
  TIMER_PID=$!
  sleep 30
  kill "$TIMER_PID" 2>/dev/null
  FIRES="$(grep -c . "$TIMERLOG" || echo 0)"
  echo "      timer fires in 30s: $FIRES"
  # 30 s at the fastest permitted period is 6 fires from the reconcile timer plus 3 from the
  # re-assert timer while armed. Anything far above that is a timer with no leeway.
  if [ "$FIRES" -gt $((30 / MIN_TIMER_PERIOD * 4)) ]; then
    echo "FAIL  too many timer fires: something is repeating faster than ${MIN_TIMER_PERIOD}s"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$TIMERLOG"
else
  echo "SKIP  timer period check - timerfires is not installed (this is a SKIP, not a pass)"
fi

echo "SUMMARY fail=$FAIL cpu=$CPU% idlew=$IDLEW/s"
exit "$FAIL"
