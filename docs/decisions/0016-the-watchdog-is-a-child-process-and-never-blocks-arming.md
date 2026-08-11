# 0016 — The watchdog is a child process, and it never blocks arming

**Status:** accepted, from a machine where the product did nothing at all · **Date:** 2026-08-11
**Corrects:** the launchd dependency and the `watchdogUnavailable` refusal

## What was happening

On a real Mac, v0.1.4 sat in the menu bar and the machine slept every time the lid closed.
`AppleClamshellCausesSleep = Yes`, so it had never armed. The message was
*"Lidwing could not start its safety watchdog, so it will not keep this Mac awake."*

```
launchctl print gui/501/ai.flymy.lidwing.watchdog
  → Could not find service in domain for user gui: 501
```

No agent registered, no `lidwingd`, nothing in `~/Library/LaunchAgents`, and no `btm`/`smd` log
line mentioning it. `SMAppService.agent` cannot register an **ad-hoc signed** app with no Team ID,
and the `launchctl bootstrap` fallback did not produce one either.

So: no watchdog, and `onUserArm` refused without one. **The product could not work for anybody
until an Apple Developer Program enrolment completed.** That is not a real constraint, it is a
bug.

## Two changes, and the second matters more

### 1. `lidwingd` is spawned as a plain child process

No registration, no signing identity, no Login Items approval. It works on an ad-hoc build and on
every macOS from the deployment floor up.

The dead-man design is unchanged and unaffected. The app is the **client** on the control socket,
so any death — crash, `kill -9`, force quit — closes the socket and the watchdog sees EOF in
milliseconds. That is what covers the real risk, and it never depended on launchd.

launchd survives as an opportunistic extra: it is attempted after the child is up, it is allowed
to fail, and it is logged either way.

### 2. A missing watchdog degrades instead of refusing

Gating the core feature on a component whose only job is cleanup after a failure is backwards.

What is actually risked by arming without one: the app dies while armed, and the Mac cannot sleep
on lid close **until the next restart**. That is bounded, and bounded by the kernel rather than by
our code — `clamshellSleepDisableMask` is initialised to 0 in `IOPMrootDomain::start()`, so a
reboot always clears it. `DESIGN.md` §2 calls that asymmetry "the whole argument" for this tier.
Re-verified against the specification before making this change rather than assumed.

Weighed against a product that never works at all, that is plainly the better failure. It is
recorded in the audit either way, so a session without a dead-man is never indistinguishable from
a protected one.

## What launchd was actually for

Boot-time recovery — `RunAtLoad`, restoring after a reboot. That guards a state which cannot
exist: the bit does not survive a reboot. A restorer that runs at boot is guarding against
something a boot has already fixed.

## The trap this introduced, and its fix

launchd guaranteed a single copy of the watchdog; nothing else does. `UnixSocket.listen` unlinks
the socket path before binding, so a second `lidwingd` would silently steal the socket from the
first and leave an orphan watching nothing — and the app can ask for a watchdog more than once in
a session, so this is reachable rather than theoretical. `lidwingd` now takes an exclusive
`flock` and exits cleanly if another instance holds it. A failure to create the lock file is
deliberately not fatal: no dead-man at all is worse than a small risk of two.
