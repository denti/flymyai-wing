# 0005 — Guard timing: what "too hot" and "too low" mean in seconds

**Status:** accepted · **Date:** 2026-08-10

## Conflict

`DESIGN.md` §3.3 transition table: `armed` + `thermal(.critical)` → `disarming`, immediately.
`ADDENDUM.md` §4.2: disarm on `.critical` **sustained for 60 s**.

`DESIGN.md` §4f is explicit about the battery side (two agreeing samples, 2 s apart) and silent
about the thermal side.

## Decision

| Guard | Trip condition | Reason |
|---|---|---|
| Battery floor | percentage ≤ floor on **two** samples ≥ 2 s apart | At the instant of an AC flip the power-source dictionary is momentarily inconsistent — `charging=false`, `toEmpty=-1` and `toFull=0` simultaneously. One sample there would end an eight-hour run on a charger reseat. |
| Battery, OS final warning | immediately, no debounce | `kIOPSLowBatteryWarningFinal` is the OS saying the machine is about to die. It also fires on machines whose capacity keys we cannot interpret, which is the case the percentage path cannot cover. |
| Thermal | `.critical` sustained **60 s** | `ADDENDUM.md` is right and `DESIGN.md` is over-eager here. |
| Thermal, advisory | `.serious` or above → `degraded`, warn once per session | Tells the user before we act. |

The thermal dwell is the one place this project deliberately takes the slower of two specified
behaviours, so the reasoning is worth stating: `ProcessInfo.thermalState` is a coarse,
smoothed, whole-system signal, and `.critical` appears transiently on a healthy machine during
a heavy link step or a Spotlight re-index. Disarming on the first sample ends the user's
overnight agent run — the exact outcome they installed this to prevent — for a condition that
frequently clears on its own within seconds.

The safety argument does not require immediacy: unlike the `SleepDisabled` mechanism, the
clamshell mask leaves `checkSystemSleepAllowed()` untouched, so the kernel's own thermal
emergency sleep (`kIOPMSleepReasonThermalEmergency`) is still armed underneath us the entire
time. We are the *first* line of defence, not the only one, and a first line that fires on
noise is worse than one that waits a minute. During the dwell the user is already being told
the Mac is running hot.

## What is not negotiable

* The guards are evaluated on **every** event and at least every 5 s (invariant I6), not only
  on the reconcile tick.
* The percentage is always computed as `current * 100 / max`. Treating
  `kIOPSCurrentCapacityKey` as a percentage is the classic version of this bug: on a machine
  reporting raw mAh, comparing 3119 against a 20 % floor never trips and the guard silently
  never fires. `SafetyPolicyTests.testPercentageIsComputedFromBothCapacities` pins it.
* Action on trip is a full disarm so the Mac sleeps **normally**. Sleep preserves RAM; a hard
  power cutoff does not. We never shut down.
* The reason is persisted, so the next launch can explain itself: *"Stopped at 03:41 — battery
  reached 20%."*
