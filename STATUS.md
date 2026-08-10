# STATUS

Updated every cycle. PROVEN means a machine checked it and the output is in this repository.
ASSUMED means it follows from reading, not from running. BROKEN means it is red right now.

**Cycle 1** · 2026-08-10

## PROVEN

- `LidwingCore` builds on Linux with Swift 6.0.3 and its unit suite is green:
  **67 tests, 0 failures**, 0.4 s wall clock (`docker run swift:6.0 swift test`).
- The suite has been **seen red**. Four assertions failed on their first run
  (thermal-dwell and battery-near-floor expectations); the code was right and the expectations
  were wrong, and they were corrected. Raw before/after in `TESTING.md`.
- `Scripts/check-core-purity.sh` passes, and its **positive control** passes: inserting
  `import AppKit` into `Sources/LidwingCore/Version.swift` turns it red, removing it turns it
  green again. Transcript in `TESTING.md`.
- The name `Lidwing` is clear on the Mac App Store (`resultCount: 0`), the iOS App Store, npm,
  PyPI, GitHub repository search and DNS (`lidwing.app` is `NXDOMAIN`). Commands and outputs in
  `docs/decisions/0007-name-availability-check.md`.
- The repository is public and empty; macOS Actions minutes are therefore free and unlimited.

## ASSUMED — and this is the whole product

- **Nobody has ever armed the clamshell bit and closed a lid.** `IOPMrootDomain` selector 12
  (`kPMSetClamshellSleepState`) is a constant in the public SDK header `IOPMLibDefs.h`, its
  dispatch entry has no privilege check in every xnu tag from 10.14 to 26, and the design of
  this entire product rests on it working. Every claim to date is derived from kernel source.
  `docs/M0-spike.md` is the experiment that decides it. Until it reports, nothing here is a
  product.
- Everything about IOKit, CoreAudio, AppKit and the macOS runtime. There is no macOS SDK on
  this machine; only GitHub Actions and Denis's Mac can turn any of it into PROVEN.

## BROKEN

Nothing is red.

## BLOCKERS

- **T5 (partially open) — USPTO trademark search for "Lidwing" not performed.** The public
  search endpoint needs a browser session. Every other registry is clear. This does not block
  development; it must be closed before the first published build, because the marker string we
  write into `~/.claude/settings.json` embeds the bundle path. See
  `docs/human-checklist.md` item **H0**.
- **M0 (blocking for product code beyond the core) — the lid experiment.** Needs a physically
  closed lid, which no rentable Mac on Earth has. `docs/human-checklist.md` items **H1–H3**.

Nothing is idling on either. Work continues on everything that does not depend on the fork.

## Decisions recorded this cycle

| # | Conflict | Resolution |
|---|---|---|
| [0001](docs/decisions/0001-product-name-and-identifiers.md) | `Lidwing` vs `Wing`, three spellings of the bundle id | `DESIGN.md` §1.4 wins; `CRAFT.md` corrected in place |
| [0002](docs/decisions/0002-mechanism-authority.md) | Unprivileged clamshell mask vs root helper writing `SleepDisabled` | Tier 1, on the safety asymmetry — the mask leaves emergency sleep armed |
| [0003](docs/decisions/0003-deployment-floor.md) | macOS 12.0 vs 13.0 vs "last 5-8 years" | 12.0: the 13.0 floor was `SMAppService`, which decision 0002 removed |
| [0004](docs/decisions/0004-low-power-mode.md) | Permanent non-goal vs default-ON toggle, incl. a contradiction inside `DECISIONS.md` | Toggle, **default ON**, no numbers in the UI |
| [0005](docs/decisions/0005-thermal-and-battery-guard-timing.md) | Thermal disarm: immediate vs 60 s dwell | 60 s dwell; the kernel's own thermal emergency sleep is still armed underneath us |
| [0006](docs/decisions/0006-repository-visibility-and-readme.md) | "Private" vs measured public | Public; `spec/` never committed, one-line README until release |
| [0007](docs/decisions/0007-name-availability-check.md) | T5 name check | Clear everywhere reachable; USPTO open |

## Shipped this cycle

```
Package.swift                       Linux builds LidwingCore only; macOS builds everything
Sources/LidwingCore/
  Constants.swift                   frozen identifiers
  Version.swift                     zero-padded build numbers, semver
  SystemFacade.swift                the one seam between logic and machine
  SafetyPolicy.swift                battery floor, thermal ceiling, duration lease, refusals
  StateMachine.swift                8 states, 20 events, invariants I1-I9
  Ledger.swift                      durable intent + launch reconciliation
  AuditRecord.swift                 session accumulator + JSONL record
Tests/LidwingCoreTests/             67 tests incl. a 1000-cycle stress and a property test
Scripts/check-core-purity.sh        the guard that keeps the core buildable on Linux
.github/workflows/ci.yml            linux core, core purity, macOS build+test, lint, macOS 26 canary
.swiftlint.yml                      --strict, with custom rules banning pmset/ioreg shell-outs
docs/decisions/0001..0007
```

## NEXT

1. Push, and get CI green on macOS. A red build is the only emergency.
2. `spike/` — adopt and harden `wingprobe`, extend to the full 8-hour M0 protocol, write
   `docs/M0-spike.md` and `docs/human-checklist.md`.
3. Telegram to Denis: what shipped, what CI proved, what M0 needs from him.
4. M1: the Darwin layer behind `SystemFacade` — `ClamshellLock`, `IdleLease`, the five
   observers, the watchdog agent, the status item.
