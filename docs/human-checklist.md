# Things only a human with a Mac can do

Batched deliberately. Every item states the exact command and what you should see, so none of
them needs a conversation. Send back the raw output, not a summary — a summary of a failed run
usually reads like a passed one.

Nothing here blocks development. Work continues on everything that does not depend on an
answer.

---

## H0 — USPTO trademark search for "Lidwing" · 2 minutes · **before the first published build**

The public search that replaced TESS needs a browser session, so it cannot be run from the
Linux box. Every other registry is already clear (Mac App Store, iOS App Store, npm, PyPI,
GitHub, DNS — see `docs/decisions/0007-name-availability-check.md`).

1. Open <https://tmsearch.uspto.gov/>.
2. Basic word mark search, term: `lidwing`.
3. Repeat with `lid wing` (two words).

**Report:** the result count for each, and the goods-and-services class of anything that comes
back. Zero results in both is the expected answer.

**Why it matters, and why it is not urgent:** if the name is contested, the only strings that
change live in `Constants.swift` and `Package.swift`. That is cheap today. It stops being cheap
the moment a build is published, because the marker Lidwing writes into
`~/.claude/settings.json` contains the bundle path — a rename after that means shipping a
migration that edits other people's config files.

---

## H1 — M0 step 0: read-only sanity · 1 minute · **first**

```bash
git clone git@github.com:denti/flymyai-wing.git ~/lidwing-repo
cd ~/lidwing-repo
swiftc -O -o /tmp/wingprobe spike/wingprobe.swift
/tmp/wingprobe verify
```

**Expected:**

```
    IOPMrootDomain user client openable : yes
    AppleClamshellState present         : yes (portable)
    uid                                 : 501  (non-zero means no root was needed)
```

This command reads and mutates nothing. `swiftc` should print no warnings; if it prints errors,
send them — the file is compiled by Xcode 16.4 on your machine and by nothing on mine.

**Send:** the whole output.

---

## H2 — M0 short form: the go/no-go · 5 minutes including the lid close · **blocking**

Disconnect every external display, dock and HDMI/DP dongle first. The script refuses to run
otherwise, and it is right to: macOS already keeps a lid-closed Mac awake with an external
display on AC, so a pass in that configuration would prove nothing.

```bash
cd ~/lidwing-repo
./spike/m0-run.sh --short
```

It prints `>>> CLOSE THE LID NOW <<<`. Close the lid, wait two minutes, open it.

**Expected if the mechanism works:** the Mac is still awake when you open the lid (no login
window, no wake animation), and the terminal ends with:

```
verdict:        PASS
max_gap_s:      1
sleep_delta:    0
darkwake_delta: 0
```

**Expected if it does not:** you get the login window, and `verdict: FAIL` with `max_gap_s`
close to 120.

**Send:** `docs/m0/short-mecha-<timestamp>/` — the whole directory, zipped. The raw logs are the
result.

Whatever happens, the machine is left exactly as it was found: mechanism A writes nothing that
survives a reboot, and the kernel initialises the bit to zero at boot. If you want to check:
`ioreg -r -c IOPMrootDomain -d 1 | grep -E 'SleepDisabled|AppleClamshell'`.

---

## H3 — M0 soak: the real evidence · 8 hours, mostly unattended · **blocking**

Only after H2 passes. Start it in the evening. On battery if the battery is above 80 %,
otherwise on AC — and tell me which, because it changes what the result proves.

```bash
cd ~/lidwing-repo
./spike/m0-run.sh --soak
```

Close the lid when it says to. If you are near the machine during the evening, plug and unplug
the charger five times, spaced out over the run — that is the re-assert test.

**Expected in the morning:** the Mac is awake, and `verdict.txt` says `PASS` with
`heartbeats: 480 of ~480`, `sleep_delta: 0`, `darkwake_delta: 0`.

**Send:** the whole output directory.

**If it shows one to three sleeps:** that is the worst case, not the best — it means the icon
would sometimes be lying. Do not run it again hoping for a clean one; send it and I will
escalate, because whether to ship a stronger method or narrow the promise is your call, not an
engineering one.

---

## H3a — Get a build, without publishing anything · 2 minutes

Every green CI run uploads a signed `.dmg`. No GitHub Release is created and nothing about the
product is public — the repository still has a one-line README, no description and no topics,
exactly as agreed.

```bash
cd ~/lidwing-repo
gh run download --name "Lidwing-$(git rev-parse HEAD)" --dir ~/Downloads/lidwing
# or, for whatever the newest green run produced:
gh run list --workflow=ci.yml --branch main --limit 5
gh run download <run-id> --dir ~/Downloads/lidwing
open ~/Downloads/lidwing/Lidwing-0.0.0.dmg
```

Drag Lidwing to Applications **in Finder**, not with `mv` — Finder clears the quarantine
attribute and `mv` does not.

**It is ad-hoc signed until the Developer Program enrolment lands (H4)**, so macOS will refuse
the first launch and you will need the six-step System Settings dance in `INSTALL.md`. That is
expected, and it is exactly why H4 matters: with a Developer ID this becomes a double-click.

---

## H3b — Fault injection · 10 minutes · once the app is installed

The unit tests cover the *logic* of dying mid-transition. This covers the *processes*.

```bash
cd ~/lidwing-repo
./Scripts/fault-injection.sh /Applications/Lidwing.app
```

It will ask you twice to turn Lidwing on from the menu and press Return — arming is a
deliberate user action and there is deliberately no way to do it from a script.

**Expected:**

```
RESULT PASS f1.crash-safe  the watchdog restored lid-close sleep after SIGKILL
RESULT PASS f2.recovery-record  recovered.json written: {...}
RESULT PASS f3.survives-corrupt-ledger  the app launched and is running
RESULT PASS f3.no-silent-change  a corrupt ledger changed nothing on the machine
RESULT PASS f4.stands-down  ...   (or f4.watchdog-relaunched)
RESULT PASS f5.stock  AppleClamshellCausesSleep is back to Yes
SUMMARY pass=6 fail=0
```

**`f1.crash-safe` is the one that matters.** It is the assertion standing between a user and a
laptop that cannot sleep in a backpack. If it fails, stop and send me the output before doing
anything else.

The script refuses to start on a machine whose baseline is already non-stock, because a dirty
baseline produces a fake pass.

---

## H4 — Apple Developer Program enrolment · **has multi-week lead time, so start early**

$99/year. Not needed for M0 or for any development, and needed for everything a stranger can
install:

* An unsigned arm64 Mach-O is killed by the kernel on launch; ad-hoc signing is the floor.
* An ad-hoc build passes `codesign --verify` but is rejected by `spctl`, so every user gets the
  six-step System Settings dance instead of a double-click.
* macOS 15 removed the Control-click → Open bypass entirely, and the "Open Anyway" button
  expires about an hour after the blocked launch. A user who opens Settings the next day sees
  nothing and concludes the app is broken.

**Enrol as an organisation** under the FlyMyAI entity if the D-U-N-S lookup is quick. Individual
enrolment puts your personal legal name in front of every user in the Gatekeeper dialog, and it
cannot later become the org account — the Team ID change would force every existing user to
re-approve.

**Decision rule so this cannot stall the project:** if D-U-N-S plus verification is not done
within ten business days, v1 ships source-only, with build-from-source instructions and no
binary release, and we wait. We do not ship a binary under a personal name by default.

**Send:** the Team ID once issued, and I will add the CI secrets list.

---

## H5 — Repository settings · 5 minutes · owner-only

1. Branch protection on `main` (required status checks: `core-linux`, `core-purity`,
   `test-macos`, `lint`).
2. Enable private vulnerability reporting (Settings → Security).
3. Leave the repository description and topics **empty** until the release milestone.

`gh api repos/denti/flymyai-wing/branches/main/protection` returning 200 is the check.

---

---

## H6 — The performance numbers · 5 minutes · once the app is installed

These are published claims, and right now every one of them is a budget rather than a
measurement. `AUDIT.md` says so explicitly instead of quoting the budgets as if they were
results.

```bash
cd ~/lidwing-repo
# Lidwing running, menu closed, doing nothing:
./Scripts/perf-gate.sh
# and a longer one, for memory and file-descriptor growth:
./Scripts/perf-gate.sh --soak 300
```

**Expected:** idle CPU at or below 0.1 %, idle wake-ups at or below 2/s, app memory under
40 MB, watchdog under 8 MB, and no file descriptors accumulating over the soak.

**Send:** the `SUMMARY` line and anything marked `FAIL`. If a number is over budget I would
rather change the code than change the budget, so the raw figure is what matters.

Also worth running once with Lidwing **off**, to confirm `pmset -g assertions | grep -i lidwing`
returns nothing at all. That is the check a suspicious user runs, and it has to pass for them.

---

## H7 — The compatibility smoke test · 2 minutes per machine

Read-only. It never writes a system setting, never asks for root and never arms anything.

```bash
ssh <mac> 'bash -s -- --app /Applications/Lidwing.app' < Scripts/lidwing-smoke.sh
```

**Expected:** `SUMMARY pass=… fail=0 skip=…`. The skips are the point — a lid cannot be closed
by a script, and the script says so in every run rather than quietly omitting the line.

---

*Not on this list, deliberately: buying an Intel MacBook, renting monthly Mac hosting, an AWS
account, or a crash-reporting plan. None of them is needed, and the reasoning is in
`ADDENDUM.md` §3.*
