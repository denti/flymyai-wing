# 0011 — Repair is never a modal on the launch path

**Status:** accepted, from a crash on a user's Mac · **Date:** 2026-08-10

## What happened

Lidwing 0.0.0 segfaulted on launch on a Mac14,2, macOS 15.5 (24F74): `EXC_BAD_ACCESS`,
`SIGSEGV`, `KERN_INVALID_ADDRESS` at `0x94`, main thread, `com.apple.main-thread`.

```
NSAppleEventManager dispatch
  -[NSApplication _handleAEOpenEvent:]
    _sendFinishLaunchingNotification
      AppDelegate.applicationDidFinishLaunching
        AppCoordinator.start()
          deliver(_:) -> perform(_:) -> presentRepair(_:)
            -[NSAlert runModal]                       <-- here
              _NSTryRunModal -> runModalForWindow -> _doModalLoop
                CFRunLoopRunSpecific -> __CFRunLoopRun
                  __CFRunLoopPerCalloutARPEnd -> _CFAutoreleasePoolPop
                    AutoreleasePoolPage::releaseUntil -> objc_msgSend -> boom
```

A modal `NSAlert` was run synchronously from `applicationDidFinishLaunching`, which is itself
running inside the Apple Event handler. The nested modal run loop spins while AppKit is still
finishing launch, and pops an autorelease pool the launch machinery still owns.

## Why that path ran, which matters more than the crash

Ground truth was non-stock and no ledger of ours explained it: a spike probe had armed the
clamshell bit **from a different process** and been interrupted without disarming. Lidwing
correctly concluded that the mechanism was armed while it owned nothing, and went down the
repair path.

That is not a synthetic case. The bit is **global, unowned, and carries no reference count**, so
the same state is produced by a previous instance that crashed, a second copy of the app, or
another utility entirely. It is the ordinary first-launch state on any Mac that has ever had one
of these tools on it — which makes it the one path guaranteed to run on a machine that is
already in a strange state.

## Decision

1. **The launch path never opens a dialog.** `.offerRepair` now carries a `RepairPrompt`:
   `.quietly` from `onLaunch`, `.askNow` from a user action. Only `.askNow` may present.
2. **The condition is still unmissable**, without blocking: the glyph shows the repair state,
   the menu carries the headline, the detail and a `Repair Now…` item.
3. **The confirmation moved to where it belongs.** `Repair Now…` is a user action whose title
   ends in an ellipsis precisely because it promises a dialog. Before this, that item repaired
   with no confirmation at all while the launch path asked — exactly backwards.
4. **The watchdog retires.** `KeepAlive: true` restarted `lidwingd` forever, so after the app
   died it stayed resident with nothing to watch — which is what the user saw. It is now
   `KeepAlive: {SuccessfulExit: false}`, and the daemon exits once there is no client **and**
   the machine is provably stock. If the machine is not stock, the job is unfinished and it
   stays. If it dies while guarding an armed session, launchd still brings it straight back.

## What is tested

`armed but owned by nobody` is now a named group in `StateMachineTests`, driving `.launch`
against a facade reporting exactly that state:

* the launch path emits `.offerRepair(_, .quietly)` and never `.askNow`;
* nothing is written — no clamshell write, no assertion, no ledger, no watchdog connection;
* the state is not reported as protecting;
* asking to arm while in that state *is* allowed to prompt;
* repair, once asked for, goes through `repairClamshellState` — the call that clears a bit this
  process never set.

## What this does not fix

The general rule is enforced by one type and five tests, not by the compiler. A future effect
that presents UI from `deliver` on the launch path would reintroduce the class. The narrower
protection that does exist: `Scripts/check-core-purity.sh` requires every `runModal()` in the app
target to be preceded by an `NSApp.activate`, which at least makes each modal visible as such
when read.
