# 0006 — The repository is public, and the README stays empty until the product works

**Status:** accepted · **Date:** 2026-08-10

## Conflict

`DECISIONS.md` "Process" says: *"Repo: `denti/flymyai-wing`, private (may go public later)."*

`ADDENDUM.md` §0.1 reports the opposite as a verified fact: `GET /repos/denti/flymyai-wing`
returns `"private": false, "visibility": "public", "size": 0`.

## Decision

The repository **is** public. `ADDENDUM.md` wins here because it is a measurement of the world
rather than an opinion about it, and the measurement is trivially re-runnable:

```
gh api repos/denti/flymyai-wing --jq '{private,visibility,size}'
```

Two consequences follow, and both are load-bearing.

### 1. GitHub Actions macOS minutes are free and unlimited

On a private Free-plan repository the same seven-minute cycle drains the 70 included minutes at
the 10× macOS rate and caps the month at roughly 28 builds. An autonomous agent debugging a
compile error blind exceeds that in an afternoon. On a public repository there is no cap, so
the development loop is: push, read the failure, push again — which is the only loop available
from a Linux box with no macOS SDK.

### 2. The repository content is the product announcement, whether we mean it to be or not

Denis's instruction is explicit: he does not want it obvious what is being built before it is
real. So:

* **`spec/` is never committed.** The five specification documents live at
  `/home/denti/lidwing/spec/`, outside the working copy. They are the full product pitch — far
  more revealing than any README. `.gitignore` carries `spec/` defensively even though nothing
  in the working copy could match it.
* **`README.md` is one line** that says nothing, until the product works. The real README, with
  the trust badges, the measured performance numbers and the four falsify-us commands, is the
  last milestone before release.
* **No repository description, no topics, no tags** until then.
* Code, commit messages, decision records and documentation are written normally and honestly.
  Hiding the product is not the same as obscuring the engineering, and a repository full of
  deliberately vague code would be both useless and a bad signal.

## What "public" costs us

Nothing that matters here, with one exception worth naming: **do not register a self-hosted CI
runner on this repository while it is public.** A fork's workflow can execute code on it. The
default answer for a public repository is GitHub-hosted runners, and they are free.
