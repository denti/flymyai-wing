# Scripts

| Script | What it does | Where it runs |
|---|---|---|
| `check.sh` | The pre-push gate: workflows, core purity, build with warnings as errors, tests, lint. | Linux, via Docker |
| `check-core-purity.sh` | Fails if `LidwingCore` imports anything platform-specific or spawns a process. | anywhere |
| `build.sh` | Two single-arch release builds, `lipo`, assembles `Lidwing.app`, generates the icon. | macOS |
| `sign.sh` | Inside-out signing. Takes a Developer ID identity, or `-` for ad-hoc. | macOS |
| `notarize.sh` | `notarytool submit --wait` then `stapler`. Needs an App Store Connect API key. | macOS |
| `package.sh` | `.dmg` and `.zip`, plus `SHA256SUMS.txt`. | macOS |
| `invariants.sh` | Assertions about the built artifact: universal, `minos`, hardened, no usage descriptions, no network entitlement. | macOS |
| `icon/main.swift` | Renders the app icon from the same wing geometry the menu bar uses. | macOS |

## One-time setup on the Linux box

The gate uses two container images and one binary:

```bash
docker pull swift:6.0
docker pull ghcr.io/realm/swiftlint:latest
curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash \
  | bash -s -- latest /tmp
```

Then `./Scripts/check.sh` reproduces everything CI checks except the macOS build itself.
