#!/bin/bash
# LidwingCore is the half of this product that builds and unit-tests on Linux in seconds.
# That property is load-bearing for the whole development loop, and it is exactly one careless
# `import AppKit` away from being lost. This script is the guard, and it is meant to be run
# locally as well as in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

CORE="Sources/LidwingCore"
FAIL=0

# Frameworks that would tie the core to Darwin. Foundation is portable and is the only
# dependency the core is allowed.
FORBIDDEN='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(AppKit|Cocoa|IOKit|CoreAudio|AudioToolbox|CoreGraphics|Darwin|SwiftUI|UserNotifications|ServiceManagement|CoreFoundation|Security|SystemConfiguration)\b'

if grep -rEn "$FORBIDDEN" "$CORE"; then
  echo "FAIL: LidwingCore imports a platform-specific framework (above)."
  FAIL=1
fi

# Shelling out to pmset or ioreg for a control decision is banned everywhere but the
# read-only diagnostics panel; in the core it is banned outright.
if grep -rEn '(Process\(\)|posix_spawn|/usr/bin/pmset|/usr/sbin/ioreg|NSTask)' "$CORE"; then
  echo "FAIL: LidwingCore spawns a process. All system access goes through SystemFacade."
  FAIL=1
fi

# Swift has no stored properties in extensions, and the Darwin-only targets are not compiled
# on Linux — so this class of error would reach a macOS runner before anyone saw it. One grep
# is cheaper than a round trip.
if grep -rEn '^    (var|let) [a-zA-Z_]+ *(:|=)' Sources/*/*+*.swift 2>/dev/null; then
  echo "FAIL: a stored property in an extension file (above). Swift does not allow that."
  FAIL=1
fi

# A type split across `Foo.swift` and `Foo+Bar.swift` cannot use `private` for anything the
# other file touches: `private` is file-scoped in Swift, and `private(set)` confines the setter
# to the declaring file. Both are compile errors that only a macOS runner would see, because
# the Darwin-only targets are never built here. This has cost two round trips already.
#
# The check is deliberately precise: a `private` member the sibling never mentions is correct
# encapsulation, and flagging it would push everything to `internal` for no reason.
for split in Sources/*/*+*.swift; do
  [ -e "$split" ] || continue
  base="${split%%+*}.swift"
  [ -e "$base" ] || continue
  while read -r name; do
    [ -n "$name" ] || continue
    if grep -qE "(^|[^A-Za-z0-9_.])${name}([^A-Za-z0-9_]|$)" "$split"; then
      echo "FAIL: $(basename "$base") declares '$name' private, and $(basename "$split") uses it."
      echo "      private is file-scoped in Swift. Make it internal, or move the use."
      FAIL=1
    fi
  done < <(grep -oE '^ *private(\(set\))? +(var|let|func) +[A-Za-z_][A-Za-z0-9_]*' "$base" \
           | awk '{print $NF}')
done

# ---------------------------------------------------------------------------------------
# 4. Log events must be named through LogCatalogue in the Darwin modules.
#
# `log.emit(.osChanged, ...)` looks right and compiles nowhere: leading-dot lookup resolves
# against the parameter type `LogEvent`, and the events are static members of `LogCatalogue`.
# Cost me a full CI round trip, because none of the Darwin targets compile on Linux - CI is
# their only compiler, so a six-minute round trip is the price of every typo in them. This grep
# is not a substitute for that compiler; it just stops this particular one from recurring.
for file in Sources/LidwingApp/*.swift Sources/LidwingSystem/*.swift Sources/lidwingd/*.swift; do
  [ -f "$file" ] || continue
  # Anchored on the log receiver. A bare `\.emit\(\.` also matches `Observers.emit(.thermalChanged)`,
  # which is a different, entirely correct method - and a check that fires on correct code gets
  # switched off within a week.
  if grep -nE '(^|[^A-Za-z0-9_])(log|Log\.shared)\.emit\(\.' "$file"; then
    echo "FAIL: $file names a log event with a leading dot."
    echo "      Use LogCatalogue.<event>: leading-dot lookup resolves against LogEvent, which"
    echo "      has no such member, and no Linux build will ever tell you."
    FAIL=1
  fi
done

# ---------------------------------------------------------------------------------------
# 5. Every modal must be preceded by NSApp.activate.
#
# Lidwing is LSUIElement: no Dock icon, no menu bar of its own. An NSAlert shown without
# activating first opens *behind* whatever the user was doing, and `runModal` then blocks the
# process on a dialog they cannot see and cannot dismiss. This found a real one - the "already
# running" alert, whose entire audience is a user who double-clicked the app in Finder because
# they could not find it.
#
# Fifteen lines of context, which is the distance in the code that actually exists; a modal
# whose activate is further away than that is worth a second look anyway.
while IFS=: read -r file line _; do
  [ -n "$file" ] || continue
  start=$((line - 15)); [ "$start" -lt 1 ] && start=1
  if ! sed -n "${start},${line}p" "$file" | grep -q "activate(ignoringOtherApps"; then
    echo "FAIL: $file:$line runs a modal without activating first."
    echo "      An LSUIElement app shows it behind the user's editor, with no Dock icon to click."
    FAIL=1
  fi
done < <(grep -rn "runModal()" Sources/LidwingApp/*.swift 2>/dev/null)

# ---------------------------------------------------------------------------------------
# 6. A workflow step that pipes must set pipefail.
#
# GitHub runs `run:` blocks under `bash -e`, which does *not* set pipefail, so in
# `swift test | tee log` it is `tee` that decides the step's exit code. A compile error then
# reads as a passing step. Not hypothetical: run 31429307962 had a macOS build failure and the
# "Unit tests" step went green, leaving the count guard to notice - far too late for something
# the compiler already knew, and the same masking made the macos-26 canary incapable of
# reporting a failing test at all.
#
# Parsed as blocks rather than by looking a few lines back. The first version of this check
# searched the twelve preceding lines for the word `pipefail` and found the *previous step's*,
# so its positive control did not fire. A check that cannot fail is worse than no check.
PIPEFAIL_REPORT="$(awk '
  # A single-line `run:` that pipes. There is nowhere for a pipefail to live except this line.
  /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[^|[:space:]]/ {
    if ($0 ~ /\|[[:space:]]*(tee|tail|head|grep|sort|awk|sed)/ && $0 !~ /pipefail/) {
      printf "%s:%d: single-line run pipes without pipefail\n", FILENAME, FNR
    }
    inblock = 0
    next
  }
  # A block scalar. Remember where it started and how far it is indented.
  /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*\|/ {
    if (inblock && piped && !safe) {
      printf "%s:%d: run block pipes without pipefail\n", FILENAME, blockline
    }
    inblock = 1; piped = 0; safe = 0; blockline = FNR
    match($0, /^[[:space:]]*/); indent = RLENGTH
    next
  }
  inblock {
    # A line at or below the block indentation ends it.
    if ($0 ~ /[^[:space:]]/) {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= indent) {
        if (piped && !safe) {
          printf "%s:%d: run block pipes without pipefail\n", FILENAME, blockline
        }
        inblock = 0
        next
      }
    }
    if ($0 ~ /pipefail/) safe = 1
    if ($0 ~ /\|[[:space:]]*(tee|tail|head|grep|sort|awk|sed)/) piped = 1
  }
  END {
    if (inblock && piped && !safe) {
      printf "%s:%d: run block pipes without pipefail\n", FILENAME, blockline
    }
  }
' .github/workflows/*.yml 2>/dev/null)"

if [ -n "$PIPEFAIL_REPORT" ]; then
  printf '%s\n' "$PIPEFAIL_REPORT" | while IFS= read -r line; do
    echo "FAIL: $line"
  done
  echo "      \`tee\` and \`tail\` return 0, so the command before them cannot fail the step."
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  # Assert on real output, never on the absence of an error: prove we actually looked at files.
  COUNT=$(find "$CORE" -name '*.swift' | wc -l | tr -d ' ')
  if [ "$COUNT" -lt 1 ]; then
    echo "FAIL: found no Swift files under $CORE — this check proved nothing."
    exit 1
  fi
  echo "core purity OK ($COUNT files scanned)"
fi

exit "$FAIL"
