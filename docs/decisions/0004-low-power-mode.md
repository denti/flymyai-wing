# 0004 — Low Power Mode ships as a toggle, default ON

**Status:** accepted (decided by the product owner; not open for re-litigation) · **Date:** 2026-08-10

## Conflict

Three positions, in two documents plus one document that contradicts itself.

* `DESIGN.md` §1.3 and §4c: **never write `lowpowermode`.** Listed as a permanent non-goal,
  citing a measured ~2.12× wall-clock cost on M4-class multicore for roughly zero net energy
  saved on a fixed job — it taxes exactly the parallel builds this app exists to protect.
* `DECISIONS.md` "Product" §6: a user-facing checkbox, **ON by default**, with Denis's own
  words quoted: *"она от кейса к кейсу варьируется, я бы по умолчанию делал включенным его."*
* `DECISIONS.md` "Battery-saving nuance", last section: "Ship the LPM toggle because Denis
  asked for it, **defaulted OFF**". This is an internal contradiction inside the document that
  otherwise has final authority.

## Decision

**A user-facing toggle, default ON**, exactly as `DECISIONS.md` §6 states.

`DECISIONS.md` wins over `DESIGN.md` by the stated order of authority. Where `DECISIONS.md`
contradicts itself, §6 wins over the closing note: §6 is the later, explicit, reasoned
statement, it quotes the owner directly, and the mission brief independently restates it as
"DEFAULT ON. This is a decided question; do not re-litigate it."

The owner's reason is a real methodological objection, not a preference: the cost of Low Power
Mode varies enormously by workload — near-invisible on short single-threaded work, large on
long parallel builds — so one benchmark on one fixed job does not generalise, and a permanent
non-goal derived from it is over-claimed.

## Shipped behaviour

* Engaged **only** on battery **and** only while the lid is closed. On AC it is never engaged:
  there is nothing to save, so the slowdown would be pure loss.
* Written per power source (`-b` and `-c` equivalents held separately). macOS stores Low Power
  Mode separately for battery and for AC; collapsing the two into one silently destroys a
  choice the user made.
* Snapshot before write, restore exactly what was found on lid open, and never write a value
  that is already in place — the guest rules in `DECISIONS.md` apply in full. On the owner's
  own Mac `lowpowermode` is already `1` on both sources, so a naive "restore the default"
  would undo his setup; we would write nothing at all there.
* Re-read at restore time. If the value is no longer what *we* set, the user or another app
  changed it after us: leave it alone and log the fact.

## UI copy rule

**No numbers in the interface.** The label warns in plain words that the mode trades speed for
battery life. No multipliers, no benchmark citations — they would imply a precision the
measurement does not have. The measured figures stay in `docs/` for engineers.

Shipped strings:

* Checkbox — `Save battery while the lid is closed`
* Explanation — `Slows your Mac down to use less battery. Your agent will take longer to finish.`
* Tooltip — `Trade speed for battery life while the lid is closed`

## Scheduling

This is not M1 scope. M1 writes **zero** settings, which keeps the first shippable milestone's
uninstall guarantee trivially true (`pmset -g custom` before and after is byte-identical). Low
Power Mode lands with the settings window, together with the snapshot/restore ledger for
third-party-owned values, and its own before/after disclosure in the diff UI.
