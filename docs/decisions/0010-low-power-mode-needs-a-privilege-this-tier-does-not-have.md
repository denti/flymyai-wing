# 0010 — Low Power Mode needs a privilege this architecture does not have

**Status:** open, escalated to the product owner · **Date:** 2026-08-10

## The problem

Two decisions that are each correct on their own do not fit together.

* **[0004](0004-low-power-mode.md)** — Low Power Mode ships as a user-facing toggle, **default
  ON**. This is the product owner's own override, restated twice, and `MISSION.md` §3 marks it
  "a decided question; do not re-litigate it".
* **[0002](0002-mechanism-authority.md)** — Tier 1. The clamshell mask plus a named assertion,
  written by the app itself with **no root, no privileged helper, and no persistent system
  state**. Chosen on a safety asymmetry: a kernel variable that a reboot clears unconditionally
  cannot leave a Mac permanently unable to sleep, and nothing in the product needs admin.

Low Power Mode is not reachable from Tier 1. The specification says so in three places, written
by people who were verifying on a real Mac:

* `ADDENDUM.md` §W4 lists `pmset -b/-c lowpowermode` as work **inside the privileged helper**,
  beside `pmset -a disablesleep`.
* `ADDENDUM.md` Appendix A's recovery script restores it with `sudo -n pmset -b lowpowermode`.
* `CRAFT.md` §733 describes the confirmation dialog for it as gating "a second **privileged**
  write".

`pmset` writes system power settings and refuses without root; `ProcessInfo.isLowPowerModeEnabled`
is read-only and there is no public API to set it. So the toggle cannot do what its label says
unless Lidwing ships something that runs as root.

## Why this is not mine to decide

Shipping a root component to satisfy a battery-saving toggle inverts the trade that decision
0002 was made on. The whole trust argument of this product is "it needs no privileges, and if
it dies your Mac still sleeps". Adding a privileged helper for Low Power Mode would:

* reintroduce persistent system state that survives a crash and a reboot,
* require the notarized-helper install flow, an admin prompt, and an uninstall path for it,
* and make the honest answer to "what happens if this app breaks" much longer.

That is `DESIGN.md` §12 **T3** in substance: shipping a root daemon is a liability decision the
human must make explicitly. It is being escalated rather than decided here, and the toggle is
not being shipped as a control that silently does nothing.

## What is being done meanwhile

1. **The claim is being turned into a measurement.** `docs/human-checklist.md` **H9** is one
   command that settles it in thirty seconds on the owner's Mac: run `pmset -b lowpowermode 1`
   as a normal user and report what it says. Every source above is a document; none of them is
   this repository having run it. If it turns out an ordinary user *can* write it, this whole
   record is void and the toggle ships as specified in 0004.
2. **No half-toggle.** A checkbox that appears to engage Low Power Mode and does not is worse
   than its absence, and worse than the escalation.

## The options, for the owner

| | What ships | Cost |
|---|---|---|
| **A** | Nothing. Low Power Mode is dropped, and the README says Lidwing writes no system settings at all. | Loses a feature the owner asked for twice. |
| **B** | A one-time, opt-in prompt that opens System Settings ▸ Battery at the right pane, and remembers the preference. Lidwing never writes the setting; the user does, once. | Honest and unprivileged, but it is a manual step, and it cannot restore the old value on lid open. |
| **C** | The privileged helper from `ADDENDUM.md` §W4, with the full snapshot/restore ledger and per-power-source handling from 0004. | Root. Reverses the basis of decision 0002. |

No option is being taken unilaterally. **B** is the only one implementable without reversing an
architectural decision, and even B is a product choice about how much manual work is acceptable.
