# 0010 — Low Power Mode is the one thing that asks for a password, and only if you ask for it

**Status:** accepted, decided by the product owner · **Date:** 2026-08-10
**Supersedes:** the "default ON" reading of [0004](0004-low-power-mode.md)

## The problem, as escalated

Two decisions that were each right on their own did not fit together.

* **[0004](0004-low-power-mode.md)** — Low Power Mode ships as a toggle, **default ON**.
* **[0002](0002-mechanism-authority.md)** — Tier 1: the clamshell mask and a named assertion,
  written by the app itself, with **no root, no privileged helper, no persistent system state**.

Low Power Mode is not reachable from Tier 1. `pmset` writes system power settings and refuses
without root; `ProcessInfo.isLowPowerModeEnabled` is read-only and there is no public API to set
it. The specification says the same in three places, written by people verifying on a real Mac:
`ADDENDUM.md` §W4 lists `pmset -b/-c lowpowermode` as work **inside the privileged helper**, its
Appendix A recovery script uses `sudo -n pmset -b lowpowermode`, and `CRAFT.md` §733 calls the
confirmation dialog for it a gate on "a second **privileged** write".

Shipping a root component to satisfy a battery toggle inverts the trade 0002 was made on, so it
was escalated rather than decided here — `DESIGN.md` §12 **T3** in substance.

## The decision

Denis's ruling, and it is now the operative one:

* **The option ships in Settings, OFF until the user turns it on.**
* **Turning it on is exactly the moment the privileged helper is installed and an administrator
  password is requested.** Never at launch. Never for the core lid feature. Never speculatively.
* **The Settings row says so before the click** — plainly, in the row itself, that enabling this
  will ask for an administrator password. Not in a dialog that appears afterwards.
* **The default state of the app stays zero-privilege**, and that is a headline trust property
  rather than an implementation detail: *a user who never enables Low Power Mode never sees a
  password prompt and never has a helper installed*. It is said in the UI, and it goes in the
  README.
* **Turning the option back off removes the helper** and restores the previous `lowpowermode`
  value exactly. So does uninstalling the app.
* **No half-toggle**, confirmed: a checkbox that appears to engage Low Power Mode and does not
  is worse than its absence. That stance was right and it is kept.

## What this changes, and what it does not

It does **not** reverse 0002. The lid mechanism — the entire reason this product exists — stays
Tier 1, unprivileged, with a kernel variable that a reboot clears unconditionally. The helper is
an **island**: it exists only for one setting, only after an explicit opt-in, and it can be
removed by unticking one box.

It does change the sentence "Lidwing needs no privileges at all" into "Lidwing needs no
privileges unless you ask it for Low Power Mode, and it tells you before you do". That is a
longer sentence and still a true one, which is the point.

## Shipped behaviour

From 0004, unchanged except for the default:

* Engaged **only** on battery **and** only while the lid is closed. On AC it is never engaged:
  there is nothing to save, so the slowdown would be pure loss.
* Written **per power source** (`-b` and `-c` held separately). macOS stores Low Power Mode
  separately for battery and for AC; collapsing them silently destroys a choice the user made.
* Snapshot before write, restore exactly what was found, and never write a value already in
  place. On the owner's own Mac `lowpowermode` is already `1` on both sources, so a naive
  "restore the default" would undo his setup — there, we write nothing at all.
* Re-read at restore time. If the value is no longer what *we* set, the user or another app
  changed it after us: leave it alone and record that we did.

## UI copy

**No numbers.** The label warns in plain words that the mode trades speed for battery life.

* Checkbox — `Save battery while the lid is closed`
* Explanation — `Slows your Mac down to use less battery. Your agent will take longer to finish.`
* The privilege line, in the row, before any click —
  `Turning this on asks for an administrator password and installs a small helper. Nothing else
  in Lidwing needs one.`
* Off state, stated as the property it is —
  `Lidwing has not asked for any privileges on this Mac.`

## Verification

`docs/human-checklist.md` **H9** still stands and is now worth more, not less: it is the
thirty-second command that confirms the premise this whole decision rests on. If an ordinary
user turns out to be able to write `lowpowermode` without root, the helper is unnecessary and
this decision should be revisited immediately.
