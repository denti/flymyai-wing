# 0015 — The idle assertion is held only when there is a reason

**Status:** accepted · **Date:** 2026-08-10
**Follows from:** [0012](0012-zero-step-install-to-value.md), which made arming the default state

## The problem 0012 created

The mechanism has two halves and `DESIGN.md` §2 is right that both are required and orthogonal:

* the **clamshell mask** stops the *demand* sleep a lid close triggers;
* `kIOPMAssertPreventUserIdleSystemSleep` stops the *idle timer*, which the mask does not touch.

The specification describes them as held together, for the length of a session — and that was
correct while a session was a deliberate act for one agent run. Decision 0012 made arming the
default state from login, and never revisited this.

The consequence: **a Mac with Lidwing installed never idle-sleeps again**, from login until the
duration lease expires, whether or not anything is happening. Somebody who walks away with the
lid open comes back to a hot laptop with a flat battery that never slept, for a feature they were
not using. That is a change nobody asked for by installing a lid app, and it is the kind of
side effect that gets an app deleted without a bug report.

## The rule

The assertion is held whenever there is a reason, and released when there is not:

| Situation | Held? | Why |
|---|---|---|
| The lid is shut | **yes** | The case the product exists for. The mask alone leaves the idle timer running, so this is essential, not optional. |
| An agent is running, lid open | **yes** | A run must survive the user walking away. Same promise, different posture. |
| The user turned it on themselves | **yes** | They asked explicitly and are entitled to have it mean what it always meant. |
| Armed automatically, lid open, nothing running | **no** | The promise is not in play and the cost is real. |

The clamshell mask is **always** held while armed. It costs nothing, changes nothing observable
while the lid is open, and is what makes the next lid close safe.

## Why the release is safe

The assertion is re-taken by two independent paths:

* **immediately**, on the clamshell notification, which arrives within milliseconds of the lid
  moving — and on any reassert trigger, including charger and display events;
* **within five seconds**, by the reconcile tick, which is the backstop for a notification that
  never arrives.

Idle sleep requires the full idle timeout — minutes, not seconds — so even the slow path is far
inside it. The dangerous direction is *failing to hold it when needed*, and three of the five
mutations below attack exactly that.

## What is tested

Nine tests, and five mutations each proven red: the assertion dropped with the lid shut (3
failures), dropped while an agent runs (2), a user-requested arm downgraded (1), the release
removed so the old behaviour returns (4), and the release also clearing the clamshell mask (2).

Two properties beyond the table: releasing the assertion is not disarming — the session and the
mask both survive it — and an unchanged machine produces no further writes, so nothing thrashes
on a five-second timer.
