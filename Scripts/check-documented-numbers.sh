#!/bin/bash
# Numbers this project publishes about itself must match the repository.
#
# TESTING.md claimed "20 (ControlSocketTests 6, NotifyServerTests 8, StorageTests 3,
# IntegrationInstallerTests 7)". Four things wrong in one line: the breakdown summed to 24, not
# 20; the real total was 27; and `StorageTests` did not exist at all. Nobody noticed, because a
# number in a document is not checked by anything.
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

# Per-file counts in the macOS breakdown, each named with its file.
while read -r name count; do
  [ -n "$name" ] || continue
  file="Tests/LidwingSystemTests/${name}.swift"
  if [ ! -f "$file" ]; then
    echo "  FAIL  TESTING.md describes $name, which does not exist"
    FAIL=1
    continue
  fi
  compare "$name" "$count" "$(grep -c 'func test' "$file")"
done < <(grep -oE '`[A-Za-z]+Tests` [0-9]+' TESTING.md | tr -d '`')

# Every macOS test file must appear in that breakdown, or the total is right by luck.
for file in Tests/LidwingSystemTests/*.swift; do
  name="$(basename "$file" .swift)"
  if ! grep -q "\`$name\`" TESTING.md; then
    echo "  FAIL  $name exists and TESTING.md does not mention it"
    FAIL=1
  fi
done

# The Linux suite total, from the summary table.
DOC_LINUX="$(grep -oE '^\| Tests \| \*\*[0-9]+\*\*' TESTING.md | head -1 | grep -oE '[0-9]+')"
ACTUAL_LINUX="$(grep -ch 'func test' Tests/LidwingCoreTests/*.swift | paste -sd+ - | bc)"
compare "Linux test count" "$DOC_LINUX" "$ACTUAL_LINUX"

# The macOS total, and its own breakdown.
DOC_MACOS="$(grep -oE '\| Tests \| \*\*[0-9]+\*\* \(`' TESTING.md | grep -oE '[0-9]+')"
ACTUAL_MACOS="$(grep -ch 'func test' Tests/LidwingSystemTests/*.swift | paste -sd+ - | bc)"
compare "macOS test count" "$DOC_MACOS" "$ACTUAL_MACOS"

SUM="$(grep -oE '`[A-Za-z]+Tests` [0-9]+' TESTING.md | grep -oE '[0-9]+$' | paste -sd+ - | bc)"
compare "macOS breakdown sum" "$SUM" "$ACTUAL_MACOS"

if [ "$FAIL" -ne 0 ]; then
  echo "DOCUMENTED NUMBERS ARE WRONG"
  exit 1
fi
echo "documented numbers OK"
