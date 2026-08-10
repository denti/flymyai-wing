#!/bin/bash
# Numbers this project publishes about itself must match the repository.
#
# TESTING.md claimed "20 (ControlSocketTests 6, NotifyServerTests 8, StorageTests 3,
# IntegrationInstallerTests 7)". The breakdown summed to 24, not 20, and the real total was 27.
#
# The first version of this check also reported that `StorageTests` did not exist, which was
# wrong and cost a red build: it existed as a *class*, inside ControlSocketTests.swift. These
# numbers count test classes, not files, so that is what this counts. The class has since been
# moved into the file that bears its name - two classes of the same name in one module is a
# compile error, which is how I found out.
#
# This product's whole argument is "prove it, don't claim it". A document full of measurements
# that drifted is worse than one with no numbers, because it reads exactly like a measurement.
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 2; }

FAIL=0

compare() {
  local what="$1" documented="$2" actual="$3"
  if [ -z "$documented" ]; then
    echo "  FAIL  could not find the documented $what - this check proved nothing"
    FAIL=1
  elif [ "$documented" != "$actual" ]; then
    echo "  FAIL  $what: TESTING.md says $documented, the repository has $actual"
    FAIL=1
  else
    echo "  ok    $what: $actual"
  fi
}

echo "== documented numbers"

# Counts every `func test` per XCTestCase class, wherever that class happens to live.
class_counts() {
  awk '/^final class [A-Za-z]+: XCTestCase/ { name=$3; sub(":","",name) }
       /func test/ { if (name != "") count[name]++ }
       END { for (k in count) print k, count[k] }' "$@" | sort
}

MACOS_COUNTS="$(class_counts Tests/LidwingSystemTests/*.swift)"

while read -r name documented; do
  [ -n "$name" ] || continue
  actual="$(printf '%s\n' "$MACOS_COUNTS" | awk -v n="$name" '$1==n {print $2}')"
  if [ -z "$actual" ]; then
    echo "  FAIL  TESTING.md describes a class $name that no macOS test file declares"
    FAIL=1
    continue
  fi
  compare "$name" "$documented" "$actual"
done < <(grep -oE '`[A-Za-z]+Tests` [0-9]+' TESTING.md | tr -d '`')

# Every class must appear in that breakdown, or a matching total is luck.
while read -r name _; do
  [ -n "$name" ] || continue
  if ! grep -q "\`$name\`" TESTING.md; then
    echo "  FAIL  the class $name exists and TESTING.md does not mention it"
    FAIL=1
  fi
done < <(printf '%s\n' "$MACOS_COUNTS")

# The Linux suite total, from the summary table.
DOC_LINUX="$(grep -oE '^\| Tests \| \*\*[0-9]+\*\*' TESTING.md | head -1 | grep -oE '[0-9]+')"
ACTUAL_LINUX="$(grep -ch 'func test' Tests/LidwingCoreTests/*.swift | paste -sd+ - | bc)"
compare "Linux test count" "$DOC_LINUX" "$ACTUAL_LINUX"

# The macOS total, and its own breakdown.
DOC_MACOS="$(grep -oE '\| Tests \| \*\*[0-9]+\*\* \(`' TESTING.md | grep -oE '[0-9]+')"
ACTUAL_MACOS="$(printf '%s\n' "$MACOS_COUNTS" | awk '{s+=$2} END {print s+0}')"
compare "macOS test count" "$DOC_MACOS" "$ACTUAL_MACOS"

SUM="$(grep -oE '`[A-Za-z]+Tests` [0-9]+' TESTING.md | grep -oE '[0-9]+$' | paste -sd+ - | bc)"
compare "macOS breakdown sum" "$SUM" "$ACTUAL_MACOS"

if [ "$FAIL" -ne 0 ]; then
  echo "DOCUMENTED NUMBERS ARE WRONG"
  exit 1
fi
echo "documented numbers OK"
