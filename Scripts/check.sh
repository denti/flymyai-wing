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

echo "== core purity"
./Scripts/check-core-purity.sh || FAIL=1

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

echo "== lint (strict)"
docker run --rm -v "$PWD":/work -w /work "$DOCKER_LINT" swiftlint lint --strict --reporter emoji \
  | tail -1 || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "GATE FAILED"
  exit 1
fi
echo "GATE PASSED"
