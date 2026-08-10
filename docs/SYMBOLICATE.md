# Turning a crash report into a line number

If Lidwing ever crashes on your Mac, the report is already on your disk and you can read it
yourself. Nothing is uploaded anywhere — Lidwing has no crash reporter and cannot open a network
connection.

## Where the report is

```bash
ls -t ~/Library/Logs/DiagnosticReports/Lidwing*.ips | head
```

That directory is owned by **you**, so every account can read its own reports whether or not it
is an administrator. (The system-wide `/Library/Logs/DiagnosticReports` needs admin rights, but
Lidwing runs as you and never writes there.)

## What to send

The whole `.ips` file, or the first forty lines if you would rather read it first. Before
sending, note that it contains:

* your Mac's **hostname**, in the file name itself — every report is named
  `Lidwing_<timestamp>_<Your-MacBook>.ips`;
* `crashReporterKey`, which is a per-device identifier;
* your username inside any path that appears in a stack frame.

Renaming the file and replacing your username is enough. None of the three is needed to
symbolicate.

## Symbolicating it yourself

Download `Lidwing-<version>-dSYMs.zip` from the release the crash came from. Then:

```bash
# 1. Which slice crashed, and where was it loaded?
#    Look for "slice_uuid" and the load address of the Lidwing image in the report.
grep -o '"slice_uuid":"[^"]*"' Lidwing_*.ips | head -1

# 2. Confirm the dSYM matches. A universal binary has a DIFFERENT debug UUID per
#    architecture, and the report matches exactly one of them - which is why the release
#    ships the whole fat dSYM rather than a thinned one.
dwarfdump --uuid Lidwing.app.dSYM/Contents/Resources/DWARF/Lidwing

# 3. Symbolicate an address.
atos -arch arm64 \
     -o Lidwing.app.dSYM/Contents/Resources/DWARF/Lidwing \
     -l <load address from the report> \
     <address from the frame>
```

### Worked example

A frame in a report looks like this:

```
0   Lidwing    0x0000000104a1c3f4 0x104a14000 + 33780
```

The second column is the address, the third is the image's load address. So:

```bash
atos -arch arm64 -o Lidwing.app.dSYM/Contents/Resources/DWARF/Lidwing \
     -l 0x104a14000 0x0000000104a1c3f4
```

which prints something like:

```
LidwingCore.StateMachine.onReconcile() -> [LidwingEffect] (in Lidwing) (StateMachine+Transitions.swift:281)
```

## If the dSYM does not match

`dwarfdump --uuid` prints two UUIDs, one per architecture, and neither matches the report's
`slice_uuid`. That means the dSYM is from a different build. Check the version in the report's
header against the release you downloaded the symbols from; Lidwing's build number is
zero-padded to ten digits, so `0000000142` and `0000000042` are easy to confuse at a glance.

## Reading the log instead

For anything that is not a crash, the log is more useful than a stack trace:

```bash
log show --predicate 'subsystem BEGINSWITH "ai.flymy.lidwing"' --last 2h
```

Every line is at `notice` or above on purpose, so this command shows everything Lidwing has to
say without `--info` or `--debug`. The events, their levels and the fields each one records are
listed in `Sources/LidwingCore/LogEvent.swift`, which is the same file the code reads them from
— there is no second list to drift out of date.
