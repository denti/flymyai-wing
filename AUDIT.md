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
