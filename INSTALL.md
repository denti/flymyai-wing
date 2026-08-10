# Installing Lidwing

**Right now, every build is the unsigned one.** The Apple Developer Program enrolment has not
completed, so start at [The unsigned build](#the-unsigned-build-development-only) below — six
steps, once. The signed path is written down because it is what shipping looks like, not
because it is what you will get today.

Two paths. Which one you get depends on whether the build you downloaded was signed by Apple's
Developer Program, and the difference is six steps.

---

## The signed build (the shipping path)

1. Open `Lidwing-<version>.dmg`.
2. Drag **Lidwing** onto **Applications**.
3. Open Applications and double-click **Lidwing**.

That is all of it. A wing appears in your menu bar. Lidwing asks for no password and no
permissions, and it opens no window at launch.

**Drag it in Finder, not with `mv` in Terminal.** Finder clears the quarantine attribute;
`mv` does not, and macOS 27 refuses to load a background helper whose plist still carries it.

**It must live in `/Applications`.** If you run it from `~/Downloads` while it is still
quarantined, macOS runs it from a randomised, read-only path that disappears the moment the app
quits — and the safety watchdog would be pointing at a mount that no longer exists. Lidwing
detects this and tells you to move it rather than pretending to work.

---

## The unsigned build (development only)

Until the Apple Developer Program enrolment completes, builds are ad-hoc signed. They run, but
Gatekeeper does not recognise them, and **macOS 15 removed the Control-click → Open shortcut
entirely**. The only path left is:

1. Open the DMG and drag Lidwing to Applications.
2. Open Applications and double-click **Lidwing**. macOS refuses. Click **Done**.
3. **Within the next hour**, open **System Settings → Privacy & Security** and scroll to the
   **Security** section at the bottom.
4. Next to *"Lidwing was blocked…"*, click **Open Anyway**.
5. Click **Open** to confirm, then enter your Mac password.
6. The wing appears in your menu bar. You do this once.

**If step 3 shows nothing**, double-click the app again first. Apple documents that the button
appears for about an hour after a blocked launch, so a user who opens Settings the next day
sees an empty panel and concludes the app is broken.

The password in step 5 is Gatekeeper's, not ours. Lidwing never asks for a password, and it
never sees one.

---

## Verifying what you downloaded

Every claim Lidwing makes should be one command away from being falsified. These four are the
ones worth running before you trust it:

```bash
# 1. Apple signed and notarized this exact binary (signed builds only).
spctl -a -vvv -t exec /Applications/Lidwing.app

# 2. It declares no permissions at all. This returns nothing.
plutil -p /Applications/Lidwing.app/Contents/Info.plist | grep -i UsageDescription

# 3. It cannot open a network connection. There is no network entitlement to find.
codesign -d --entitlements - /Applications/Lidwing.app

# 4. When it is on, it says who it is. When it is off, it is not there.
pmset -g assertions | grep -i lidwing
```

The third one is the structural proof of the no-telemetry claim: it is checkable offline, on
the file you downloaded, before you ever run it.

---

## What it changes on your Mac

One kernel flag, and it is not stored anywhere:

* **While Lidwing is on**, it sets the clamshell sleep-disable bit on `IOPMrootDomain` and holds
  a named power assertion. `ioreg -r -c IOPMrootDomain -d 1 | grep AppleClamshellCausesSleep`
  reports `No` while it is on and `Yes` while it is off.
* **It never writes `pmset disablesleep`.** That setting is stored in a root-owned file, it
  survives a restart, and it disables your Mac's low-battery and thermal *emergency* sleep as
  well. Lidwing's flag does none of those things: it leaves both emergencies armed, and the
  kernel resets it to zero at every boot.
* **It writes no `pmset` settings at all.** `diff` of `pmset -g custom` before and after a full
  on/off cycle is empty.

Its own files live in one directory, `~/Library/Application Support/Lidwing`, holding a socket,
an intent record and a log of past sessions. Nothing else, anywhere.

---

## Uninstalling

**Lidwing → Uninstall Lidwing…** in the menu. It shows you every path it will touch before it
touches anything, then removes them in an order that can never leave your Mac unable to sleep,
verifies the result, and reveals the app in Finder so you can drag it to the Trash.

By hand, if you prefer:

```bash
# 1. Quit Lidwing from its menu. That alone restores lid-close sleep.
# 2. Remove the background helper and its own files.
launchctl bootout "gui/$(id -u)/ai.flymy.lidwing.watchdog" 2>/dev/null
rm -f  ~/Library/LaunchAgents/ai.flymy.lidwing.watchdog.plist
rm -rf ~/Library/Application\ Support/Lidwing
rm -f  ~/Library/Preferences/ai.flymy.lidwing.plist
# 3. Drag /Applications/Lidwing.app to the Trash.
```

Then check that nothing is left:

```bash
find ~/Library /Library -iname '*lidwing*' 2>/dev/null
```

**If your Mac still will not sleep when you close the lid, restart it.** The flag Lidwing uses
is a kernel variable that is initialised to zero at every boot, so a restart clears it
unconditionally — even if Lidwing is already in the Trash. There is nothing to repair by hand
and no `sudo` command to run, because there was never anything durable to undo.

---

## Requirements

macOS 12.0 or later, on a MacBook. See the README's compatibility table for exactly which
combinations have been run through the acceptance suite; anything not listed there is marked
**untested**, in those words, rather than implied to work.

Lidwing does nothing useful on a Mac without a lid, and it says so instead of pretending: on a
Mac mini or a Mac Studio the feature is hidden, not merely disabled.
