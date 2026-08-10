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
