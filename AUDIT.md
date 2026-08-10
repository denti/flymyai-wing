# AUDIT

Adversarial passes over this codebase, including findings that were rejected and why.

**The question that governs every round:** *can this app leave a Mac that will not sleep, with
the user not knowing why?* If the answer is ever not a hard no with a mechanism behind it,
everything else stops until it is.

---

## Round 1 — 2026-08-10, after the first end-to-end green build

Scope: the whole tree at commit `286e0b5`. Method: read every file as if I had never seen it,
enumerate the states the spec says must be handled, and try to reach a bad one.

### The governing question, answered

A Mac can be left unable to sleep on lid close only if `clamshellSleepDisableMask` stays set
with nobody left to clear it. Four things have to fail at once for that:

1. **The process dies.** Covered by `lidwingd`: the app is the *client*, so any death —
   including `SIGKILL`, which runs no handler — closes the socket and the watchdog sees EOF in
   milliseconds. `StateMachine.onUserArm` refuses to arm at all if the watchdog cannot be
   connected first (`testArmIsRefusedWithoutADeadMan`).
2. **The watchdog dies too.** Its plist carries `KeepAlive`, so launchd restarts it, and
   `reconcileAtStartup` reads the marker written at arm time. A marker from *this* boot with no
   client inside ten seconds triggers recovery.
3. **Both die and the machine stays up.** Not covered by software. Covered by the mechanism:
   the mask is a kernel variable initialised to zero in `IOPMrootDomain::start()`, so a reboot
   clears it unconditionally. This is the argument for Tier 1 that no amount of daemon
   engineering could replace, and it is why decision 0002 went the way it did.
4. **The user never finds out.** `recovered.json` is written by the watchdog and read by the
   app at the next launch, so the explanation survives the death of the process that noticed.

**Answer: a hard no, with four independent mechanisms, and the last one does not depend on our
code running at all.**

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 1.1 | `wingprobe disarm` — the safety valve a user runs when they believe their Mac is stuck awake — called `Armer.arm()` on its way through, because of a nonsense `guard … == false \|\| true` that always succeeded. It would have **armed** the machine it was asked to release. | **Critical** | Added `Armer.forceClear()`, which opens the user client and writes zero without ever setting it. |
| 1.2 | The CI assertion guarding against an empty test run read the **first** `Executed N tests` line, which is the first suite's count. It reported 13 of 79 and passed. A change that dropped 80 % of the suite would have sailed through the check that exists to catch exactly that. | High | Read the last line, which is the run total. |
| 1.3 | `if: ${{ secrets.MACOS_CERT_P12 != '' }}` in a step is rejected by GitHub outright: the run produces **zero jobs** and a red tick that names nothing. Copied from the design document, which is wrong about it. | High | Lift the secret into `env` and test that. `actionlint` is now the first thing `Scripts/check.sh` runs. |
| 1.4 | `IOPMCopyAssertionsByProcess` was called as if it returned the dictionary; it answers through an out-parameter. Caught by the compiler here, but the same shape of error against a function that *does* return an optional would have silently reported "we hold no assertion" forever. | Medium | Wrapped in `assertionsByProcess()`, one call site, checked return code. |
| 1.5 | `SystemObservers.stop()` called `NotificationCenter.removeObserver(self)` for a block-based observer, which does not remove it. The thermal observer would have outlived `stop()`. | Medium | Keep the token and remove that. |
| 1.6 | The chime fired on the arm click. `CRAFT.md` is right that this is backwards: the user is looking at the menu they just clicked, and a sound there trains them to mute the app, after which the sound that matters never lands. | Medium | The chime now fires on **lid close while protecting** and on **standing down while the lid is closed** — the two moments the screen is not an output channel. Recorded as decision 0008; tested by `testClosingTheLidWhileArmedChimesExactlyOnce`. |
| 1.7 | The lid-close chime would have fired on every charger plug: `kIOPMMessageClamshellStateChange` also fires for `kIOPMSetDesktopMode`, `kIOPMSetACAdaptorConnected`, `kIOPMEnableClamshell` and `kIOPMDisableClamshell`, and arrives twice per transition. | Medium | Diff the lid state instead of counting notifications. The test asserts silence on the repeat, on a bare clamshell notification, and on a power-source change. |

### Findings, rejected

| Finding | Why it was rejected |
|---|---|
| "The watchdog should clear the bit unconditionally on any doubt — it is the safe direction." | It is not. Bit `0x02` is shared with powerd and carries no reference count. In the one configuration where powerd legitimately owns it (external display on AC), an unconditional clear puts *somebody else's* lid-closed Mac to sleep in the middle of their work. Both the app and the watchdog obey the same rule, and the watchdog logs when it stands down rather than acting. |
| "`assertionFailure` in `assertInvariants` will crash release builds." | It compiles to nothing in release. The audited record next to it is what carries the information in a shipped build, and that is deliberate: a menu-bar app that traps is worse than one that records and keeps protecting. |
| "The 60-second thermal dwell is too slow; `DESIGN.md` says disarm immediately." | Kept at 60 s, recorded as decision 0005. `ProcessInfo.thermalState` reads `.critical` transiently on a healthy machine during a heavy link step, and disarming on the first sample ends the overnight run the user installed this to protect. The kernel's own thermal emergency sleep is still armed underneath us the whole time — the clamshell mask does not touch `checkSystemSleepAllowed()`. We are the first line, not the only one. |
| "Sound should be off by default; it is a menu-bar utility." | Denis asked for audible confirmation on lid close explicitly, and the accessibility argument is stronger than the taste argument: with the lid shut, audio is one of the only two channels left. It stays on, and it stays limited to the two moments the screen cannot speak. |
| "The app should re-arm silently after a `SLEPT_WHILE_ARMED` failure rather than showing a failure state." | It re-arms, and it still records the failure and tells the user with the timestamp. Silent re-arming would mean a green icon that has already been wrong once, which is the exact failure this product cannot afford. |

### What this round could not check

Everything requiring the machine: a physically closed lid, a real power event, a real thermal
excursion, the status item's legibility, and the Gatekeeper flow. Those are `docs/M0-spike.md`
and `docs/human-checklist.md`, and none of them is claimed as done anywhere in this repository.

**Round 1 verdict:** one critical defect found and fixed, in a tool whose entire purpose is
safety. Two more that would have made the CI signal meaningless without looking broken. That
ratio is the argument for doing this again before, not after, the first user.


---

## Round 2 — 2026-08-10, against runtime behaviour rather than logic

Round 1 read the code for correctness. This round asked a different question: **what does this
process actually do, second by second, on a machine that is doing nothing?** An app whose
promise is "save your battery" that shows up in Activity Monitor's Energy tab has refuted
itself, and none of the unit tests could have caught any of the following.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 2.1 | The status item was re-rendered on **every** effect delivery, including the five-second reconcile tick — rasterising a bezier path twelve times a minute for a picture that had not changed. | Medium | Refresh only when the presented state actually changes. |
| 2.2 | `StatusIcon.image` allocated and drew a fresh `NSImage` on every call. | Medium | Cached by shape and thickness. Five shapes, one thickness: bounded by construction. |
| 2.3 | `UserDefaults` was written on every event, armed or not, because `hasEverArmed` was assigned unconditionally. | Medium | Assign only on change. |
| 2.4 | `currentPowerSample()` called `PowerSourceReader.read()` three times — `onAC`, `batteryCurrent` and `batteryMax` each copy the entire power-source blob. | Low | One read per pass where the caller needs all three. |
| 2.5 | The reconcile timer was started at launch with a comment saying "guards run whether or not we are armed", and then stopped permanently by the first disarm. The comment was a lie after the first cycle, and the timer was pointless before it: there is nothing to guard while idle. | Medium | Armed-session scoped, and the comment now says what the code does. An idle Lidwing runs no timer at all. |
| 2.6 | **A modal dialog spins its own run loop**, so the reconcile timer kept firing underneath one and could put a second dialog on top. The user would have had to dismiss a stack. | Medium | One modal at a time, enforced by a flag on the only path that presents them. |
| 2.7 | `NSAlert().runModal()` ran before `NSApplication.shared` existed, on the "already running" path. Touching `NSApp` implicitly from a static context is a launch-time crash waiting for the one user who double-clicks twice. | Medium | The application is created first. |
| 2.8 | `onVerifyTick` returned early when it had no deadline, without stopping the timer. Unreachable today, but the failure mode is a **10 Hz timer running for the life of the process** — the single worst thing this app could do to a battery. | Medium | No deadline stops the timer. |

### Findings, rejected

| Finding | Why |
|---|---|
| "Cache `foreignAssertionHolders`; `IOPMCopyAssertionsByProcess` is not free." | It is called when the menu is built, which is when a human is looking, and once per reconcile tick during an armed session. Caching it would mean showing a stale answer to the question *who else is keeping this Mac awake* — which is precisely the question a suspicious user opens the menu to ask. Measure it in `perf-gate.sh` first; optimise only if the number says so. |
| "Coalesce the reassert and reconcile timers into one." | They have different periods for different reasons: re-assertion is a write that must beat powerd's clearing of the bit, reconciliation is a read that decides whether to end the session. One timer at the faster period would double the wake-ups; one at the slower would weaken the mechanism. |
| "The 100 ms verify timer is too fast." | It exists for at most two seconds per transition and it is the only thing standing between "the API returned success" and "the machine agrees". Its cost is bounded by construction; the leeway is 20 ms because 2 s is the entire budget it has to work in. |

### Still not measured

Every number in `perf-gate.sh` is a budget, not a measurement: idle CPU, idle wake-ups,
resident memory, descriptor growth. The script exists and has never been run, because running
it needs a Mac with the app installed. That is `docs/human-checklist.md`, and until it happens
this section says **unmeasured** rather than quoting the budgets as if they were results.

**Round 2 verdict:** no correctness defects, eight efficiency and robustness ones, and the two
that matter most (the never-stopping fast timer, the stacking modals) were reachable only by
reading the code as a running process rather than as a set of functions.


---

## Round 3 — 2026-08-10, fresh eyes, and one bug the tests were built to miss

Method: read the tree as if I had never seen it, then trace every path that can write to the
machine and every path that can read from it. No prior knowledge of what any file was for.

### The finding that matters

**The Repair button could not work, and the test suite said it did.**

Repair exists for exactly one situation: a *previous* Lidwing process left the clamshell bit
set — it crashed, or the Mac was force-restarted — and the running process finds a non-stock
machine at launch. It offers to put it back.

The implementation called `setClamshellSleepDisabled(false)`, which routes through
`ClamshellLock.safeRelease`, which begins:

```swift
guard weSetTheBit else { return KERN_SUCCESS }
```

That guard is invariant I7 and it is **correct** — every automatic path must refuse to clear a
bit this process did not set. But Repair is the one path whose entire purpose is to clear a bit
this process did not set. So the button would have reported success, written nothing, and left
the user with a Mac that still would not sleep.

**Why every test passed anyway:** `MockSystem` wrote unconditionally. It did not model the
`weSetTheBit` guard at all, so the mock was strictly more permissive than the machine it stands
for — and a mock that is more permissive than reality does not test, it reassures.

Fixed three ways:

1. A separate `repairClamshellState()` on the facade, reachable only from a button the user
   pressed after reading what it does, which skips the ownership guard and keeps the powerd
   one.
2. `MockSystem` now models ownership, so the divergence cannot hide again.
3. `testRepairClearsABitLeftBehindByAPreviousProcess` reproduces the real situation. Positive
   control: restoring the original call makes **3 tests fail**; the fix returns 142/0.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 3.1 | Repair could not clear a bit left by a previous process, and reported success (above). | **High** | A distinct facade method, a mock that models the guard, and three tests. |
| 3.2 | Auto mode's `agentAppeared` and `agentDisappeared` events had no producer. A branch no caller can reach is a stub with better manners. | Medium | Wired: a 15 s scan while Auto is selected, plus the control that turns it on. |
| 3.3 | `MockSystem` did not model the ownership guard (the reason 3.1 survived two audits). | **High** | Modelled, with `simulateBitSetByAnotherProcess()` for the state a crash leaves behind. |

### Findings, rejected

| Finding | Why |
|---|---|
| "Repair should run automatically at launch when the ledger says it was us." | No. A silent clear can stomp powerd, or another keep-awake tool, or a deliberate setting. The reconciliation has exactly three outcomes and two of them are *tell the user something and do nothing*. The one-click button is the whole design. |
| "`fatalError` in `SettingsWindowController.init?(coder:)`" | It is the `@available(*, unavailable)` NSCoder initialiser for a window built entirely in code. Reaching it is impossible; the alternative is an optional that every call site has to unwrap for a case that cannot happen. |
| "The 10-second agent cache in `LiveSystem` violates the read-ground-truth rule (I9)." | I9 is about *our own state* — never trusting a cached belief about whether we are protecting the machine. Which processes exist is not our state, and the read is a full process-table walk. The cache is shorter than the poll that consumes it. |

### The governing question, re-answered after three rounds

*Can this app leave a Mac that will not sleep, with the user not knowing why?*

Still a hard no, and round 3 strengthened it: before this round the **recovery path a user is
told to use** did not work. The other three mechanisms (watchdog EOF, launchd `KeepAlive`, the
kernel zeroing the mask at boot) would still have saved them, but they would have been told to
press a button that did nothing, which is its own kind of lie.

**Round 3 verdict:** one high-severity defect, and it was hidden by a mock that flattered the
code. That is the most useful thing this round found — not the bug, but the reason the bug
survived two previous audits and 135 passing tests.


---

## Round 4 — 2026-08-10, the seams between things that landed in different weeks

Method: for each pair of features that were built at different times, ask what the earlier one
assumed about the later one, and whether that assumption is still true.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 4.1 | **The uninstaller did not remove the coding-agent integrations.** It was written before them, and its step reported *"nothing was ever written"* — which was true when written and became a lie the moment the integrations shipped. Uninstalling would have left Lidwing's hook in somebody's `~/.claude/settings.json`, pointing at a binary that was no longer there. | **High** | The step now calls the real uninstall for every agent, reports which files it touched, and fails the run if any of them could not be cleaned up. Three tests bind the two halves: the agent list and the uninstall surface must match, and the marker the uninstaller matches on must be the one the installer writes. |
| 4.2 | The menu **rows** were still English after the menu **header** was translated, so a Russian user would have seen one language in the header and another in every row under it. The catalogue-coverage test could not catch it: a key nothing reads still passes. | Medium | Every row title goes through the catalogue. Only reading the drawing code finds this class of thing. |
| 4.3 | Settings, the uninstall confirmation and the integration diffs were untranslated — the surfaces where a non-technical user makes the decisions that matter most. | Medium | Translated, and the scope of what deliberately is *not* translated is recorded as decision 0009 rather than left as an accident. |

### Findings, rejected

| Finding | Why |
|---|---|
| "The diagnostics output should be translated too." | Its audience is not the user; it is whoever is helping them, and it arrives pasted into an issue or a message. A Russian diagnostics dump is harder for that person to act on. Recorded as a decision rather than an omission. |
| "Ship the other six languages from the craft spec with machine translation." | I cannot check a translation I cannot read, and these strings say things like *"Lidwing turns off at 20%"*. A mistranslation there means somebody misunderstands when their overnight run will end. The catalogue is keyed by language, so a native speaker can add one as a data change. |
| "`Uninstaller` should delete the third-party config files it edited." | It removes its own entries and leaves every other byte alone. Deleting somebody's `settings.json` because we once added a line to it would be the single most destructive thing this product could do. |

### The pattern worth naming

Every finding in this round is the same shape: **feature A was correct when written, and feature
B made it wrong without touching it.** None of them is visible from inside either feature, and
no test suite that grows alongside the code catches them, because each test was written when its
own assumption was still true.

The defence is not more tests of the same kind — it is a test that binds the two features
together and lives in the module where both are visible. `testEveryThirdPartyFileWeCanWriteIsInTheUninstallSurface`
is that shape: it fails when somebody adds an agent without adding it to the removal path,
which is exactly how 4.1 happened.

**Round 4 verdict:** one high-severity defect, in the uninstall path, found by asking what an
old feature assumed about a new one rather than by reading either of them.


---

## Round 5 — 2026-08-10, running the binaries and walking the worst path

Two methods this round. First: compile and **execute** the one component whose contract is
timing rather than behaviour. Second: walk the sequence a user meets after the worst thing this
product can do, one state at a time, and ask what they can see at each step.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 5.1 | **`lidwing-notify` read stdin non-blockingly.** Claude Code writes the payload to a pipe and the helper can start first, so the read returned `EAGAIN` and the body was **silently lost** — every notification would have arrived empty, looking as though the agent had nothing to say. | **High** | `select` with the same 100 ms budget: the hard bound on how long we can cost the user's agent is unchanged, and the data actually arrives. |
| 5.2 | **The menu forgot that the Mac had slept.** After a `SLEPT_WHILE_ARMED` failure the app re-arms itself, and the header went back to a plain "Awake — you can close the lid". Both known holes in the mechanism have the same precondition — the machine must sleep once first — so the first sleep is the single most important thing about that session, and it vanished from the only persistent surface the product has. | **High** | An armed session with any observed sleep shows `Your Mac slept at 03:12` with `Protection is back on. See Diagnostics.`, and keeps the checkmark, because both facts are true at once. |
| 5.3 | A translocated app would have refused to arm with *"Lidwing could not start its safety watchdog"* — true, and useless: the fix is to drag the app out of Downloads and nothing in that sentence says so. | Medium | Checked before the state machine sees the request, with the specific message. |

### The positive control that had to be built first

The first version of the notify-helper test could not tell the fixed and broken implementations
apart, because on this machine the shell happened to write to the pipe before the child ran.
The test passed either way, which makes it worthless as evidence.

Delaying the write by 50 ms makes the race deterministic, and only then is it a real control:

```
with select():        ok    a payload written 50ms late still arrives      pass=15 fail=0
with non-blocking:    FAIL  lost a payload ... {"v":1,"src":"claude","body":""}   pass=14 fail=1
```

That is worth naming as a general rule: **a test that passes against the bug it was written for
is not a test.** Where timing is the defect, the test has to control the timing.

### Findings, rejected

| Finding | Why |
|---|---|
| "After re-arming, clear the failure once the session has been clean for an hour." | No. The audit record for the session already says a sleep happened, and the menu should agree with it. A UI that quietly forgets a failure is how a user concludes the product is fine when it is not. It clears when the session ends, which is the honest boundary. |
| "Require `/Applications`, as the design document says." | That is a hard requirement for a **daemon** that must run before login. This is a user agent, and `~/Applications` is an ordinary place to keep an app. Refusing to work there would be enforcing somebody else's rule on ourselves. Translocation and `~/Downloads` are refused, because those genuinely break a launchd path. |

**Round 5 verdict:** two high-severity defects, and neither was reachable by reading. One needed
the binary run with controlled timing; the other needed walking a five-step sequence and asking
what the user can see at step four.


---

## Round 6 — 2026-08-10, reading the transition table against the specification

Method: read `StateMachine+Transitions.swift` line by line with `DESIGN.md` §3.3 and §4g open
beside it, and check each state the specification names against the code that is supposed to
reach it.

### The finding

**On a Mac with no lid, Lidwing would have offered to protect it.**

`RootDomain.lidState` returns `.unknown` when `AppleClamshellState` is absent and no clamshell
notification has been seen — which is correct, and deliberately so: the key is absent on a
*laptop* too until the lid driver makes its first report, and coercing that to "no lid" would
disable the product at every login. The specification is explicit about it.

What was missing is the other half: **nothing ever concluded the absence.** On a Mac mini no
clamshell notification ever arrives, so `sawClamshellNotification` stayed false forever,
`lidState` stayed `.unknown` forever, and `.unknown` is not `.noLid` — so the refusal check
never fired. The user could turn Lidwing on and read *"Awake — you can close the lid"* on a
machine with no lid to close.

Not dangerous: the clamshell mask does nothing on a desktop and the idle assertion is harmless.
But it is the product lying about the one thing it does, and `DESIGN.md` A8.3 asks for the
opposite — the feature **hidden**, not merely disabled.

Fixed with the ten-second grace period the specification names: absent *and still silent after
ten seconds* is evidence, and the conclusion is **reversible** — a clamshell notification
arriving later (a slow driver, unusual hardware) puts the machine back into the ordinary flow.
Four tests, including one asserting the probe can never end a session that is already
protecting.

### Findings, rejected

| Finding | Why |
|---|---|
| "Conclude no-lid immediately when the key is absent at launch." | This is the mistake the specification warns about by name. The key is absent on a laptop until the lid driver reports, and a Lidwing that disables itself at every login is worse than one that waits ten seconds. |
| "Probe by arming and seeing what happens." | Never. The runtime probe reads; it does not write. Arming to find out whether arming works is exactly the class of thing this product refuses to do to somebody's machine. |

### Two more from the same read

| # | Finding | Severity | Fix |
|---|---|---|---|
| 6.2 | **A failed recovery stood down in silence.** After a sleep while armed, the app tries to protect the machine again; when that fails too it went back to `idle` with no sound and no notification. The user had gone to sleep expecting an eight-hour run that was now over — the quietest possible way to lose somebody's night of work. | Medium | It chimes and names the reason. A test also pins that the audit record still carries the sleep: `reason=watchdog_lost` with `ground_truth_failures=1` and `isCleanSoak` false, so the record cannot describe the session as clean because the *last* thing that happened had a different name. |
| 6.3 | `WatchdogClient.connect()` ran `launchctl bootout` and `bootstrap` on every failed attempt. Bounded in practice, but hammering launchd is a worse failure than standing down. | Low | A five-second cooldown. If it did not work a moment ago it will not work now. |

**Round 6 verdict:** one medium defect from reading the code against the specification rather
than against itself — the specification described a state, *no lid*, that the code had a name
for and no path to — plus two more from walking the same file's error paths.


---

## Round 7 — 2026-08-10, a test that hung instead of failing

Not a planned round. The macOS CI job stopped making progress on the step that runs the
notify-helper tests, and a job that hangs is the worst possible outcome: it burns to its timeout
and reports nothing at all.

### The finding

**`sun_path` is 104 bytes on macOS, and the test's socket path did not fit.**

The socket lives at `$HOME/Library/Application Support/Lidwing/notify.sock` — forty-five
characters before the home directory even begins. The test set `HOME` to `mktemp -d`, which on
macOS returns something like `/var/folders/xx/…/T/tmp.XXXXXXXX`, and the total blew the limit.

The failure mode is the interesting part, because the two sides disagreed **silently and in
opposite directions**:

* the listener used `strncpy` into `sun_path`, which **truncates**, so it bound to a different
  address than the one it was asked for and waited for a client there;
* `lidwing-notify` checks the length and **declines to connect** — correctly — so no client ever
  arrived;
* `accept()` blocked forever, and the CI job sat there until its timeout.

On Linux the limit is 108 and the same path fitted, which is why it passed locally every time.

Fixed three ways, because any one of them alone leaves the trap set for the next person:

1. The test uses a short working directory (`/tmp/lw$$`) and **prints the path length in every
   run**, so the constraint is visible rather than remembered.
2. The listener **refuses** a path that would be truncated instead of binding to a different
   address.
3. The listener sets a ten-second `alarm`, so a hang becomes a reported failure.

Positive controls for all three, run with a deliberately over-long path:

```
note  socket path is 114 chars (sun_path holds 103 on macOS, 107 on Linux)
FAIL  the socket path is too long for macOS - this test would hang there
FAIL  the socket path was too long for sun_path
SUMMARY pass=9 fail=4
```

### The rule

*Empty is not success* has a sibling: **a hang is not a pass, and it is worse than a failure.**
Anything in this project that waits on another process now has a deadline, because the failure
mode without one is a green-looking job that never finished and a person who has to guess why.

### And a gate that should have existed from the start

The shell scripts are a large part of this product — the M0 experiment, the fault injection, the
performance gate, the smoke test — and every one of them runs on a machine I cannot debug.
macOS ships bash 3.2; this box has 5.x.

`shellcheck -S warning` over all of them found four things on its first run. Two were real:
`[ cond ] && ok "…" || bad "…"` written as if it were if-then-else. In a **test** script that is
a genuine hazard, because a spurious `C` prints a failure that did not happen — and a test that
can report a failure it did not observe is worse than no test at all. It is now part of both the
local gate and CI, and it has been seen red.

**Round 7 verdict:** one defect in the test infrastructure, found by CI behaving oddly rather
than by CI going red — and it was only ever going to appear on the platform the product
actually ships to. Plus a whole category of script defect that nothing had been looking for.

---

## Round 8 — 2026-08-10, the specification beside the code

Scope: `CRAFT.md` §8 (accessibility) and §11 (the fifty-item antipattern list), read line by
line against the implementation, plus the packaging scripts against the runtime.

The method is the least clever one available: open the specification and the code side by side
and check each claim. It is also the most productive round so far, which says something
uncomfortable — six earlier rounds read this code for correctness and none of them read it
against the document that defines what "done" means for the visible surface.

### The governing question, answered

Unchanged, and untouched by this round: none of these findings can leave a Mac unable to sleep.
They are all failures of the second promise rather than the first — the product telling the
user something that is not true, or failing to tell them something that is. Which is why they
are worth a round: a mechanism nobody can hear, see or verify is not a mechanism anyone can
trust.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 8.1 | **Three of the five Settings controls had no help text and no tooltip.** `withExplanation` attached both behind `if let control = view as? NSButton`. `NSSegmentedControl` and `NSPopUpButton` are not `NSButton`s, and `row()` made it worse by wrapping the control in a stack view and handing *that* to the cast, which could never match. The two rows built that way are the battery floor and the duration limit — the two settings that decide when this Mac is allowed to stop. The two checkboxes worked, which is exactly why nobody noticed. | High | Attach to any `NSControl`, before wrapping. The visible label is now set on the control itself: without it a pop-up reached by Tab or VoiceOver announces "20 per cent" with no hint of what it governs. |
| 8.2 | **Nothing subscribed to `accessibilityDisplayOptionsDidChangeNotification`.** `refresh()` read Increase Contrast correctly — but it only runs on a state change, and this app is designed so the state does not change while nothing is happening. A user who turned the accommodation on while Lidwing sat idle kept the dimmed glyph for the rest of the session. The spec says "read live, never once at launch"; the code read it live and then never looked again. | Medium | Subscribe, and re-render on every fire. |
| 8.3 | **`flash()` ignored Reduce Motion**, blinking the status item six times at 4 Hz. | Medium | Under Reduce Motion it highlights once and holds. Not silence: `flash()` is the recovery path for someone who relaunched from Finder and cannot find the icon, and Reduce Motion means do not move, not give this user no feedback. |
| 8.4 | **The status-item tooltip was the menu headline**, so hovering an unfamiliar icon said "Off - your Mac sleeps normally". The glyph carries the state and so does `accessibilityValue`; a tooltip appears before the click and should say what will happen. | Low | One tooltip per state, verb first, no ending period, in both languages. Tested in the portable module. |
| 8.5 | **The Settings window opened with focus on nothing** (§8.4). | Low | `initialFirstResponder` on the mode control. |
| 8.6 | **Antipattern 38 — break after a macOS update and stay broken silently.** Nothing stored or compared the OS build. This product rests on one undocumented `IOPMrootDomain` selector, so it is a worse candidate for this failure than Rectangle or Ice, and its failure mode is the quiet one. | High | Remember the build on which an arm last *verified*, notice at launch when it differs, and let the next verified arm report it. Deliberately **no** launch-time probe: `clamshellCausesSleep` and `sleepDisabled` are both `Bool?` where nil legitimately means "key absent", so absence proves nothing, and the only real proof is arming — which this product does not do unasked. |
| 8.7 | **Antipattern 37 — a feature silently rotting.** `ChimePlayer` named one system sound per chime and returned silently if the file was absent. No log, no warning, sound checkbox still in Settings. Worse here than in the app whose review named it: with the lid shut, sound is the **only** channel, so a rotted chime takes the lid-close confirmation with it and the user finds out by opening a laptop that slept three hours ago. | High | Fallbacks per chime, a self-check that names what is missing (in Settings only when wrong, in diagnostics always — "Sound  ok" rules out a theory for someone who cannot see the machine), and a Play button that plays even when the sound preference is off, because the question it answers is "does this work on my Mac". |
| 8.8 | **The build script, the signing script and the runtime named the same files in three unconnected places.** A rename on one side ships an app that launches, shows a menu, arms — and has no watchdog, the one component whose absence means a `kill -9` strands the machine until reboot. | Medium | `Scripts/check-bundle-contract.sh`, five positive controls, in the gate and in CI. |
| 8.9 | **My own CI break**, included because it belongs in the record: `log.emit(.osChanged, …)` compiles nowhere — leading-dot lookup resolves against `LogEvent` and those events are static members of `LogCatalogue`. The local gate passed because **none of the Darwin targets compile on Linux**, which makes CI their only compiler and a six-minute round trip the price of every typo in them. | Medium | Fixed, plus a grep for this shape. The first version of that grep also matched `Observers.emit(.thermalChanged)` — a different and entirely correct method — and a check that fires on correct code gets switched off within a week, so it is anchored on the log receiver. |

Two of the findings above were in checks I wrote *this round*, caught by their own positive
controls: `check-bundle-contract.sh` aborted at the failing `grep` under `set -e` and exited 1
having printed nothing (a crash, not a finding), and its workflow comparison was an unanchored
substring match, so `ai.flymy.lidwing` matched `ai.flymy.lidwing2` and the drift control passed.
A check whose positive control is not run is a decoration.

### Findings, rejected

| Finding | Why it was rejected |
|---|---|
| "Antipattern 8 — Differentiate Without Color needs handling for the WARNING state." | Already satisfied structurally, not by luck: every glyph is a template image, and template images cannot carry colour at all. The degraded state is a *shape* difference — solid wing plus a warning dot — and the menu's status line carries the same information in words. Adding a code path for a flag we already satisfy would be a code path nobody could ever see fail. |
| "The self-check should confirm sound works on every launch, in the UI." | It reports in the UI only when something is wrong. A check that announces success on every launch is noise, and noise is precisely how the one real warning gets ignored six months later. Diagnostics is the exception, because it is read by someone who cannot see the machine. |
| "`OSChangeWatch` should compare only the marketing version — a build bump is not a real change." | The opposite. A security update keeps the marketing version and changes only the build, and that update can ship a new kernel. Deciding what counts as "different enough" would be inventing a rule Apple never agreed to. |
| "Add a launch-at-login checkbox while in the Settings window." | Out of scope for a round whose job was to check the spec against the code, and antipatterns 21–23 make it a feature with real requirements (never default-on, never a cached boolean, `SMAppService` only). It goes on the list as work, not as a fix smuggled into an audit. |
| "The tooltip should also state the battery percentage, since the menu does." | A tooltip that changes every few minutes is a tooltip nobody reads twice. State that moves belongs in the menu, which is rebuilt on every open; the tooltip carries what will happen if you click. |

### What this round could not check

Every finding above is in AppKit code in an executable target, and CI has no window server. None
of it is red anywhere, and none of it can be: `swift build` on macOS proves it compiles, not
that a focus ring appears or that VoiceOver says anything. That is now `docs/human-checklist.md`
H8, with the exact keys to press, the two controls to check first, and the live Increase Contrast
test — six minutes of someone's attention, on the one part of this product that reading cannot
verify.

### Continued — the rest of the fifty antipatterns

Swept mechanically where a grep could decide it and by reading where it could not. Most entries
were already satisfied, several of them structurally rather than by luck: every glyph is a
template image (8, 10, 32), the status item's `autosaveName` is fixed and its behaviour is not
`.removalAllowed` (11, 12), the menu is real `NSMenuItem`s with no custom views (5, 6, 7), every
timer carries leeway (33), the assertion is named (35), there are zero usage descriptions and
zero entitlements (34, 43), and the window is called Settings with a real ellipsis (26).

Two more findings, both the same antipattern, number 18:

| # | Finding | Severity | Fix |
|---|---|---|---|
| 8.10 | **The "already running" alert was shown without activating.** Lidwing is `LSUIElement`: no Dock icon, no menu bar of its own. That alert opens behind the user's editor, and `runModal` then blocks the process on a dialog they cannot see and cannot dismiss. It is also the worst possible one to lose: its entire audience is a user who double-clicked the app in Finder *because they could not find it*, and what they get is a second invisible process. | Medium | Activate first. |
| 8.11 | **The uninstall result alert relied on the activation from the confirmation before it**, with `Uninstaller.run` in between - which disarms, verifies, rewrites config files and deregisters an agent, all taking real time. A user who clicks back to their editor while it works gets the report behind that editor. It is the report that says whether their Mac was left in a good state. | Low | Activate again immediately before it. |

8.11 was found by the check written for 8.10, not by me: `check-core-purity.sh` now requires an
`NSApp.activate` within fifteen lines of every `runModal()` in the app target. My own by-hand
pass over the same twelve call sites had missed it.

### One more, from CI going red on its own

| # | Finding | Severity | Fix |
|---|---|---|---|
| 8.12 | **A flaky test, on the case that guards the round 5 defect.** The slow-writer case delayed the payload 50 ms against the helper's 100 ms stdin budget. That is a 2x margin, and a loaded macOS runner overran it: the helper correctly gave up, sent an empty body and exited, and the writer's `echo` died with `EPIPE`. The assertion was right and the margin was wrong. A flaky test on the payload-loss defect is worse than most flakes, because the response to a flake is to re-run it. | Medium | 10 ms against 100 ms, and it retries. A non-blocking read loses the payload on *every* attempt, so retrying cannot hide the defect - verified by restoring the non-blocking read, which failed all three attempts. The attempt count is printed, so a degraded machine is visible rather than silently tolerated. |

**Round 8 verdict:** twelve defects, nine of them user-visible, none of them capable of stranding
a Mac. The pattern worth naming: every one of them was invisible to the tests because the tests
check what the code does, and these were all cases of the code doing something perfectly well
for a case that never arrives — a cast that never matches, a notification never subscribed, a
comparison never made.

---

## Round 9 — 2026-08-10, read as an attacker

Scope: the three IPC surfaces and the state on disk. Method: assume a hostile process running
as the same user, and a Mac with more than one account on it.

### The governing question, answered

Nothing here can strand a Mac. The clamshell mask is written only by the state machine, and the
notify socket structurally holds no reference through which it could arm anything (invariant
I8). What is at stake is the second promise: that Lidwing's own record of when this Mac was
awake, and which agent binaries were running, stays the user's.

A same-uid attacker is explicitly **not** a boundary this product can defend - a process running
as you can already read your files, and macOS defends that line with TCC and the App Sandbox,
neither of which Lidwing uses or relies on. The boundary that *is* real is other accounts on the
same Mac, and that is the one these findings are about.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 9.1 | **The state directory's mode was set once and never checked again.** `ensure()` returned as soon as the path existed, so a directory that arrived any other way kept its mode forever - restored from a backup that lost it, migrated by Setup Assistant, created by an earlier build, or made by hand. `createDirectory` neither corrects an existing directory nor complains about one. Inside it: the ledger, the audit log of when this Mac was awake and which agent binaries ran, and both sockets. | Medium | Verify and repair on every launch. The rule is "grants nothing to group or other" rather than "is exactly 0700", so bits it has no opinion about survive and it does not re-chmod a private directory forever. |
| 9.2 | **`fileExists` follows symlinks**, so a symlink pointing anywhere at all reported a perfectly good state directory. | Medium | `lstat`, and refuse. A symlink is not something that can be repaired, and the honest answer is to decline rather than write the ledger somewhere the user did not choose. A plain file in that position is refused too. |
| 9.3 | **The control socket was chmod-ed one call after `bind` created it**, so it existed briefly with whatever the process umask allowed. Nothing was reachable through that window, because the containing directory is 0700 - but "unreachable because of the directory" is one mistake away from "reachable". | Low | `umask(0o077)` around the bind, so it is private from the instant it exists. The chmod stays as belt and braces. |
| 9.4 | **TESTING.md's numbers had drifted.** It claimed 20 macOS tests as `ControlSocketTests` 6, `NotifyServerTests` 8, `StorageTests` 3, `IntegrationInstallerTests` 7 - a breakdown summing to 24, against a real total of 27. In a project whose argument is "prove it, don't claim it", a document full of measurements that quietly drifted is worse than one with no numbers, because it reads exactly like a measurement. | Medium | Fixed, and `Scripts/check-documented-numbers.sh` now checks every one of those numbers against the repository on each run. |

**Correction to 9.4, from the red build it caused.** I also wrote that `StorageTests` "was never
written". That was wrong. It existed as a *class*, inside `ControlSocketTests.swift` - these
numbers count classes, and I read them as files. My check inherited the same mistake and looked
for a file, so it reported a missing test suite that was there all along, and I wrote a second
class of the same name, which is a compile error. The class now lives in the file that bears its
name, and the check counts classes wherever they are declared.

### Findings, rejected

| Finding | Why it was rejected |
|---|---|
| "The control socket should authenticate its peer with `getpeereid`." | The socket lives in a 0700 directory and is itself 0600, so the only process that can connect already runs as the user - and a check against our own uid would pass for exactly the attacker it is imagined to stop. It would read as security while adding none. |
| "The ledger should be signed or checksummed so a tampered one is detected." | Tampering with it requires being the user, who can equally well set the clamshell bit directly with the same unprivileged call Lidwing uses. A signature would protect nothing and would imply a threat model this product does not have. Corruption, as opposed to tampering, is already handled: an unparseable ledger is treated as absent and the machine's own ground truth decides. |
| "`ensure()` should refuse a too-open directory rather than repairing it." | It is our own directory and the user did not choose its mode. Refusing would disable the product over something that can simply be fixed. A symlink is different, and is refused, because there is no correct repair for it. |

### The red build, which was worth more than the round

| # | Finding | Severity | Fix |
|---|---|---|---|
| 9.5 | **A compile failure reported as a passing step.** `swift test 2>&1 \| tee macos-test.log` runs under `bash -e`, which does not set `pipefail`, so `tee` decides the step's exit code. In run 31429307962 the macOS build failed and the "Unit tests" step went **green**; the job only went red at the count guard two steps later. A guard is not supposed to be the first thing that notices a compile error. | High | `set -o pipefail` on all six masked steps, and a check that parses the workflows for `run:` blocks that pipe without it. |
| 9.6 | **The macOS 26 canary could not report a failing test at all.** Both its steps were `swift build \| tail -40` and `swift test \| tail -40`. Its entire purpose is to go red before a user does, and it was structurally incapable of it. Every green canary result recorded in this repository proved only that the runner started. | High | Same fix. Its greens mean something from now on; the ones before this commit do not. |

The first version of the pipefail check searched the twelve preceding lines for the word
`pipefail` and found the *previous step's*, so its positive control did not fire. It now parses
block scalars properly, and all three shapes - a masked one-liner, a block with its `pipefail`
deleted, and the canary restored to its old form - have been seen red.

### 9.7 — the one that was hiding behind 9.5

Fixing the masked pipes turned `test-macos` red immediately, and reading back through the logs
it had been red all along:

| Run | Reported | Actually |
|---|---|---|
| `7239296` | success | 201 tests, **5 failures** |
| `93c66a3` | success | 209 tests, **5 failures** |
| `eaa417c` | success | 230 tests, **5 failures** |
| `98403cf` | success | 238 tests, **5 failures** |

Two `NotifyServerTests` cases built their socket path from `NSTemporaryDirectory()`, which on a
CI runner is `/var/folders/_5/<hash>/T/` - 48 characters before anything of ours. With a full
UUID the paths came to **105 and 110 bytes** against a `sun_path` that holds 103 plus a NUL, so
`makeAddress` refused them exactly as it is designed to, `start()` returned false, and both
tests failed. The `sun_path` guard that caused this is the round 7 fix; I applied its lesson to
the shell test and not to the Swift one.

The product path is fine and was never at risk: `~/Library/Application Support/Lidwing/
notify.sock` stays under the limit for any username macOS permits. So this was a defect in the
tests - but "the hidden failures turned out to be harmless" is luck, and the reason it stayed
hidden for weeks is not.

Fixed: short paths, and the test now asserts its own path length so a future creep says what it
is instead of looking like a broken server. A failed `NotifyServer.start()` is now logged rather
than ignored, because an advisory feature that silently does not exist is the hardest kind to
diagnose from a support report. And the CI guard gained a second, independent check for reported
failures that does not depend on an exit code at all.

**The lesson, stated plainly:** every "CI is green" in this repository before `e3d5a9b` was
worth less than it claimed, and `STATUS.md` has been corrected rather than quietly updated.

### 9.8 — the same mistake, by the person who had just diagnosed it

The first genuinely meaningful green macOS run reported "249 tests, **1 test skipped**, 0
failures". The skipped one was `testAListeningSocketIsOwnerOnly` - the test written an hour
earlier to prove finding 9.3 - and it was skipped because it bound its socket under
`NSTemporaryDirectory()`, which is the exact defect diagnosed in 9.7, reproduced by the person
who diagnosed it, in the same session, in the file next to it.

Worse than the repeat: it reported that failure as `XCTSkip`. A test that could not run became
a green suite with a quiet "1 test skipped" - the precise shape of "empty read as success" that
this project treats as a bug and that the brief calls out by name. The socket-permission
assertion for 9.3 was therefore never actually executed, and I described it in a commit message
as though it had been.

Fixed: a short path, an asserted path length, and `XCTUnwrap` instead of `XCTSkip`. There is now
no `XCTSkip` anywhere in the suite, and CI fails on any reported skip, so putting one back has
to be a deliberate decision somebody defends.

---

## Round 10 — 2026-08-10, the script that decides the architecture

Scope: `spike/m0-run.sh`. Method: the lens the last two rounds sharpened - where can this report
success without having proved anything? - pointed at the one script whose result the entire
product rests on, and which is about to be run on a real Mac.

### Findings, fixed

| # | Finding | Severity | Fix |
|---|---|---|---|
| 10.1 | **A PASS did not require the lid to have been closed.** The script printed `>>> CLOSE THE LID NOW <<<`, measured for two minutes, and computed its verdict. Nothing anywhere sampled `AppleClamshellState`. If the lid stayed open - forgotten, interrupted, or shut for ten seconds of the window - the Mac stays awake for the most ordinary reason there is, the heartbeat is perfect, both kernel counters are unmoved, and the verdict is a confident PASS. The entire architecture would then rest on an experiment in which the thing being tested never happened. | **Critical** | The lid is sampled every 5 s into `lid.log` and into every heartbeat line, and the verdict fails below 80% closed, or on fewer than two samples. `lid_closed:` is now the first line of the verdict a reader should check, and `docs/human-checklist.md` H2 says so. |
| 10.2 | **A gap of zero measured from zero samples read as a flawless run.** `max_gap_of` ends in `print max + 0`, so a heartbeat log that is empty or unparseable yields `max_gap_s: 0` - indistinguishable from perfection, and the most reassuring number in the file. | High | The verdict now records how many samples the gap came from and fails below two. The script's own comment already said "a gap measured from two samples is not a measurement"; it just did not act on it. |
| 10.3 | **The verdict logic had never been executed.** It runs once or twice ever, on a machine nobody can debug, and until now no test had run it at all - including the branches that matter most, which are the ones nobody wants to stage on real hardware. | High | `Scripts/test-m0-verdict.sh` extracts the block verbatim from the shipped script and runs it against sixteen synthetic cases: a Mac that slept, a dark wake, unreadable counters, a lid never closed, a lid closed for 79% and for 80%, a gap from no samples. In the gate and in CI. |

Five positive controls on 10.3, each proven red by disabling a guard in the real script. One of
them came back **green**: the "lid was never sampled" case was being caught by the *percentage*
guard rather than the sample guard, so deleting the sample guard changed nothing the test could
see. `expect` now asserts on the reason text as well as the verdict, which is what makes each
case test its own guard rather than the union of all of them.

### The same hole, two scripts over

`invariants.sh` had a floor added an hour earlier because a run that checks nothing must not
report success. `fault-injection.sh` and `lidwing-smoke.sh` end in `exit "$FAIL"` and had exactly
the same hole: stop after two of six scenarios and the output is `SUMMARY pass=2 fail=0` and an
exit code of zero. Both now carry the floor, and both floors are tested - they refuse to run on
Linux and do not run in CI, so without `Scripts/test-report-floors.sh` that logic would ship
having never executed anywhere at all.

**Round 10 verdict:** three defects in one 324-line script, one of them critical, in the
component with the least code and the most riding on it. It had been reviewed twice before, for
correctness - which it had. The question that found these was not "is this right" but "can this
report success without proving anything", and that is a different question.

---

**Round 9 verdict:** eight defects, none capable of stranding a Mac, three of them about other
accounts on a shared Mac rather than about the same-uid attacker this product cannot defend
against and does not claim to. The fourth was a document quietly claiming things that were not
true, which in this project is a defect like any other.

---
