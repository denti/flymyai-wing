# STATUS

Updated every cycle. PROVEN means a machine checked it and the output is in this repository.
ASSUMED means it follows from reading, not from running. BROKEN means it is red right now.

**Cycle 2** · 2026-08-10

## PROVEN

- **CI is green on every job**: `core-linux`, `core-purity`, `test-macos` (macOS 15),
  `lint` (`swiftlint --strict`, 0 violations), and the `macos-26` canary. The whole Darwin
  layer — IOKit, CoreAudio, AppKit, the watchdog daemon, the C notify helper — compiles and
  its tests pass on both macOS 15 and macOS 26.
- **112 unit tests, 0 failures**, 0.7 s on Linux; the same suite plus 9 macOS-only tests in CI.
- **The suite has been proven able to fail, four ways.** Deliberate mutations produced 21, 14,
  9 and 1 failures respectively. Numbers and mutations in `TESTING.md`; the one caught by a
  single test is called out as the weak spot rather than averaged away.
- **1000 arm/disarm cycles** leave ground truth stock, zero leaked assertions, no ledger.
- **12 000 random state transitions** never leave the machine reporting protection without
  owning the mechanism.
- The name `Lidwing` is clear on both App Stores, npm, PyPI, GitHub and DNS. USPTO is open
  (`docs/human-checklist.md` H0).

## ASSUMED — and this is still the whole product

- **Nobody has armed the clamshell bit and closed a lid.** Everything downstream of that is
  reading, not measurement. `docs/M0-spike.md` is the experiment; `spike/m0-run.sh` is the
  script Denis runs. Until it reports, this is a well-tested program that has never done its
  job once.
- Everything about the real machine: a physically closed lid, a real power event, real thermal
  behaviour, whether the status item is visible on a crowded menu bar, the Gatekeeper flow.

## BROKEN

Nothing is red.

## BLOCKERS

- **M0** — the lid experiment. `docs/human-checklist.md` H1–H3. Nothing else can substitute:
  no rentable Mac on Earth has a hinge.
- **T5, partially open** — USPTO search for "Lidwing". Every other registry is clear. Blocks
  the first published build, not development.
- **H4** — Apple Developer Program. Multi-week lead time, blocks anyone but Denis installing a
  build. Development continues without it; `sign.sh` takes the identity the moment it exists.

Nothing is idling on any of these.

## Shipped since cycle 1

| Area | What |
|---|---|
| Mechanism | `ClamshellLock` (selector 12), `IdleLease` (named assertion), `RootDomain` reads, `AssertionInspector` verified by pid **and** name |
| Observers | clamshell interest, `IORegisterForSystemPower`, `IOPSNotification`, display reconfiguration, thermal — each C callback does nothing but decode and hop to the main queue |
| Watchdog | `lidwingd` LaunchAgent; app is the **client** so its death is EOF, not a missed heartbeat. Decision logic extracted to `WatchdogPolicy` in the portable module, 13 tests |
| App | status item, menu, drawn wing glyph, chimes, notifications, diagnostics, uninstaller, first run |
| Uninstall | written and tested **before** the installer. The plan is data so its order is testable; each step carries its reason |
| Packaging | `build.sh` (universal via two builds + `lipo`), `sign.sh` (inside-out, never `--deep`), `notarize.sh`, `package.sh`, `invariants.sh` |
| Gates | `Scripts/check.sh` runs workflows, purity, build, tests and lint from Linux in one command |
| Fault injection | `Scripts/fault-injection.sh` — SIGKILL while armed, corrupt ledger, watchdog killed. Needs a real Mac |

## Decisions recorded

| # | Conflict | Resolution |
|---|---|---|
| [0001](docs/decisions/0001-product-name-and-identifiers.md) | Three spellings of the bundle id | `DESIGN.md` §1.4; `CRAFT.md` corrected in place |
| [0002](docs/decisions/0002-mechanism-authority.md) | Unprivileged mask vs root helper | Tier 1, on the safety asymmetry |
| [0003](docs/decisions/0003-deployment-floor.md) | 12.0 vs 13.0 vs "5-8 years" | 12.0 |
| [0004](docs/decisions/0004-low-power-mode.md) | Non-goal vs default-ON toggle | Toggle, default ON, no numbers in the UI |
| [0005](docs/decisions/0005-thermal-and-battery-guard-timing.md) | Thermal disarm immediate vs 60 s | 60 s dwell |
| [0006](docs/decisions/0006-repository-visibility-and-readme.md) | Private vs measured public | Public; one-line README until release |
| [0007](docs/decisions/0007-name-availability-check.md) | T5 name check | Clear everywhere reachable |
| [0008](docs/decisions/0008-when-lidwing-makes-a-sound.md) | Chime on arm vs on lid close | Lid close, and standing down with the lid shut |

## Audit

`AUDIT.md` round 1: one **critical** defect — `wingprobe disarm`, the safety valve, armed the
machine instead of releasing it — plus two that would have made the CI signal meaningless
without looking broken. Five rejected findings recorded with reasons.

## NEXT

1. Round 2 of the audit, against the app's runtime behaviour rather than its logic.
2. A soak harness measuring the app's own idle CPU, memory and file-descriptor growth as hard
   numbers, since `CRAFT.md` §7.1 states them as gates and none of them is measured yet.
3. The compatibility smoke script (`ADDENDUM.md` §2.4), rewritten for Tier 1: canaries for
   selector-12 reachability, bundle integrity, and `SKIP` that is never `PASS`.
4. Settings window and the remaining M2 surface.
5. `INSTALL.md`, then the real README with the four falsify-us commands — last, per
   `DECISIONS.md`.
