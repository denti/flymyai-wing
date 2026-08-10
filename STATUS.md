# STATUS

Updated every cycle. PROVEN means a machine checked it and the output is in this repository.
ASSUMED means it follows from reading, not from running. BROKEN means it is red right now.

**Cycle 8** · 2026-08-10

## PROVEN

- **CI is green on every job** — and, for the first time, that sentence means something. Until
  commit `e3d5a9b` the macOS jobs piped `swift test` into `tee` with no `pipefail`, so `tee`
  decided the exit code and **five failing tests reported success on every run for weeks**. The
  claim that used to sit here was false, and it was false in the way that matters: it was
  checkable, and nothing checked it. Both failures were the test's own socket path exceeding
  `sun_path` on a CI runner, not a product defect - but that is luck, not diligence.
- **216 unit tests, 0 failures**, 1.3 s on Linux; the same suite plus 33 macOS-only tests in CI.
- **`shellcheck -S warning` clean** over every script, in the gate and in CI. The scripts run on
  a Mac I cannot debug, and macOS ships bash 3.2 where this box has 5.x.
- **The hook helper is measured, not assumed**: 15 behavioural assertions against the compiled
  binary, 12 528 bytes, no warnings at `-Wall -Wextra -Werror`, and **5 ms with no listener**
  against a 150 ms budget. Running it found a real defect — see below. Its slow-writer case was
  flaky against a 2x timing margin and is now 10 ms against 100 ms with retries, proven still
  able to catch the defect it exists for.
- **A `.dmg` exists.** `Scripts/build.sh` → `sign.sh` → `package.sh` → `invariants.sh` runs
  end to end on every push. All **15 artifact invariants** are green on the real artifact:
  universal (`x86_64 arm64`), `minos 12.0` on both slices, hard-linked concurrency runtime,
  signature verifies deep and strict, `LSUIElement`, a ten-digit build number, **zero**
  `UsageDescription` keys and **zero** entitlements of any kind.
- **The suite has been proven able to fail, twenty-three ways.** Deliberate mutations produced
  21, 14, 9, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1 and 1 failures. Numbers and mutations in
  `TESTING.md`; the ones caught by a single test are called out as the weak spots rather than
  averaged away.
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
  no rentable Mac on Earth has a hinge. The harness now refuses to report PASS unless the lid
  was actually shut for most of the run, and its verdict arithmetic is tested by
  `Scripts/test-m0-verdict.sh` against sixteen cases including that one.
- **T5, partially open** — USPTO search for "Lidwing". Every other registry is clear. Blocks
  the first published build, not development.
- **Low Power Mode cannot be written without root** — and it is a Denis override, default ON
  ([0004](docs/decisions/0004-low-power-mode.md)), against a Tier 1 architecture with no
  privileges at all ([0002](docs/decisions/0002-mechanism-authority.md)). `ADDENDUM.md` §W4 puts
  `pmset -b/-c lowpowermode` inside the privileged helper and `CRAFT.md` §733 calls it a
  privileged write. Escalated as [0010](docs/decisions/0010-low-power-mode-needs-a-privilege-this-tier-does-not-have.md);
  the choice between dropping it, guiding the user to the Battery pane once, or shipping a root
  helper is a product call. **H9** settles the premise itself in thirty seconds on a real Mac,
  because every source for it is a document rather than a run. No half-toggle ships meanwhile:
  a checkbox that appears to engage Low Power Mode and does not is worse than its absence.
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
| Integrations | Order-preserving JSON for `~/.claude/settings.json`; a line editor for `~/.codex/config.toml` that chains rather than replaces an occupied `notify`. Backup, original file mode, temp file in the same directory, `rename(2)` |
| Auto mode | Arms while `claude`, `codex` or `cursor-agent` runs; stands down after a grace period. The only poll in the product, and only when the user chooses it |
| Notify socket | `lidwing-notify` and the server that receives it. Invariant I8 enforced structurally: the receiver holds no reference through which it could arm anything |
| Settings | A real window: mode, battery floor, duration, thermal guard, sound, and the agent integrations with their diff-before-write |
| Release | `release.yml` — test, build, sign, notarize, staple, **then** attest and checksum |
| Logging | A closed catalogue of 24 events, none below `.notice`, with the field allowlist unit-tested. `docs/SYMBOLICATE.md` turns any crash report a user pastes into a line number |
| Localisation | Every user-visible string through one catalogue, with a full Russian translation. Two tests: every catalogue covers every key, and every translation keeps its placeholders |
| Security | `SECURITY.md`: three surfaces, four mechanisms against the one failure mode that matters |
| Hook helper | `Scripts/test-notify-helper.sh` — compiles it, runs it, measures it. Part of the ordinary gate on Linux and on macOS |
| Script hygiene | `shellcheck -S warning` on every script, locally and in CI |
| Bundle contract | The build script, the signing script and the runtime name the same files in three places. A script checks they agree, with five positive controls |
| State on disk | The directory is verified and repaired on every launch rather than trusted from its creation; a symlink in its place is refused; sockets are private from the instant `bind` creates them |
| Documented numbers | Every test count this repository publishes about itself is checked against the repository. It was wrong when the check was written |
| Workflow pipes | Every `run:` block that pipes is checked for `set -o pipefail`, parsed as block scalars rather than by proximity. Six steps were masking their exit codes, two of them the canary's |
| macOS updates | The build on which an arm last verified is remembered; a change is noticed at launch and reported by the next verified arm. Nothing probes, because nothing may arm unasked |
| Sound self-check | Fallbacks per chime, a Play button, and a check that names what is missing. Sound is the only channel once the lid is shut |
| Launch at login | `SMAppService` only, never ticked by default, and the checkbox is read from the live system status rather than a boolean of ours - the one a user can revoke while the app is not running. No checkbox at all on macOS 12, where the only mechanisms are the two the antipattern list forbids |
| Accessibility | Display accommodations read live, Reduce Motion honoured, one tooltip per state, focus starts on a control. The parts a machine cannot check are `docs/human-checklist.md` H8 |

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
| [0009](docs/decisions/0009-localisation-scope.md) | Eight languages vs what can be checked | English and Russian, complete and tested; diagnostics stay English on purpose |

## Audit — ten rounds, all findings fixed

| Round | Method | Worst finding |
|---|---|---|
| 10 (the M0 script) | Ask of the most consequential script: can this report success without proving anything? | **A PASS did not require the lid to have been closed.** Nothing sampled `AppleClamshellState`. A lid left open gives a Mac that stays awake for the most ordinary reason there is, clean counters, and a confident PASS - and the architecture would have rested on an experiment in which the thing under test never happened. |
| 9 (read as an attacker, then a red build) | Assume a hostile same-uid process and a shared Mac; then read the CI that failed | **A compile failure reported as a passing step**, because `swift test \| tee log` runs under `bash -e` with no `pipefail` and `tee` decides the exit code. The `macos-26` canary had the same shape in both its steps, so the job whose entire purpose is to go red before a user does was structurally incapable of reporting a failing test. Every green canary before this commit proved only that the runner started. |
| 8 (the spec beside the code) | Read `CRAFT.md` §8 and all fifty antipatterns in §11 against the implementation | **Three of the five Settings controls had no help text at all.** The tooltip and the spoken explanation were attached behind `as? NSButton`; a segmented control and two pop-ups are not buttons, and one call site handed the cast a stack view, which could never match. The two silent rows were the battery floor and the duration limit - the two settings that decide when this Mac is allowed to stop. The two checkboxes worked, which is why it looked fine. |
| 7 (CI behaving oddly) | A macOS job stopped making progress | **A test that hung instead of failing.** `sun_path` is 104 bytes on macOS and 108 on Linux; the test's socket path fitted only the larger. The listener's `strncpy` truncated and bound elsewhere, `lidwing-notify` correctly refused the over-long path, and `accept()` waited forever. Everything that waits now has a deadline. |
| 6 (code vs the specification) | Read the transitions with `DESIGN.md` open beside them | **On a Mac with no lid, nothing ever concluded that.** `lidState` correctly stays `.unknown` while the lid driver has not reported — but nothing turned that into a decision, so on a Mac mini the state stayed `.unknown` forever and the user could turn Lidwing on and read *"Awake — you can close the lid"*. |
| 5 (running, not reading) | Compile and execute the hook helper | It read stdin non-blockingly, so a payload the caller wrote a moment later was **silently lost** and every Claude Code notification would have arrived with an empty body. The test that proves it needed the race made deterministic first. |
| 1 | Read for correctness | **Critical.** `wingprobe disarm` — the safety valve — called `arm()` on its way through and would have armed the machine it was asked to release. |
| 2 | Read as a running process | A modal dialog spins its own run loop, so the reconcile timer fired underneath one and could stack a second dialog on top. And a verify tick that returned early without stopping its own 10 Hz timer. |
| 3 | Fresh eyes, trace every write | **High.** The Repair button could not clear a bit left behind by a previous process, and reported success. It survived two audits and 135 passing tests because `MockSystem` wrote unconditionally — a mock more permissive than the machine does not test, it reassures. |

Twenty-six rejected findings are recorded with their reasons, and one **corrected** finding: I reported a test suite as missing when it existed under another file, and that mistake cost a red build.

## NEXT

1. `Scripts/perf-gate.sh` has never been run. Every number in it is a budget, not a
   measurement, and `AUDIT.md` says so rather than quoting budgets as results.
2. The real README with the four falsify-us commands and the compatibility table — last, per
   `DECISIONS.md`, and only listing combinations with a green acceptance run.
3. Everything blocked on a Mac: M0, fault injection, the perf gate, the smoke script, and the
   keyboard and VoiceOver pass (H8).
