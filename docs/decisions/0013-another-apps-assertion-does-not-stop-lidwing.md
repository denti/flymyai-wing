# 0013 — Another app's assertion is reported, never a reason to stand down

**Status:** accepted · **Date:** 2026-08-10
**Corrects:** the foreign-holder refusal in `SafetyPolicy`, shipped through v0.1.2

## The bug

`SafetyPolicy.refusalReason` refused to arm whenever **any** other process held a sleep
assertion, and `RootDomain.foreignHolders` counted `PreventUserIdleSystemSleep` and
`NoIdleSleepAssertion` as blocking.

On the machine this product exists for, that means it never works. A real developer Mac, sampled
at one ordinary moment:

* `Claude` (the Electron desktop app) — `NoIdleSleepAssertion`, held for 3h25m;
* `caffeinate` — `PreventUserIdleSystemSleep`, **respawned per command** by Claude Code as
  `caffeinate -i -t 300`;
* `configd` — `DenySystemSleep` for Internet Sharing, 1h30m.

So Lidwing would have refused to arm, every time, on exactly the Mac it was built for — and after
decision 0012 made it arm at launch, it would have refused silently at every login.

## Why the refusal was wrong on the merits, not just inconvenient

`StateMachine` already states the reason, in a comment written long before this:

> clamshell sleep is a demand sleep and only idle sleep can be vetoed.

An idle-sleep assertion **cannot** stop a Mac sleeping when the lid closes. That is the entire
reason this product needs `IOPMrootDomain` selector 12 rather than an assertion of its own. So
another app holding one is not doing Lidwing's job, is not in conflict with Lidwing, and standing
down for it protects nothing — it simply lets the user's Mac sleep and their agent run die.

The stronger kinds (`PreventSystemSleep`, `DenySystemSleep`) genuinely do prevent sleep. Lidwing
still arms alongside them, because its mechanism is a **separate kernel mask that it sets and
clears itself** and tracks ownership of precisely (`weSetTheBit`, invariant I7). There is nothing
to fight over, and no reason a user's overnight run should end because Internet Sharing is on.

## What ships instead

Detection got **stronger**, not weaker. Holders are classified by what they actually prevent,
named the way a person would recognise them, and reported in the menu in every state:

| Case | Line |
|---|---|
| idle-sleep holder | `Claude is also holding this Mac awake.` |
| system-sleep holder | `Internet Sharing is holding this Mac awake on its own.` |
| self-releasing holder | `caffeinate is also holding it awake, briefly.` |

The transient wording matters. `caffeinate -t 300` is respawned per command, so telling a user
"caffeinate is keeping your Mac awake" without qualification sends them hunting for something
that stops existing while they look for it.

The conflict line is appended rather than substituted when a battery or thermal warning already
owns the detail line — conflict is a headline fact, not a fallback.

## What did not change

* The **clamshell bit** is a different matter entirely. If it is already set and no ledger of
  ours explains it, that is the repair path (decision 0011), and it still stands down there.
* Every other refusal — no lid, battery below the floor, too hot, external display on AC, no
  watchdog — is untouched.
