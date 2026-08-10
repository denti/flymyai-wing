# Security

## Reporting

Use GitHub's **private vulnerability reporting** on this repository (Security → Report a
vulnerability). Please do not open a public issue for anything that touches power state or the
files Lidwing writes.

No response-time commitment is made here, deliberately. A missed one is a public broken
promise, and this is a one-person project.

## What there is to attack

Lidwing is unusually small as a target, and that is a design decision rather than an accident.

* **No root, anywhere.** There is no privileged helper, no LaunchDaemon, no `setuid` binary and
  no admin prompt. The mechanism is `IOPMrootDomain` selector 12, whose dispatch entry has no
  privilege check, so an ordinary user process can call it. Nothing in this product runs as
  anyone but you.
* **No network.** The app is signed with **no entitlements at all**, so it has no
  `com.apple.security.network.client` and cannot open an outbound connection. Check it on the
  file you downloaded, before running it: `codesign -d --entitlements - /Applications/Lidwing.app`
  prints nothing.
* **No permissions.** Zero `*UsageDescription` keys in `Info.plist`. No Accessibility, no Full
  Disk Access, no Screen Recording, no Automation. `plutil -p …/Info.plist | grep -i Usage`
  returns nothing.
* **No third-party dependencies.** `Package.swift` has an empty `dependencies` array. The whole
  supply chain is this repository and the Swift toolchain.

## The three surfaces that do exist

### 1. `control.sock` — the watchdog channel

`~/Library/Application Support/Lidwing/control.sock`, mode `0600`, `AF_UNIX`. The app connects
to it; the watchdog listens. A peer on this socket can tell the watchdog that the app armed the
machine, which at worst causes the watchdog to **clear** the clamshell bit — the safe direction.
It cannot cause anything to be armed. Messages are version-tagged JSON and anything unrecognised
is discarded rather than guessed at.

### 2. `notify.sock` — the coding-agent channel

Mode `0600`, inbound only. **Invariant I8: a message on this socket can never arm anything.**
That is enforced structurally rather than by convention: `NotifyServer` holds no reference
through which it could reach the state machine, and there is a test that walks its stored
properties and asserts so. Its only permitted effects are a sound, a user notification and a
menu indicator. Bodies are truncated to 200 characters, control characters are stripped, and the
source field is checked against a fixed list before it can reach a notification title.

Anyone who can write to that socket is already running code as you, so no privilege is gained.

### 3. The files Lidwing writes into other people's configuration

`~/.claude/settings.json` and `~/.codex/config.toml`, and only with an explicit click after the
literal diff has been shown. A hostile `settings.json` could point Claude Code's hook at
anything — but anyone who can write that file can already run arbitrary code as you, so again no
privilege is gained. `lidwing-notify` never elevates, never parses beyond 4 KB, and always exits
0.

## The failure mode that actually matters

Not privilege escalation. **A Mac left unable to sleep with the user not knowing why.** Four
independent mechanisms prevent it, and the last one does not depend on our code running at all:

1. The watchdog sees the app's death as EOF within milliseconds and clears the bit.
2. `launchd` restarts the watchdog if it dies, and it reconciles from a marker file at startup.
3. **The kernel initialises `clamshellSleepDisableMask` to zero at every boot.** A restart
   always clears it, even if Lidwing has already been deleted. There is nothing durable to undo.
4. If the watchdog ever does clean up after us, it leaves a record the app reads at its next
   launch, so the explanation survives the death of the process that noticed.

This is the central argument for the mechanism Lidwing uses over `pmset disablesleep`, which
persists in a root-owned file across reboots and disables the machine's own low-battery and
thermal emergency sleep. See `docs/decisions/0002-mechanism-authority.md`.

## Verifying a build

```bash
spctl -a -vvv -t exec /Applications/Lidwing.app     # notarized Developer ID
codesign -dv --verbose=4 /Applications/Lidwing.app  # hardened runtime, real Team ID
codesign -d --entitlements - /Applications/Lidwing.app   # nothing
shasum -a 256 Lidwing-*.dmg                         # matches the release notes
gh attestation verify Lidwing-*.dmg --repo denti/flymyai-wing
```

The checksum in the release notes is generated from the artifact **after** stapling, because
stapling rewrites the disk image. A hash taken before it would be wrong for every downloader.
