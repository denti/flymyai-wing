# 0003 — Deployment floor: macOS 12.0

**Status:** accepted · **Date:** 2026-08-10

## Conflict

| Source | Floor | Reason given |
|---|---|---|
| `DECISIONS.md` (Denis) | "roughly the last 5-8 years", i.e. ~10.14 | Broad compatibility is the ambition |
| `DESIGN.md` §6.1 | 12.0 | SwiftPM emits a **weakly linked** concurrency runtime below 12.0 |
| `CRAFT.md`, `ADDENDUM.md` §1.1 | 13.0 | `SMAppService` is `API_AVAILABLE(macos(13.0))` |

## Decision

**`LSMinimumSystemVersion = 12.0`.**

The 13.0 floor was derived entirely from `SMAppService`, and `SMAppService` was needed only to
install a **privileged helper**. Decision 0002 removed the privileged helper. What remains that
would have needed it is the unprivileged watchdog LaunchAgent, and that has a documented
pre-13 path: write the plist to `~/Library/LaunchAgents` and `launchctl bootstrap gui/$UID`,
with no dialog and no admin rights. So the 13.0 floor no longer has a reason to exist.

The 12.0 floor does, and it is not a preference — it is a crash. Verified on the authoring
machine with Xcode 16.4 / Swift 6.1.2:

```
-target x86_64-apple-macos11.0 :  @rpath/libswift_Concurrency.dylib  ... weak
                                  LC_RPATH: /usr/lib/swift          <- dylib NOT in the OS at 11.x
-target x86_64-apple-macos12.0 :  /usr/lib/swift/libswift_Concurrency.dylib   (hard, no rpath)
```

At a macOS 11 target SwiftPM weakly links the concurrency runtime and does **not** embed the
back-deployment dylib (Xcode's build system does; SwiftPM does not). The app launches on
macOS 11 and then dies with `EXC_BAD_ACCESS` at address 0 on the first `await` — a
random-looking crash on exactly the OS versions a low floor exists to reach. The SDK agrees:
`SwiftConcurrencyMinimumDeploymentTarget => 12.0`.

Three further reasons, any one sufficient:

* arm64 is silently clamped to `minos 11.0` regardless of `-target`, so anything below 11 only
  ever helps Intel.
* `async`/`await` is a hard compile error below 10.15, so a 10.14 floor means callbacks
  everywhere, in a product whose correctness rests on ordering.
* Xcode 26 — the only Xcode on the `macos-26` runner image — has a minimum deployment target of
  macOS 11. A 10.15 floor has a hard CI expiry date.

## What this gives Denis, honestly

It goes as low as the toolchain can go without shipping a binary that crashes. It does **not**
reach 10.14/10.15. Machines that old cannot run a Swift-concurrency binary built by any
supported toolchain, and shipping one that installs and then crashes reads as "broken", not as
"unsupported".

## Support claims

Per the mission rule *never claim support for a version you have not run the acceptance suite
on*, the public claim is exactly:

* **12.0–12.7 Monterey** — builds and runs; watchdog installed via `launchctl bootstrap`.
  Untested on hardware until a machine exists.
* **13.x, 14.x, 15.x** — full support once the acceptance suite has run there.
* **26.x** — same code, runtime feature-probe gates the claim; "verified" only after a run.
* **27+** — probe and degrade. Never assume.

Anything without a green acceptance run says **untested**, in those words.
