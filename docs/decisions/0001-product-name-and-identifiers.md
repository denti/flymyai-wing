# 0001 — Product name and identifiers

**Status:** accepted · **Date:** 2026-08-10

## Conflict

The specification set disagreed with itself about what this product is called.

| Source | Product name | Bundle id | Helper label |
|---|---|---|---|
| `DESIGN.md` §1.4 (frozen) | `Lidwing` | `ai.flymy.lidwing` | `ai.flymy.lidwing.helper` |
| `CRAFT.md` §0 | `Wing` | `ai.flymy.Wing` | `ai.flymy.Wing.Helper` |
| `ADDENDUM.md` | `Wing` | `ai.flymy.wing` | `ai.flymy.wing.helper` |
| `DECISIONS.md` (Denis, process notes) | `Wing` | `ai.flymy.wing` | — |

Three different capitalisations of the same reverse-DNS identifier appear across the set
(`ai.flymy.Wing`, `ai.flymy.wing`, `ai.flymy.lidwing`). launchd labels, code-signing
requirements and the marker written into third-party config files all key on this string
exactly.

## Decision

`DESIGN.md` §1.4 wins, as the mission brief directs. The frozen list is:

```
Product name        Lidwing
App bundle id       ai.flymy.lidwing
Watchdog agent      ai.flymy.lidwing.watchdog
Privileged helper   ai.flymy.lidwing.helper       (Tier 3 only)
Boot reconciler     ai.flymy.lidwing.reconciler   (Tier 3 only)
Mach service        ai.flymy.lidwing.helper
Marker in 3rd-party configs: an absolute path containing "/Lidwing.app/"
```

The git repository stays `denti/flymyai-wing`; a repository name is not an installed
identifier and renaming it would break the remote for no benefit.

`CRAFT.md` was written before the naming decision and has been corrected in place on the
authoring machine (it lives outside the repository and is never committed). Every craft
requirement in it — icon, menu, sound, accessibility, antipatterns — survives the rename
unchanged.

## Why these strings and not the shorter ones

`Wing` alone is heavily squatted and collides with unrelated software; `Lidwing` names what the
product does, does not promise "never sleeps" (which the battery and thermal guards will
correctly break), and is unique against the Caffeine / Amphetamine / KeepingYouAwake / Theine /
Lungo lineage.

Lowercase throughout the reverse-DNS identifier: `ai.flymy.Wing` mixes cases in a way that is
easy to get wrong in a plist, a launchd label and a signing requirement at the same time, and
those three are compared byte-for-byte in three different places.

## Consequence

`Sources/LidwingCore/Constants.swift` is the single definition of every one of these strings,
and `VersionTests.testIdentifiersAreConsistent` asserts their relationships. A name change
after the first public build would mean shipping a migration that edits other people's
`~/.claude/settings.json`, which is why they are frozen now rather than at release.

A trademark and availability check is tracked separately as escalation trigger T5 and is
recorded in `docs/decisions/0007-name-availability-check.md`.
