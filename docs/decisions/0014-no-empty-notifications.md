# 0014 — No empty notifications, and the detector asks the right question

**Status:** accepted, from the product owner · **Date:** 2026-08-10
**Corrects:** [0012](0012-zero-step-install-to-value.md) §2 and [0013](0013-another-apps-assertion-does-not-stop-lidwing.md)

Denis, verbatim: *"пустые нотификейшны не нужны, нужен продукт который работает"* — no empty
notifications, ship a product that works.

## The bug that prompted it

The first thing v0.1.1 said on launch:

> Another app is already keeping this Mac awake: powerd (pid 368).

Every part of that is wrong. `powerd` is Apple's own power-management daemon; its assertion
`Powerd - Prevent sleep while display is on` is present whenever the display is on, which is to
say always. It is not an app, it is not keeping the Mac awake in any sense the user cares about,
and it does not interfere with Lidwing. The same class: `WindowServer` `UserIsActive` from
trackpad tickles, `useractivityd` `BTLEAdvertisement`, `sharingd` `Handoff`, `mds_stores`
`BackgroundTask`.

## The detector was asking the wrong question

It asked **who is preventing sleep**. The question that matters is **who will interfere with
me**. Lidwing blocks the clamshell *demand* sleep; idle-sleep assertions are a different layer
and the two coexist perfectly.

Re-derived, there are three tiers and only one is a conflict:

1. **Genuine conflict, worth interrupting a user.** The clamshell bit is already set and we do
   not own it. It comes from ground truth, not from assertions; it is the state that crashed
   v0.1.0; it is handled by the repair path in [0011](0011-repair-is-never-a-modal-on-the-launch-path.md);
   and it is rare.
2. **Worth one quiet line, not a warning.** A `DenySystemSleep`-class holder such as Internet
   Sharing. The Mac will not sleep at all while it is held, so Lidwing's promise is temporarily
   moot. Stated in the detail line, never in the headline, never with a badge.
3. **Ignored entirely.** Every `PreventUserIdleSystemSleep`, `NoIdleSleepAssertion` and
   `UserIsActive` holder, Apple's or anybody's, including `caffeinate` and the Claude desktop
   app. Available under diagnostics; never on the launch path.

The *kind* of hold decides this, never the owner. Filtering by owner is what both named `powerd`
to users and would have hidden Internet Sharing — the two mistakes are the same mistake.

The owner's Mac holds **seven assertions from six owners and not one is a conflict**. That is the
ordinary case, and `pmset-assertions-quiet-mac.txt` asserts the app says nothing about any of it.

## The rule, applied to everything

Every notification, alert, banner and badge must pass one test before it exists: **what does the
user do differently because of it?** If the honest answer is nothing, it is deleted — not
softened, deleted.

**Three were deleted:**

| Deleted | Why |
|---|---|
| The first-arm notification, "Lidwing is running / look for the wing" | The user has just installed a menu-bar app and is looking at the menu bar. Nothing changes. |
| "macOS changed, and Lidwing still works" | True, friendly, and nothing anybody does about it. The fact is still recorded and logged, which is what makes a later failure explainable. |
| The first-run popover pointing at the menu bar | Same as the first, in a borderless window. 79 lines. |

The distinct "another app is in control" glyph went too: a dot in the menu bar is a warning, and
warning somebody that Internet Sharing is on is noise.

**What survives** either tells the user their Mac is about to sleep, or that it is not protected
when they believe it is, or asks them to do something physical about heat. That is the whole
list, and each entry names the action it enables.

The chime on lid close stays, and is exempt from any argument about noise: it is the one signal
that reaches a user who cannot see the screen, which is the entire point of the product.
