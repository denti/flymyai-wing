#!/bin/bash
# Behavioural tests for `lidwing-notify`.
#
# This binary runs inside somebody else's tool, on their critical path, possibly hundreds of
# times a session. Its contract is about **timing and exit codes**, which no unit test of the
# surrounding Swift can check — so it is tested by running it.
#
# It is plain POSIX C, so this runs on Linux as well as macOS and is part of the ordinary
# pre-push gate rather than something that waits for a runner.
#
#   ./Scripts/test-notify-helper.sh
#
# Exit code is the number of failed assertions.

set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# A short path on purpose. `sun_path` in `sockaddr_un` is 104 bytes on macOS, and the socket
# lives at $HOME/Library/Application Support/Lidwing/notify.sock — 45 characters before the
# home directory even starts. macOS's `mktemp -d` returns something like
# /var/folders/xx/…/T/tmp.XXXXXXXX, which blows the limit, and the failure is silent
# truncation on one side and a refusal on the other: the helper declines to connect and the
# listener waits for a client that will never arrive.
WORK="/tmp/lw$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# Any of the three. `cc` is absent from the Swift container, which is where the Linux side of
# the gate runs.
CC="${CC:-}"
if [ -z "$CC" ]; then
  for candidate in cc clang gcc; do
    if command -v "$candidate" >/dev/null 2>&1; then CC="$candidate"; break; fi
  done
fi
if [ -z "$CC" ]; then
  echo "SKIP  no C compiler found (tried cc, clang, gcc). This is a SKIP, not a pass."
  exit 2
fi
echo "  note  compiler: $CC"

echo "== building lidwing-notify"
"$CC" -O2 -Wall -Wextra -Werror -o "$WORK/lidwing-notify" \
  "$ROOT/Sources/lidwing-notify/main.c" || {
    echo "  FAIL  it does not compile cleanly with -Wall -Wextra -Werror"
    exit 1
  }
ok "compiles with no warnings"

SIZE=$(wc -c < "$WORK/lidwing-notify")
echo "  note  binary size: $SIZE bytes"

# ------------------------------------------------------------------ no listener
#
# The case that happens most: the app is not running. Exit code 2 is a *blocking* error in
# Claude Code and would stall the user's agent, so the only acceptable answer is 0, fast.

export HOME="$WORK"
mkdir -p "$WORK/Library/Application Support/Lidwing"

START=$(date +%s%N 2>/dev/null || echo 0)
echo '{"hook":"test"}' | "$WORK/lidwing-notify" --claude
STATUS=$?
END=$(date +%s%N 2>/dev/null || echo 0)

if [ "$STATUS" -eq 0 ]; then
  ok "exits 0 with no listener"
else
  bad "exited $STATUS with no listener — this would stall the user's agent"
fi

if [ "$START" != "0" ] && [ "$END" != "0" ]; then
  ELAPSED_MS=$(( (END - START) / 1000000 ))
  echo "  note  elapsed with no listener: ${ELAPSED_MS}ms"
  if [ "$ELAPSED_MS" -lt 150 ]; then
    ok "returns in under 150ms with no listener (${ELAPSED_MS}ms)"
  else
    bad "took ${ELAPSED_MS}ms with no listener — budget is 150ms"
  fi
fi

# ------------------------------------------------------------------ a listener that is there

SOCKET="$WORK/Library/Application Support/Lidwing/notify.sock"
echo "  note  socket path is ${#SOCKET} chars (sun_path holds 103 on macOS, 107 on Linux)"
if [ "${#SOCKET}" -ge 103 ]; then
  bad "the socket path is too long for macOS - this test would hang there"
fi
RECEIVED="$WORK/received.txt"

# A listener in C rather than in Python: the Swift container has a compiler and no python3,
# and a test that skips on the machine where it usually runs is not a test.
cat > "$WORK/listener.c" <<'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>

/* A hang is worse than a failure: it burns a CI job to its timeout and reports nothing. */
static void give_up(int signal_number) {
    (void)signal_number;
    _exit(7);
}

int main(int argc, char **argv) {
    struct sockaddr_un address;
    int server, client;
    char buffer[4096];
    ssize_t got;
    FILE *out;

    if (argc < 3) return 2;
    /* Refuse a path that would be truncated, rather than binding to a different address than
     * the one we were asked for and waiting forever for a client that cannot find us. */
    if (strlen(argv[1]) >= sizeof(address.sun_path)) {
        fprintf(stderr, "socket path too long for sun_path (%zu >= %zu)\n",
                strlen(argv[1]), sizeof(address.sun_path));
        return 8;
    }
    signal(SIGALRM, give_up);
    alarm(10);
    unlink(argv[1]);
    server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 3;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, argv[1], sizeof(address.sun_path) - 1);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0) return 4;
    if (listen(server, 4) < 0) return 5;
    /* Say we are ready only once we are actually accepting. The socket file appears at bind,
     * and a caller that waits for it can connect in the window before listen and be refused.
     * The window is microseconds, which is exactly the kind of race that fails once a month
     * on somebody else's machine. */
    {
        char ready[1200];
        FILE *flag;
        snprintf(ready, sizeof(ready), "%s.ready", argv[1]);
        flag = fopen(ready, "w");
        if (flag) fclose(flag);
    }

    client = accept(server, NULL, NULL);
    if (client < 0) return 6;
    got = read(client, buffer, sizeof(buffer) - 1);
    if (got < 0) got = 0;
    buffer[got] = '\0';
    out = fopen(argv[2], "w");
    if (out) { fwrite(buffer, 1, (size_t)got, out); fclose(out); }
    close(client);
    close(server);
    unlink(argv[1]);
    return 0;
}
CSRC
"$CC" -O2 -o "$WORK/listener" "$WORK/listener.c" || { echo "  FAIL  listener will not build"; exit 1; }
# Clear the flag *before* starting the listener. Clearing it afterwards races the listener that
# is already writing it, and then waits five seconds for a flag that was deleted a moment after
# it appeared.
rm -f "$SOCKET.ready"
"$WORK/listener" "$SOCKET" "$RECEIVED" &
LISTENER=$!

# Wait for the listener to say it is accepting, rather than sleeping a guessed amount - and
# rather than waiting for the socket file, which appears one call earlier, at bind.
for _ in $(seq 1 50); do
  [ -f "$SOCKET.ready" ] && break
  sleep 0.1
done

echo '{"session":"abc","message":"needs permission"}' | "$WORK/lidwing-notify" --claude
STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "exits 0 with a listener"
else bad "exited $STATUS with a listener"; fi

wait "$LISTENER" 2>/dev/null
LISTENER_STATUS=$?
[ "$LISTENER_STATUS" -eq 7 ] && bad "the listener timed out waiting for a connection"
[ "$LISTENER_STATUS" -eq 8 ] && bad "the socket path was too long for sun_path"

if [ -s "$RECEIVED" ]; then
  BODY="$(cat "$RECEIVED")"
  echo "  note  received: $BODY"
  case "$BODY" in
    *'"v":1'*) ok "the message is version-tagged" ;;
    *) bad "no version tag in: $BODY" ;;
  esac
  case "$BODY" in
    *'"src":"claude"'*) ok "the source is carried through" ;;
    *) bad "no source in: $BODY" ;;
  esac
  case "$BODY" in
    *needs*permission*) ok "the body reaches the listener" ;;
    *) bad "the stdin payload did not arrive: $BODY" ;;
  esac
  # Newline-terminated, because the receiver frames on newlines. Checked against the file
  # rather than the shell variable: `$(cat ...)` strips the trailing newline, so testing the
  # variable would always say there is none.
  if [ "$(tail -c1 "$RECEIVED" | od -An -c | tr -d ' ')" = "\\n" ]; then
    ok "the line is newline-terminated"
  else
    bad "no trailing newline — the receiver would never frame the message"
  fi
  LINES="$(wc -l < "$RECEIVED" | tr -d ' ')"
  if [ "$LINES" -eq 1 ]; then ok "exactly one line"
  else bad "expected one line, got $LINES"; fi
else
  bad "the listener received nothing (empty is a failure, not a pass)"
fi

# ------------------------------------------------------------------ a slow writer
#
# The caller writes the payload to a pipe, and the helper may start before it does. A
# non-blocking read races that and returns EAGAIN, silently losing the body — the notification
# then arrives with nothing in it, which looks like the agent had nothing to say. This case
# makes the race deterministic by delaying the write, so the test can tell the two
# implementations apart.

# The delay is 10 ms against the helper's 100 ms budget. It used to be 50 ms, which is only a
# 2x margin, and on a loaded CI runner a `sleep 0.05` can genuinely overrun 100 ms - at which
# point the helper correctly gives up, sends an empty body, exits, and the writer's echo dies
# with EPIPE. That is exactly what happened on macOS in run 31427570805: the listener received
# `{"v":1,"src":"claude","body":""}` and the shell reported a broken pipe.
#
# The margin is what was wrong, not the assertion. The two implementations are still told apart
# by *any* delay, because a non-blocking read loses the payload even at 1 ms, and the helper
# needs a few ms to start - so 10 ms keeps every bit of the discriminating power at 10x the
# headroom.
#
# It also retries. A non-blocking read loses the payload on every single attempt, so retrying
# cannot hide that defect; a descheduled runner loses it once. The attempt count is printed
# either way, so a degraded machine is visible instead of silently tolerated.
slow_writer_attempt() {
  local delay="$1" received="$2"
  rm -f "$received" "$SOCKET" "$SOCKET.ready"
  "$WORK/listener" "$SOCKET" "$received" &
  local listener=$!
  local waited=0
  while [ ! -f "$SOCKET.ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  # `2>/dev/null` on the writer: if the helper has already given up, the echo dies with EPIPE,
  # and that shell diagnostic is a symptom of the case under test rather than an error in it.
  ( sleep "$delay"; echo '{"delayed":"payload"}' 2>/dev/null ) | "$WORK/lidwing-notify" --claude
  wait "$listener" 2>/dev/null
  local status=$?
  if [ "$status" -eq 7 ]; then return 7; fi
  grep -q "delayed" "$received" 2>/dev/null
}

SLOW_RECEIVED="$WORK/received-slow.txt"
SLOW_OK=0
SLOW_TRIES=0
for attempt in 1 2 3; do
  SLOW_TRIES="$attempt"
  if slow_writer_attempt 0.01 "$SLOW_RECEIVED"; then
    SLOW_OK=1
    break
  fi
done

if [ "$SLOW_OK" -eq 1 ]; then
  if [ "$SLOW_TRIES" -eq 1 ]; then
    ok "a payload written 10ms late still arrives"
  else
    ok "a payload written 10ms late still arrives (took $SLOW_TRIES attempts - loaded machine)"
  fi
else
  bad "lost a payload written 10ms late, three times over: $(cat "$SLOW_RECEIVED" 2>/dev/null)"
fi

# ------------------------------------------------------------------ chaining
#
# Codex's `notify` is a single scalar and is often already occupied. Ours execs whoever was
# there before, so that tool keeps working.

CHAIN_MARKER="$WORK/chained.txt"
cat > "$WORK/incumbent.sh" <<EOF
#!/bin/sh
echo "\$@" > "$CHAIN_MARKER"
exit 0
EOF
chmod +x "$WORK/incumbent.sh"

"$WORK/lidwing-notify" '{"payload":"x"}' --codex --chain "$WORK/incumbent.sh" --its-own-arg
STATUS=$?
if [ "$STATUS" -eq 0 ]; then ok "exits 0 when chaining"
else bad "exited $STATUS when chaining"; fi

if [ -f "$CHAIN_MARKER" ]; then
  ok "the displaced command actually ran: $(cat "$CHAIN_MARKER")"
else
  bad "the chained command never ran — we would have taken away a feature the user had"
fi

# ------------------------------------------------------------------ hostile input

BIG="$(head -c 20000 /dev/zero | tr '\0' 'x')"
if echo "$BIG" | "$WORK/lidwing-notify" --claude; then
  ok "exits 0 on a 20 KB payload"
else
  bad "a large payload changed the exit code"
fi

if printf '\x00\x01\x02 binary \xff\xfe' | "$WORK/lidwing-notify" --claude; then
  ok "exits 0 on binary input"
else
  bad "binary input changed the exit code"
fi

if HOME="" "$WORK/lidwing-notify" --claude </dev/null; then
  ok "exits 0 with no HOME set"
else
  bad "an unset HOME changed the exit code"
fi

echo "SUMMARY pass=$PASS fail=$FAIL"
exit "$FAIL"
