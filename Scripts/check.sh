#!/bin/bash
# The pre-push gate, runnable in one command from the Linux box.
#
# Everything here is what CI will do anyway. Running it locally first is the difference between
# a five-second loop and a five-minute one.
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKER_SWIFT="${DOCKER_SWIFT:-swift:6.0}"
DOCKER_LINT="${DOCKER_LINT:-ghcr.io/realm/swiftlint:latest}"
FAIL=0

run_swift() {
  docker run --rm -v "$PWD":/src -w /src -u "$(id -u):$(id -g)" -e HOME=/tmp "$DOCKER_SWIFT" "$@"
}

# A workflow that GitHub refuses to parse produces a run with ZERO jobs and a red tick that
# names nothing — the hardest kind of red to read. actionlint catches that class before it
# costs a round trip.
if [ -x /tmp/actionlint ]; then
  echo "== workflows"
  /tmp/actionlint || FAIL=1
elif command -v actionlint >/dev/null; then
  echo "== workflows"
  actionlint || FAIL=1
else
  echo "== workflows (skipped: actionlint not installed — see Scripts/README.md)"
fi

# The shell scripts are a large part of this product and they run on Denis's machine, where I
# cannot debug them. macOS ships bash 3.2, this box has 5.x, and the difference is exactly the
# kind of thing that only shows up in front of the person who can least afford it.
echo "== shell scripts"
docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable -S warning \
  Scripts/*.sh spike/*.sh || FAIL=1

echo "== core purity"
./Scripts/check-core-purity.sh || FAIL=1

./Scripts/check-bundle-contract.sh || FAIL=1   # prints its own header

echo "== build (warnings are errors)"
run_swift swift build -Xswiftc -warnings-as-errors || FAIL=1

echo "== tests"
run_swift swift test 2>&1 | tee /tmp/lidwing-test.log | tail -3 || FAIL=1

# Empty is never success. A run that collected no tests has proved nothing, and "no failures"
# read from silence is how a green board comes to mean nothing.
COUNT="$(grep -Eo 'Executed [0-9]+ tests' /tmp/lidwing-test.log | tail -1 | grep -Eo '[0-9]+' || echo 0)"
echo "   collected $COUNT tests"
if [ "$COUNT" -lt 40 ]; then
  echo "   FAIL: too few tests collected — did the suite actually run?"
  FAIL=1
fi

echo "== notify helper"
# `timeout`, because these tests talk to sockets and a wedged one would hang this gate the way
# it once hung a CI job. A hang is not a pass.
timeout 120 docker run --rm -v "$PWD":/src -w /src -u "$(id -u):$(id -g)" -e HOME=/tmp \
  "$DOCKER_SWIFT" ./Scripts/test-notify-helper.sh | tail -1 || FAIL=1

echo "== lint (strict)"
docker run --rm -v "$PWD":/work -w /work "$DOCKER_LINT" swiftlint lint --strict --reporter emoji \
  | tail -1 || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "GATE FAILED"
  exit 1
fi
echo "GATE PASSED"
