# 0008 — When Lidwing makes a sound

**Status:** accepted · **Date:** 2026-08-10

## Conflict

`DESIGN.md` §4d: *"The arm chime fires on the **arm action** (deliberate, machine definitely
awake), not on lid close."* Its reason is a real race: `IOPM.h` documents that if a clamshell
change results in a sleep, the sleep initiates soon *after* the message, so a chime fired from
that handler competes with the machine going down.

`CRAFT.md` §6.1: *"Never play a sound for something the user can see… Always play for something
they cannot."* Toggling from the menu with the lid open plays nothing; lid close while armed is
unconditional.

`DECISIONS.md` §7, which outranks both: *"Audible confirmation on lid close. If protection is
ON and the user closes the lid, play a simple sound so they know the Mac is still running."*

## Decision

**On lid close while protecting, and on standing down while the lid is closed. Nothing else.**

`DECISIONS.md` is explicit and it agrees with `CRAFT.md`, so the only question left is whether
`DESIGN.md`'s race objection defeats them. It does not, and the reason is specific to this
product rather than a general preference:

The chime fires from the clamshell handler **only when we are already `armed` or `degraded`** —
that is, only when the mechanism has been verified against the machine's own state within the
last five seconds. In that state no sleep is coming, so there is no sleep for the chime to race.
In the state where `DESIGN.md`'s race is real — the lid closing while we are *not* protecting —
we play nothing at all, which is also what the user should hear.

Where a race can still occur is the case the product treats as a hard failure anyway: the lid
closes, we believe we are armed, and the machine sleeps regardless (hole A or hole B). There the
chime may be cut short. That is acceptable: a truncated sound in the one scenario that is
already recorded as `SLEPT_WHILE_ARMED` and reported to the user by name and timestamp.

## The grammar, complete

| Moment | Sound | Why |
|---|---|---|
| Lid closes while protecting | `Submarine` (1.49 s) | Low, descending, "sealed and running deep". The one that matters. |
| We stand down while the lid is closed | `Bottle` | The Mac is about to sleep normally, and the user cannot see the screen to learn that. |
| Anything failed | `Basso` | The macOS "no" sound for twenty years. Never invent one. |

Nothing else makes a sound. Not the menu opening, not the checkbox, not launch, not quit with
the lid open, not arming, not disarming with the lid open.

## Routing, and why it is not a detail

* Confirmations go through `AudioServicesPlayAlertSoundWithCompletion` — the **alert** path — so
  they follow the user's Alert volume slider and their chosen alert output device.
  `NSSound.play()` would send them at *media* volume to the *default* output, ignoring both.
* The failure sound uses `AudioServicesPlaySystemSoundWithCompletion` with
  `kAudioServicesPropertyIsUISound = 0`, which the header documents as audible regardless of the
  user's sound-effects setting. A failure has to land even for someone who turned interface
  sounds off.
* **Never `UNUserNotificationCenter`.** Its sound is suppressed by Focus and Do Not Disturb, and
  this product's user has a Focus mode on *while the agent runs* — exactly when the lid-close
  sound must arrive. `UNNotificationSound.defaultCritical` is iOS and watchOS only, and the
  critical-alert entitlement is granted by written application and effectively never to a
  utility. Direct playback by our own process is not gated by Focus and needs no permission.
* Every sound id is created once at launch with
  `kAudioServicesPropertyCompletePlaybackIfAppDies = 1`. Creating one at lid-close time would
  add a disk read to the single event that has to be immediate.
* Stock system sounds only. A bundled whoosh or marimba marks an app as cross-platform in one
  note.

## The rule that follows

**Sound is never the sole confirmation.** Bluetooth output may have disconnected as the lid
closed, the route may have moved to a display's speakers, the volume may be zero. The on-screen
state is authoritative whenever the screen returns; the sound is a courtesy that must be assumed
lost. That is why the menu header carries the full session state in words, and why the failure
path writes a record rather than relying on anyone having heard anything.
