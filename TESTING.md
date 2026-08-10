# TESTING

Numbers, and the proof that each suite can fail.

**The governing rule.** A suite that has never been seen red is not evidence. Every layer below
records the mutation that turned it red and the observed output, because "no failures" read
from silence is how a green board comes to mean nothing. Empty is never success: no output, a
run that collected zero tests, a skipped job and a tool that returned nothing are all RED.

Last updated: 2026-08-10, at commit `286e0b5` plus the working tree of the same cycle.

---

## 1. Unit — LidwingCore, on Linux

| | |
|---|---|
| Command | `docker run --rm -v $PWD:/src -w /src swift:6.0 swift test` |
| Tests | **309** |
| Failures | 0 |
| Wall clock | 1.3 s |
| Also runs | macOS 15 and macOS 26 in CI, same suite, same count |

Breakdown: StateMachine 40 · ClaudeSettingsPatch and CodexConfigPatch 23 · SafetyPolicy 17 ·
WatchdogPolicy 13 · Ledger and AuditRecord 13 · MenuPresenter 12 · Strings and Translations 12 ·
Uninstall 11 · LogEvent 8 · FirstRunCopy 6 · Version 5 · WingGeometry 5. `LidwingSystemTests`
adds 20 more on macOS only (§2), and `Scripts/test-notify-helper.sh` 15 more against the
compiled binary (§3).

### Positive control — observed, not asserted

The suite went red on its first run, before any of these expectations were adjusted:

```
/src/Tests/.../SafetyPolicyTests.swift:89: error: XCTAssertEqual failed:
  ("degrade(LidwingCore.SafetyWarning.thermalSerious)") is not equal to ("ok")
/src/Tests/.../StateMachineTests.swift:200: error: XCTAssertEqual failed:
  ("degraded") is not equal to ("armed") - one sample is not evidence
Executed 67 tests, with 4 failures (0 unexpected)
```

In all four cases the **code** was right and the **test** was wrong: the policy degrades and
warns the user while the thermal dwell runs, rather than sitting silent. The expectations were
corrected to the true behaviour. That is a real red→green transition on this suite.

Deliberate mutation, run afterwards to confirm the suite catches a real defect rather than only
its own bookkeeping:

| # | Mutation | Defect it simulates | Failures |
|---|---|---|---|
| 1 | `SafetyPolicy.evaluate` returns `.ok` first thing | every guard silently disabled | **21** |
| 2 | `PowerSample.percentage` returns `current` instead of `current * 100 / max` | the raw-mAh bug: a 20 % floor that never fires | **14** |
| 3 | `verifyTick` calls `completeArming()` without reading ground truth | believing a write that returned success while doing nothing | **9** |
| 4 | `releaseMechanism` drops the `weSetTheBit` and desktop-mode guards | invariant I7: clearing a bit powerd owns | **1** |
| 5 | `ClaudeSettingsPatch.install` appends without removing our previous entry | a second hook on every install, and a duplicate notification for every event | **3** |
| 6 | `CodexConfigPatch.install` writes our command without chaining | silently taking away a feature the user already had | **2** |
| 7 | Repair calls `setClamshellSleepDisabled(false)` instead of `repairClamshellState()` | the original defect from audit round 3: the button reports success and changes nothing | **3** |
| 8 | The status-item tooltip returns the menu headline | the defect audit round 8 replaced: hovering an unfamiliar icon restates the state instead of saying what a click does | **1** |
| 9 | A tooltip gains an ending period | copy rules rotting one careless string at a time | **1** |
| 10 | `.degraded` shares the calm armed tooltip | still protecting, but the one signal that a guard is warning is gone | **1** |
| 11 | A Mac that slept while armed reads as ordinarily armed | the failure this product exists to prevent, made invisible | **2** |
| 12 | The new OS build is recorded at launch rather than after a verified arm | claiming the mechanism was re-verified on a build where nothing was ever armed | **3** |
| 13 | The "macOS changed" notice is not cleared after firing | telling the user the same thing on every arm until they mute it | **1** |
| 14 | A first run counts as an OS change | announcing an update to someone for whom Lidwing has never worked once | **3** |
| 15 | Only the marketing version is compared, the build ignored | missing a security update that ships a new kernel and keeps the version | **1** |
| 16 | One sound per chime, no fallbacks | the original defect: a missing system sound silences a chime with no warning | **3** |
| 17 | A chime with nothing available is dropped instead of reported | antipattern 37 exactly: the option remains, the sound does not | **2** |
| 18 | The sound self-check reports success too, on every launch | noise that trains the user to ignore the one real warning | **1** |
| 19 | The failure sound reuses a confirmation sound | a failure that sounds exactly like success | **2** |
| 20 | A fresh install presents the login checkbox already ticked | antipattern 21: registering a login item without asking, with a fig leaf | **2** |
| 21 | `requiresApproval` counts as launching at login | reads as on inside the app, launches nothing at login | **2** |
| 22 | macOS 12 gets the login checkbox anyway | a control that cannot work, where no compliant mechanism exists | **2** |
| 23 | The login item is deregistered after the user is sent to the app | `SMAppService` identifies the item by the app; one already in the Trash cannot deregister itself | **1** |
| 24 | Low Power Mode engages regardless of the user's opt-in | a password prompt and a helper install nobody asked for - the trust property in decision 0010 | **3** |
| 25 | Low Power Mode engages on AC | the agent runs slower and the user saves nothing, because there is nothing to save from a socket | **2** |
| 26 | It writes a value that is already in place | a privileged write that changes nothing and leaves a trace in the user's own `pmset -g custom` | **3** |
| 27 | Restore overwrites a value somebody else changed after us | the app deciding it knows better than the user, in a setting it needed a password to touch | **1** |
| 28 | Unknown hardware reported as accepted | the compatibility table becoming a wish list - the exact thing "there are many different MacBooks" forbids | **13** |
| 29 | Model matching relaxed to a prefix, so `Mac14,3` counts as `Mac14,2` | a different machine with a different thermal envelope, claimed on somebody else's evidence | **3** |
| 30 | The "untested" line goes silent | a claim made by implication, which is the kind this project is least allowed to make | **2** |
| 31 | The twelve-second M0 short form recorded as a full acceptance run | overstating the single piece of real-hardware evidence that exists | **3** |
| 32 | Arming at launch is allowed to prompt | the v0.1.0 crash class returning by the front door, on the path that now runs on every launch | **5** |
| 33 | It arms itself while the machine needs repair | writing on top of a bit somebody else set, instead of standing down | **1** |
| 34 | Foreign holders ignored when deciding to arm | fighting another keep-awake tool for a global, reference-count-free bit | **6** |
| 35 | It arms itself before knowing the Mac has a lid | a Mac mini held awake for the whole duration lease, for a feature it cannot use. Found by auditing my own change, not by a user | **7** |
| 36 | System-owned assertions shown to the user | naming `powerd` and `WindowServer` holds a user can do nothing about | **1** |
| 37 | Display and user-active holds treated as conflicts | a trackpad tickle reported as competing for a closed lid | **1** |
| 38 | A self-releasing `caffeinate` promoted to the headline | the menu bar changing on its own every few minutes, forever, because Claude Code spawns one per command | **1** |
| 39 | Internet Sharing named `configd` | a name that tells the user nothing, in place of the one that tells them what to switch off | **4** |
| 40 | A non-releasing timeout counted as temporary | a hold that never hands the machine back, dismissed as transient | **1** |
| 41 | Idle-sleep and system-sleep holds not distinguished | the one kind that actually does Lidwing's job, ranked equal with the ones that do not | **2** |
| 42 | Refusing to arm because another app holds an assertion | the shipped bug from decision 0013: on a developer Mac running an agent, Lidwing never arms at all | **6** |
| 43 | The other holder hidden behind a battery or thermal line | conflict demoted to a fallback, so the user sees it only when nothing else is wrong | **7** |
| 44 | A self-releasing holder described as a standing one | sending the user hunting for a `caffeinate` that stops existing while they look | **1** |
| 45 | The charger event no longer triggers a re-assert | the powerd stomp survives until the next timer tick, on the most frequent event in the product | **7** |
| 46 | The re-assert stops re-issuing the write | the stomp is never recovered at all | **7** |
| 47 | The reconcile stops recovering a stomp | the second, independent recovery path removed, leaving only the best-effort notification | **1** |
| 48 | A recovered stomp notifies the user | an interruption every time a charger is plugged in, for something already fixed | **1** |
| 49 | An unmeasured counter reads as zero | the shipped defect: `isCleanSoak` could not fail on either of the two numbers it names | **5** |
| 50 | A finished session stops recording the sleeps it observed | every audit record leaves the soak unjudgeable | **2** |
| 51 | A recorded sleep no longer makes a record dirty | the one failure this product exists to prevent, not counted against it | **3** |
| 52 | The diagnostics inventory drops what the app ignores | hiding the very lines that explain why the app said nothing | **4** |
| 53 | An empty machine prints nothing instead of saying so | "nothing was held" and "the read failed" become the same output | **1** |
| 54 | The irrelevant assertions stop being counted | a silent drop, so a reader cannot tell whether the classification lost something | **2** |
| 55 | The idle assertion is dropped with the lid shut | the dangerous direction: the mask alone leaves the idle timer running, so the Mac sleeps on a closed lid | **3** |
| 56 | Dropped while an agent is running | a run dies because the user walked away with the lid open | **2** |
| 57 | A user-requested arm is downgraded like an automatic one | somebody who asked explicitly gets less than they asked for | **1** |
| 58 | It never releases | the behaviour this decision exists to remove: a Mac that never idle-sleeps again | **4** |
| 59 | Releasing the assertion also clears the clamshell mask | an unarmed Mac that still believes it is protected | **2** |
| 60 | It never arms again after a disarm | "install it and it works" true exactly once: after the eight-hour lease, protection never returns on a Mac that stays logged in | **2** |
| 61 | A wake arms against the user's preference | overruling somebody who switched the behaviour off | **2** |
| 62 | The wake arm is allowed to prompt | a dialog on a path that by definition runs with nobody there | **1** |

Each was applied, measured, and reverted; the suite returned to **0 failed** after every one
(168 tests when mutations 1-7 were run, 203 for 8-19, 211 for 20-23, 232 for 24-27, 244 for 28-31, 251 for 32-34, 254 for 35, 272 for 36-41, 278 for 42-44, 291 for 45-51, 295 for 52-54, 304 for 55-59, 309 for 60-62).

Mutation 7 is the one that matters most, because it is not hypothetical: it **was** the shipped
code until audit round 3, and the suite passed with it. The tests that catch it now exist
because the mock was corrected to model a guard the real machine has and the mock did not.

Mutation 53 first went red by **trapping** rather than failing: the test indexed `lines[0]`, so an
empty result crashed the suite and took every other result with it. A crash is a signal, but it is
the wrong one - it turns a single clear failure into a run that reports nothing. The assertions
use `XCTUnwrap` now.

Mutations 36 and 37 were **green on the first attempt**, and that is the finding rather than a
footnote: the owner filter and the kind filter are redundant *for the real fixture*, because every
system process in it happens to hold a display or user-active assertion. Each was masking the
other, so deleting either changed nothing any test could see. Two cases now isolate them - a
system process holding a system-sleep assertion, and an ordinary app holding a display one -
which are the combinations the real machine did not happen to produce.

Mutation 27 needed the code changed before it could be caught at all: the "somebody else changed
it" guard and the "it already equals the original" guard are indistinguishable for a two-valued
setting, so disabling the first one changed nothing any test could see. `writesToRestore` now
decides using the same predicate it reports, which makes the fact told to the user and the action
taken by the code the same thing — and makes the mutation detectable.

**Mutations 4, 8, 9, 10, 13, 15, 23 and 27 are each caught by exactly one test.** They are listed
individually rather than averaged into a comfortable number, because a single test is a single
careless edit away from being the only thing that noticed.

**Mutation 4 is the thinnest, and it is worth saying so.** Exactly one test
(`testWeNeverClearTheBitInAConfigurationPowerdOwns`) stands between that change and shipping,
which means a careless edit to that single test would remove the only guard on an invariant
whose failure mode is *sleeping somebody else's lid-closed Mac in the middle of their work*.
Broadening that coverage is on the list in §6.

---

## 2. Unit — LidwingSystem, on macOS

| | |
|---|---|
| Command | `swift test` on `macos-15` |
| Tests | **33** (`ControlSocketTests` 6, `NotifyServerTests` 9, `StorageTests` 9, `IntegrationInstallerTests` 9) on top of the suite shared with Linux |
| Covers | the control-socket wire format, an `AF_UNIX` loopback, socket permissions, the ledger's temp-file-plus-`rename` write, the audit log's append and read-back |
| Cannot cover | anything needing a lid, a battery, a real power event, or a window server (§5) |

### Positive control

`testLoopbackDeliversLines` asserts `count > 0` on the read **before** decoding, precisely so a
socket that delivers nothing fails instead of decoding an empty buffer into a nil that a
weaker test would have skipped over.

---

## 3. The notify helper, measured

`lidwing-notify` runs inside somebody else's tool, on their critical path, possibly hundreds of
times a session. Its contract is about **timing and exit codes**, which no test of the
surrounding Swift can check — so it is tested by running it. It is plain POSIX C, so this runs
on Linux as well as macOS and is part of the ordinary pre-push gate.

| | |
|---|---|
| Command | `./Scripts/test-notify-helper.sh` |
| Assertions | **15**, 0 failed |
| Binary size | **12 528 bytes** |
| Warnings | none, at `-Wall -Wextra -Werror` |
| **Time with no listener** | **4 ms** (budget 150 ms) |
| Readiness | The listener now writes a `.ready` flag **after** `listen()`, and the script waits for that rather than for the socket file, which appears one call earlier at `bind()`. Removes a microsecond-wide connect-refused window. **No positive control**: deleting the signal leaves the suite green, because the five-second wait loop times out and proceeds by which point the listener is accepting anyway. It removes a race; it is not proven to. |
| Flake fixed | The slow-writer case delayed the payload 50 ms against the helper's **100 ms** budget - a 2x margin, which a loaded CI runner overran for real in run 31427570805. Now 10 ms, and it retries: a non-blocking read loses the payload on *every* attempt, so retrying cannot hide the defect. Verified by restoring the non-blocking read - it failed all three attempts. |

The no-listener case is the one that happens most, because the app usually is not running. Exit
code 2 is a *blocking* error in Claude Code and would stall the user's agent, so the only
acceptable answer is `0`, fast. Also asserted: a 20 KB payload, binary input, and an unset
`HOME` all still exit 0; the chained command really does run, with its own argument; and the
message is one newline-terminated version-tagged line.

### The defect it found

The helper read stdin non-blockingly. The caller writes the payload to a pipe and the helper can
start first, so the read returned `EAGAIN` and **silently lost the body** — the notification then
arrived empty, looking as though the agent had nothing to say.

The first version of the test could not tell the two implementations apart, because on this
machine the shell happened to write before the child ran. Making the race deterministic (delay
the write by 50 ms) turns it into a real positive control:

```
with select():        ok    a payload written 50ms late still arrives      SUMMARY pass=15 fail=0
with non-blocking:    FAIL  lost a payload ... {"v":1,"src":"claude","body":""}   pass=14 fail=1
```

`select` with the same 100 ms budget keeps the hard bound on how long the helper can cost the
user's agent, and actually gets the data.

---

## 4. Static gates

| Gate | Command | Result | Positive control |
|---|---|---|---|
| Core purity | `./Scripts/check-core-purity.sh` | pass, 22 files scanned | Inserting `import AppKit` into `Sources/LidwingCore/Version.swift` produced `FAIL: LidwingCore imports a platform-specific framework` and exit 1; removing it returned exit 0. Transcript below. |
| Warnings as errors | `swift build -Xswiftc -warnings-as-errors` | pass | Seen red repeatedly during development; the flag is not decorative. |
| Lint | `swiftlint lint --strict` | **0 violations in 138 files** | Seen red at 42, then 10, then 2 violations across successive fixes in this session. |
| Workflow syntax | `actionlint` | pass | Caught red for real: `if: ${{ secrets.X != '' }}` in a step is rejected by GitHub, which produced a run with **zero jobs** and a red tick naming nothing. See §7. |
| Documented numbers | `./Scripts/check-documented-numbers.sh` | pass | Five controls red, one of which was live in the repository: TESTING.md claimed a `StorageTests` file that did not exist, a total of 20 against 27 actual, and a breakdown that summed to 24. |
| M0 verdict logic | `./Scripts/test-m0-verdict.sh` | **16 of 16**, extracted verbatim from `spike/m0-run.sh` | Five controls red by disabling a guard in the real script. One came back green - the "lid never sampled" case was being caught by the percentage guard - so `expect` now asserts on the reason text and each case tests its own guard. |
| Report floors | `./Scripts/test-report-floors.sh` | **8 of 8** | The Mac-only scripts refuse to run on Linux and do not run in CI, so this logic would otherwise ship having never executed. Three controls red, including one that fired the extractor's own "could not find the floor" guard. |
| Modals activate first | `./Scripts/check-core-purity.sh` | pass, 12 call sites | Written after finding the un-activated "already running" alert by hand; it then found a **second** one I had missed in the same by-hand pass. Removing either `NSApp.activate` turns it red. |
| Bundle contract | `./Scripts/check-bundle-contract.sh` | pass | Five controls, each proven red: the watchdog renamed in the build, the helper dropped from signing, a bundle id drifting in a workflow, the constant made unextractable, the agent plist missing from the build. Two of the five failed first time because of defects **in the check** - see `AUDIT.md` round 8. |
| Artifact invariants | `./Scripts/invariants.sh` | **15 of 15 green** on the real artifact, run 31428574074 | Written before the first artifact existed, deliberately. The script now counts its own checks and refuses to report success if fewer ran than the bundle has invariants - and CI proves that guard on every build by running the script a second time with an impossible expected count and requiring it to fail. It cannot be exercised from Linux: there is no `lipo`, `codesign` or `plutil` here, so it dies long before reaching the guard. |

```
$ sed -i '1i import AppKit' Sources/LidwingCore/Version.swift
$ ./Scripts/check-core-purity.sh; echo "exit=$?"
Sources/LidwingCore/Version.swift:1:import AppKit
FAIL: LidwingCore imports a platform-specific framework (above).
exit=1
$ git checkout Sources/LidwingCore/Version.swift
$ ./Scripts/check-core-purity.sh; echo "exit=$?"
core purity OK (11 files scanned)
exit=0
```

The script also refuses to pass when it scanned no files at all, so a rename that empties its
search path fails loudly instead of quietly reporting success.

### Measured on the first packaged artifact

```
archs: x86_64 arm64
ok    universal: both arm64 and x86_64 slices present
ok    minos 12.0 on both slices (found 2)
ok    concurrency runtime is hard-linked, not weak
ok    Resources/lidwingd is universal
ok    Resources/lidwing-notify is universal
ok    signature verifies (deep, strict)
ok    LSUIElement is true (menu-bar only, no Dock icon)
ok    LSMinimumSystemVersion is 12.0
ok    a second instance is prohibited
ok    CFBundleVersion is zero-padded to ten digits (got '0000000011')
ok    Info.plist declares no *UsageDescription keys
ok    no network-client entitlement
ok    the bundle declares no entitlements at all
```

`dist/Lidwing-0.0.0.dmg`, SHA-256 `19727480d72584c0…`. Ad-hoc signed: Gatekeeper will refuse it
until the Developer ID exists, and `INSTALL.md` says exactly what that costs a user.

---

## 5. Load and stress

| Test | Scale | Result |
|---|---|---|
| `testOneThousandArmDisarmCyclesLeaveNoResidue` | 1000 full arm→verify→disarm→verify cycles | ground truth stock at the end, `weSetTheBit == false`, zero leaked assertions, no ledger left behind, watchdog disconnected. 64 ms. |
| `testRandomEventSequencesNeverLeaveUsArmedWithoutTheBit` | 200 runs × 60 events, deterministic PRNG, with the world perturbed between events (AC flips, thermal transitions, battery jumps, watchdog failures, mechanism failures) | the invariant held on all 12 000 transitions. 73 ms. |

The property test asserts two things after **every** event: protecting implies we own the
mechanism, and quiescent implies we hold nothing. A seeded `SplitMix64` means a failure
reproduces exactly rather than "sometimes".

---

## 6. What none of this proves, and where it will be proved

CI has no lid, no battery, no real power events and no Aqua session. In particular:

* whether a Mac stays awake with the lid physically closed — **`docs/M0-spike.md`**, on Denis's
  MacBook, and nothing else on Earth can answer it;
* `pmset -g stats` deltas across a real sleep;
* whether the status item is visible and legible on a light bar, a dark bar, a translucent bar
  over a bright wallpaper, and on a 16-inch MacBook Pro with ten other items;
* the Gatekeeper first-launch flow;
* thermal behaviour under a real closed-lid load;
* idle CPU and idle wake-ups as measured numbers.

Every one of those is an item in `docs/human-checklist.md` with the exact command and the
expected observation. None of them is claimed here until it has been run.

---

## 7. Still to build

Named so that their absence is visible rather than implied:

- Fault injection against the real binaries: `kill -9` while armed, a dirty ledger, a corrupt
  ledger, reboot while armed. The logic is unit-tested; the *processes* are not yet.
- A soak measuring the app's own memory, file-descriptor growth and idle CPU as hard numbers.
- The compatibility matrix run.
- The uninstaller, and the before/after diff that proves it left nothing.
- A second, independent test of invariant I7 (see mutation 4 above).
- The file-writing half of the config patchers: backup, `fchmod` to the original mode, temp
  file in the same directory, `rename(2)`. The *transformations* are tested exhaustively; the
  I/O around them is not yet.

---

## 8. The rule this regime keeps re-learning

**A test that passes against the bug it was written for is not a test.**

It has now happened twice in different forms. The notify-helper test passed against both the
broken and the fixed implementation until the race was made deterministic. The Repair test
passed against a button that did nothing, because the mock was more permissive than the
machine. In both cases the suite was green, the count went up, and the evidence was worth
nothing.

The habit that catches it: after writing a test, break the thing it covers and watch it go red.
Every mutation in §1 and the two controls in §3 exist because that habit found something.

---

## 9. Failures this regime has already caught

Recorded because a test regime's value is what it stopped, not what it asserts.

| What | How it would have shipped | Caught by |
|---|---|---|
| `if: ${{ secrets.MACOS_CERT_P12 != '' }}` in a step | GitHub rejects the workflow and runs **zero jobs**, reporting failure with no job, no log and no annotation. The signing path would simply never have run, and the red tick would have looked like flakiness. | `actionlint`, now part of `Scripts/check.sh` |
| The CI test-count assertion read the **first** `Executed N tests` line | It asserted on 13 tests out of 79 — a suite could have lost 80 % of its coverage and still passed the guard that exists to prevent exactly that | reading the log rather than the exit code |
| `IOPMCopyAssertionsByProcess()` used as if it returned a dictionary | It answers through an out-parameter. The idle-assertion verification would not have compiled — but the same shape of mistake in a function that *does* return an optional would have silently reported "we hold no assertion" forever | the macOS compiler in CI |
| `wingprobe disarm` called `arm()` on its way to disarming | The safety valve, the command a user runs when they think their Mac is stuck awake, would have **armed** it | reading the code back before shipping it |
| `lidwing-notify` read stdin non-blockingly | Every notification from Claude Code would have arrived with an empty body, looking like the agent had nothing to say | running the binary, then making the race deterministic so the test could tell the two versions apart |
