# 0002 — Which mechanism keeps the Mac awake

**Status:** accepted, pending the M0 spike · **Date:** 2026-08-10

## Conflict

The specification set describes two different products.

`CRAFT.md` §7.6 and `ADDENDUM.md` §5.5 are written against a **root helper** that calls
`IOPMSetSystemPowerSetting` (or shells out to `pmset -a disablesleep 1`), installed with
`SMAppService`, approved by an administrator in System Settings. Every trust affordance in
those documents — the permission window, the "one setting" disclosure, the restore ledger at
`/Library/Application Support`, the XPC hardening, the 90-second watchdog — assumes it.

`DESIGN.md` §2.2 rejects that as the *default* and chooses an unprivileged mechanism:
`IOConnectCallScalarMethod(IOPMrootDomain, selector 12, in=1)` — `kPMSetClamshellSleepState`,
a constant in the **public** SDK header `IOKit/pwr_mgt/IOPMLibDefs.h` — plus a
`kIOPMAssertPreventUserIdleSystemSleep` assertion. No root, no helper, no daemon, no approval
dialog, and nothing that survives a reboot.

## Decision

**Tier 1 (`DESIGN.md` §2.2) is the mechanism.** `CRAFT.md` and `ADDENDUM.md` remain
authoritative for craft and operations, and are read with their privileged-helper assumptions
suspended.

The argument that settles it is not authorial precedence, it is the safety asymmetry:

* The clamshell mask leaves `checkSystemSleepAllowed()` untouched, so low-battery
  (`kIOPMSleepReasonLowPower`) and thermal (`kIOPMSleepReasonThermalEmergency`) emergency sleep
  still work. `SleepDisabled` sets `userDisabledAllSleep`, which is tested at the top of
  `checkSystemSleepAllowed()` **before any reason code** — it kills both emergencies, the Apple
  menu's Sleep item and the power button.
* The mask is initialised to zero in `IOPMrootDomain::start()`, so a reboot always clears it.
  `SleepDisabled` persists in a root-owned plist, which is why the helper design needs a boot
  reconciler daemon to be safe at all.
* `man pmset` on macOS 15.5 contains zero occurrences of `disablesleep`. We would be asking a
  user for admin rights to use an undocumented verb, and we could not point them at any Apple
  documentation for it.

For a product whose promise includes *"and stops on its own before your battery dies or your
Mac overheats"*, a mechanism that disables the machine's own last-resort halt is the wrong
default at any price.

## What this cancels and what it keeps

**Cancelled while Tier 1 holds:** the root helper, the boot reconciler, the `SMAppService`
approval flow, the XPC threat model in `DESIGN.md` §9, the admin-permission window in
`CRAFT.md` §4.4, and the `/Library/Application Support` root-owned ledger. `DESIGN.md` M3 is
cancelled outright if M0 mechanism A passes.

**Kept unchanged:** everything in `CRAFT.md` about the icon, the menu, the Dock-menu escape
hatch, sound grammar, accessibility, the antipattern list, and the "prove it, don't claim it"
posture. Kept from `ADDENDUM.md`: the compatibility matrix shape, the smoke-test discipline
(`SKIP` is never `PASS`), structured `os_log` at `.notice` and above, diagnostics scrubbing by
allowlist, and the trust-badge rules.

**Kept and made stronger:** the watchdog. Tier 1 needs one *more*, not less:
`RootDomainUserClient::clientClose()` only calls `terminate()`, so nothing in the kernel clears
`clamshellSleepDisableMask` when our process dies. A `kill -9` would otherwise leave a Mac
unable to sleep on lid close until reboot. Ours is an unprivileged user LaunchAgent, it is not
optional, and the app refuses to hold the bit without a live connection to it (invariant I2).

## The two known holes, and why the design still stands

* **Hole A** — the dark-wake path in `IOPMrootDomain` does not include the mask as a term.
* **Hole B** — on Apple silicon, powerd clears the bit on a dark-to-full-wake transition, and
  does it synchronously in the same workloop, so no polling interval can win the race.

Both have the same precondition: *the machine must have slept at least once*. That is the
origin of **INVARIANT SLEEP-ZERO** — while armed, a single observed sleep is a hard product
failure, not a recoverable event — and of the pre-arm rule, the aggressive re-assert loop and
the `SLEPT_WHILE_ARMED` audit record.

## Falsifiable

This decision rests on kernel-source reading that nobody has yet confirmed with a physically
closed lid. `docs/M0-spike.md` is the experiment that can overturn it. If mechanism A fails and
mechanism B (`disablesleep`) passes, this record is superseded, Tier 3 becomes mandatory, and
escalation trigger T3 fires before any root code is written.
