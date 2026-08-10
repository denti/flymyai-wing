# 0009 — What gets translated, and what deliberately does not

**Status:** accepted · **Date:** 2026-08-10

## What `CRAFT.md` asks for

Every user-visible string through a localisation call from line one, into a String Catalogue,
with v1 shipping `en`, `ru`, `de`, `fr`, `es`, `zh-Hans`, `ja`, `pt-BR`.

## What ships

**English and Russian, complete.** Every surface a user meets: the menu, the detail line, every
refusal, every notification, every sentence explaining why Lidwing stopped by itself, the
settings window, the first-run screens, the uninstall confirmation and the integration diffs.
The catalogue-coverage test fails until the last key is translated, so "complete" is checked
rather than claimed.

**Not the other six languages.** I cannot check a translation I cannot read, and shipping six
machine translations of sentences like *"Lidwing turns off at 20%"* — where a mistranslation
means somebody misunderstands when their overnight run will end — is worse than shipping
English. The catalogue is keyed by language and adding one is a data change, so a native
speaker can contribute one without touching a line of logic.

**Not the diagnostics output, deliberately.** `Copy Diagnostics` produces a support artefact
that gets pasted into an issue or a message. A Russian diagnostics dump is harder for whoever
reads it to act on, and its audience is not the user — it is whoever is helping them. It stays
in English, and that is a decision rather than an omission.

## Why the translations are Swift data, not `.lproj` resources

The conventional answer is a localised resource bundle. It is not used here for one specific
reason: this product assembles its own `.app` with `lipo` and `cp` rather than with Xcode's
build system, and a SwiftPM resource bundle would have to be copied by a step in `Scripts/build.sh`
that nobody would notice was missing. **Translations that silently vanish from a shipped build
are worse than translations that do not exist**, because the English fallback looks deliberate
and nobody files a bug about it.

As data in `LidwingCore` they are unit-tested on Linux in the same suite as everything else,
they cannot be dropped by the packaging step, and the two properties that actually matter are
enforced by tests:

* every catalogue covers every key — a partially translated app shows one language in the menu
  header and another in the row below it, which reads as a bug in the app;
* every translation keeps the placeholders of its English source — a dropped or renumbered
  specifier is a crash or a wrong number at runtime, in strings that are mostly about battery
  and time limits.

If the app ever moves to an Xcode build, this decision should be revisited: `.xcstrings` is the
better long-term home, and the migration is mechanical because every string already lives
behind one call with a stable key.

## The two rules that outlive any particular language

1. **Never build a sentence from fragments.** `"Lidwing is " + state` cannot be translated and
   cannot be read naturally by a screen reader.
2. **Interpolation is always positional** (`%1$@`, `%2$lld`). A test proves it works by
   supplying a Russian translation that puts the process id before the application name; with
   non-positional specifiers that would be impossible, and nobody would notice until a
   translated build was already out.
