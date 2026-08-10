# 0012 — Install to value is zero steps, and conflict detection is a headline feature

**Status:** accepted, from the product owner · **Date:** 2026-08-10
**Overrides:** the five-screen onboarding in `CRAFT.md` §4

Denis, verbatim: *"сразу поставил и она работает сразу со звуком при закрытии, предупреждает
если другое что-то контролит сразу"* — you install it and it works immediately, with a sound on
lid close, and it warns you straight away if something else is in control.

## 1. Zero steps between installing and being protected

Drag to Applications, launch, and **protection is already on**. No wizard, no questionnaire, no
permission request, no page of explanation standing between the user and the thing working.

Anything that survives from onboarding must be **non-blocking, skippable, and must never gate the
core function**.

This is possible precisely because Tier 1 needs no privileges — no password, no helper, no
persistent system state. That is the whole reason the architecture is worth having, and this is
where it pays out. An app that needed admin could not do this; Lidwing can, so it must.

## 2. The safety debt is paid in the moment, not up front

Removing the wizard does not remove the obligation. A user whose Mac stops sleeping is entitled
to know **why**, and the answer arrives when it is relevant rather than as a wall of text nobody
reads at install time:

* the armed glyph in the menu bar,
* the chime on the **first lid close** — the moment the screen is not an output channel,
* and **one** non-blocking notification the first time it arms, worded for somebody who is not
  an engineer.

The battery floor, the thermal guard and the maximum-duration lease remain mandatory. They are
what makes arming-by-default defensible: the app that turns itself on is also the app that turns
itself off before the battery dies or the Mac cooks.

## 3. Conflict detection is a headline feature, not a diagnostic

At launch **and continuously**, detect anything else holding sleep prevention — `caffeinate`
processes, Amphetamine, KeepingYouAwake, Lungo, or a clamshell bit already set and owned by
nobody — and say so **immediately and non-modally**, with a distinct icon state and a
plain-English menu line naming the other holder.

This is the common case, not the edge case: the owner's own Mac has several `caffeinate` holders
on it right now. An app that silently does nothing there, or worse claims to be protecting while
another tool actually is, is lying by omission at the exact moment the user is trying to work out
why their Mac behaves oddly.

## Consequences to work through

* Arming at launch must still respect every refusal the state machine already enforces: no lid,
  unsupported OS, battery already below the floor, too hot, a foreign holder, no watchdog. **A
  refusal is not a failure to report quietly** — it is the conflict case above, and it is
  exactly what the user needs to see.
* First-arm-at-launch must not chime. The chime belongs to the lid close, and a sound at every
  login would be the fastest way to be muted permanently.
* The maximum-duration lease starts at launch, not at first lid close, or an app that arms itself
  on login would hold a Mac awake all day.
* `hasEverArmed` currently gates the first-arm notification; with arming at launch it fires on
  first run, which is correct — that is the one notification this decision allows.
