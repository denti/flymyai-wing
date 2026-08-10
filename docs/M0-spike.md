# M0 — the experiment the product rests on

**Status: not yet run.** Everything in this repository beyond the portable core is contingent
on the result below.

## The question

> Does arming `IOPMrootDomain` selector 12 keep a MacBook running when the lid is physically
> closed, on battery, with no external display, without root?

## Why it is not already answered

The mechanism is derived from kernel source, and the source reading is strong:

* `kPMSetClamshellSleepState = 12` is a constant in the **public** SDK header
  `IOKit/pwr_mgt/IOPMLibDefs.h`.
* `IOPMrootDomain::shouldSleepOnClamshellClosed()` returns
  `!clamshellDisabled && !(desktopMode && acAdaptorConnected) && !clamshellSleepDisableMask`,
  and `clamshellSleepDisableMask` is the only one of the three reachable from userspace.
* `RootDomainUserClient` sets `kIOUserClientEntitlementsKey = false`, and selector 12's
  dispatch entry has `.checkEntitlement = NULL` with no `clientHasPrivilege()` call — unlike
  its neighbours 13 and 15, which do check. That holds in every xnu tag from 4903 (10.14)
  through 12377 (macOS 26).

None of that is a measurement. **Nobody has armed the bit and closed a lid.** Every
"verification" in the research corpus was a provable no-op — an API returning `KERN_SUCCESS`
while the machine did nothing. Both mechanisms in this document return success while doing
nothing, which is exactly why the acceptance signal below is the machine's own behaviour and
never a return code.

## What "pass" means, precisely

A run passes only if **all three** agree:

1. The 60-second heartbeat never gaps by more than 90 seconds.
2. `pmset -g stats` **Sleep Count** is unchanged between the before and after snapshots.
3. `pmset -g stats` **Dark Wake Count** is unchanged.

A continuous heartbeat with a moved counter is a **fail**. A sleep short enough to hide between
two ticks is still a sleep, and it matters more than a long one: both known holes in this
mechanism have the same precondition — *the machine must have slept at least once* — so the
first sleep is the one that opens the door for every sleep after it.

A ten-minute test proves nothing. The short form is a go/no-go signal; the eight-hour soak is
the evidence.

## What Denis runs

Everything is in `spike/`. Nothing needs root for mechanism A. Nothing persists across a
reboot for mechanism A.

### Step 0 — read-only sanity, 10 seconds

```bash
cd ~/lidwing-repo                       # wherever you cloned it
swiftc -O -o /tmp/wingprobe spike/wingprobe.swift
/tmp/wingprobe verify
```

Expected: `IOPMrootDomain user client openable : yes`, `AppleClamshellState present : yes
(portable)`, and a non-zero `uid` — that last line is the proof that no root was involved.
This command mutates nothing.

### Step 1 — the short form, 2 minutes

This is the go/no-go. Disconnect every external display, dock and HDMI/DP dongle first; the
script refuses to run if it sees more than one display, because macOS already keeps a
lid-closed Mac awake with an external display on AC and a pass in that configuration would
prove nothing.

```bash
./spike/m0-run.sh --short
```

The script prints `>>> CLOSE THE LID NOW <<<` and then waits two minutes. Close the lid, count
to a hundred and twenty, open it. It disarms itself.

**What you should observe:** the terminal shows `=== PASS ===` and a `verdict.txt` with
`max_gap_s` in single digits and both deltas `0`. If the Mac slept, you will see the login
window when you open the lid and the verdict will say `FAIL` with the gap in seconds.

Either way, send me the directory it prints. **The raw logs are the result; the verdict line is
just arithmetic over them.**

### Step 2 — the soak, 8 hours

Only after the short form passes. Start it in the evening, on battery if the battery is above
80 %, otherwise on AC and note which.

```bash
./spike/m0-run.sh --soak
```

During the run, if you are around: plug and unplug the charger five times, spaced out. That is
the re-assert test (`A4`) — the mechanism has to survive a power-source change, and powerd's
own clamshell shadow state changes when it does.

**What you should observe in the morning:** the Mac is awake, `verdict.txt` says `PASS`,
`heartbeats` is about 480, and `sleep_delta` and `darkwake_delta` are both `0`.

### Step 3 — only if step 1 fails

Do not redesign anything. Run the same protocol against mechanism B so the fork has data:

```bash
./spike/m0-run.sh --short --mechanism b
```

**Read this before you run it.** Mechanism B is `sudo pmset -a disablesleep 1`. Unlike
mechanism A it needs root, it persists across a reboot in a root-owned plist, and it disables
the machine's low-battery and thermal *emergency* sleep as well as lid-close sleep. The script
restores it in a trap on every exit path and verifies the restore, but if you ever want to
check by hand:

```bash
ioreg -r -c IOPMrootDomain -d 1 | grep SleepDisabled     # must print No
sudo pmset -a disablesleep 0                             # the one-line fix, always safe
```

## The fork

| Result | Consequence |
|---|---|
| **A passes** | Tier 1 is the product. No root, no privileged helper, no persistent system state, no admin prompt. `DESIGN.md` M3 is cancelled. This is by far the best outcome for both trust and UX. |
| **A fails, B passes** | Tier 1 stays the default *attempt* because it is strictly safer, but a root helper becomes mandatory and the battery and thermal guards move into it. Escalation trigger **T3** fires first: shipping a root daemon that disables emergency sleep is a liability decision, not a technical one, and Denis makes it explicitly. |
| **A passes with 1-3 sleeps in an 8-hour run** | Escalation trigger **T2**. Intermittent is worse than broken, because the product would show a green icon that is sometimes a lie. The decision — ship the stronger method, or narrow the promise to "on AC" — is a product call. |
| **Both fail** | Escalation trigger **T1**. Stop everything. The product as specified does not exist, and no amount of engineering conjures it. |

## What is already built against the passing branch

The portable core — state machine, safety policy, ledger, audit — is mechanism-agnostic: it
talks to `SystemFacade`, which has exactly two writes (`setClamshellSleepDisabled`,
`setIdleAssertion`). If the fork lands on Tier 3, the facade's implementation changes and the
state machine does not. That is deliberate, and it is why the core was written before the
answer arrived rather than after.

## Raw results

Committed under `docs/m0/<label>-mech<a|b>-<timestamp>/` as they arrive. Each directory holds
the before and after snapshots, both heartbeat logs, `pmset -g log` for the window, and
`verdict.txt`. Nothing is summarised away.

*(No runs yet.)*
