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
WORK="$(mktemp -d)"
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
RECEIVED="$WORK/received.txt"

# A listener in C rather than in Python: the Swift container has a compiler and no python3,
# and a test that skips on the machine where it usually runs is not a test.
cat > "$WORK/listener.c" <<'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

int main(int argc, char **argv) {
    struct sockaddr_un address;
    int server, client;
    char buffer[4096];
    ssize_t got;
    FILE *out;

    if (argc < 3) return 2;
    unlink(argv[1]);
    server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 3;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, argv[1], sizeof(address.sun_path) - 1);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0) return 4;
    if (listen(server, 4) < 0) return 5;

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
"$WORK/listener" "$SOCKET" "$RECEIVED" &
LISTENER=$!

# Wait for the socket to exist rather than sleeping a guessed amount.
for _ in $(seq 1 50); do
  [ -S "$SOCKET" ] && break
  sleep 0.1
done

echo '{"session":"abc","message":"needs permission"}' | "$WORK/lidwing-notify" --claude
STATUS=$?
[ "$STATUS" -eq 0 ] && ok "exits 0 with a listener" || bad "exited $STATUS with a listener"

wait "$LISTENER" 2>/dev/null || true

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
  [ "$LINES" -eq 1 ] && ok "exactly one line" || bad "expected one line, got $LINES"
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

SLOW_RECEIVED="$WORK/received-slow.txt"
"$WORK/listener" "$SOCKET" "$SLOW_RECEIVED" &
SLOW_LISTENER=$!
for _ in $(seq 1 50); do
  [ -S "$SOCKET" ] && break
  sleep 0.1
done

( sleep 0.05; echo '{"delayed":"payload"}' ) | "$WORK/lidwing-notify" --claude
wait "$SLOW_LISTENER" 2>/dev/null || true

if grep -q "delayed" "$SLOW_RECEIVED" 2>/dev/null; then
  ok "a payload written 50ms late still arrives"
else
  bad "lost a payload the caller wrote 50ms late: $(cat "$SLOW_RECEIVED" 2>/dev/null)"
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
[ "$STATUS" -eq 0 ] && ok "exits 0 when chaining" || bad "exited $STATUS when chaining"

if [ -f "$CHAIN_MARKER" ]; then
  ok "the displaced command actually ran: $(cat "$CHAIN_MARKER")"
else
  bad "the chained command never ran — we would have taken away a feature the user had"
fi

# ------------------------------------------------------------------ hostile input

BIG="$(head -c 20000 /dev/zero | tr '\0' 'x')"
echo "$BIG" | "$WORK/lidwing-notify" --claude
[ $? -eq 0 ] && ok "exits 0 on a 20 KB payload" || bad "a large payload changed the exit code"

printf '\x00\x01\x02 binary \xff\xfe' | "$WORK/lidwing-notify" --claude
[ $? -eq 0 ] && ok "exits 0 on binary input" || bad "binary input changed the exit code"

HOME="" "$WORK/lidwing-notify" --claude </dev/null
[ $? -eq 0 ] && ok "exits 0 with no HOME set" || bad "an unset HOME changed the exit code"

echo "SUMMARY pass=$PASS fail=$FAIL"
exit "$FAIL"
