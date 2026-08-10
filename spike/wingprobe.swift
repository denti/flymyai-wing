// wingprobe — the decisive experiment for Lidwing. Throwaway by design; no product code
// depends on it and nothing here is imported by the app.
//
// The question, stated exactly: does arming `IOPMrootDomain` selector 12
// (`kPMSetClamshellSleepState`, a constant in the public SDK header
// IOKit/pwr_mgt/IOPMLibDefs.h) plus a `PreventUserIdleSystemSleep` assertion keep a MacBook
// running when the lid is physically closed, on battery, with no external display, without
// root?
//
// Everything the research produced is derived from kernel source. Nobody has ever armed the
// bit with in=1 and closed a lid. This program does exactly that, and it is built so that
// every way it can end leaves the machine as it found it.
//
// Safety properties, in order of importance:
//   1. It disarms on every exit path: normal completion, SIGINT, SIGTERM, SIGHUP, an
//      uncaught deadline, and `atexit`.
//   2. It has a hard maximum duration. `arm` without an explicit duration is 90 seconds.
//   3. It never writes a `pmset` setting, never asks for root, and never persists anything
//      that survives a reboot. The kernel initialises the mask to zero in
//      IOPMrootDomain::start(), so even a kernel panic mid-run self-heals on the next boot.
//   4. `status` and `verify` mutate nothing at all.
//
// Build (on the Mac, no Xcode project needed):
//   swiftc -O -o wingprobe spike/wingprobe.swift
//
// Usage:
//   wingprobe status                    read state, mutate nothing
//   wingprobe verify                    check that the mechanism is reachable, mutate nothing
//   wingprobe arm [seconds] [--log P]   arm for N seconds (default 90, max 43200), then disarm
//   wingprobe disarm                    safety valve: clear the bit unconditionally
//
// Exit codes: 0 no sleep observed · 1 a sleep was observed · 2 usage · 3 the mechanism refused

import Foundation
import IOKit
import IOKit.pwr_mgt

// IOKit/pwr_mgt/IOPMLibDefs.h:42  #define kPMSetClamshellSleepState 12
let kPMSetClamshellSleepStateSelector: UInt32 = 12

/// Longest arm this tool will accept. Twelve hours covers the eight-hour soak with room, and
/// refuses a typo that would arm for a week.
let maximumArmSeconds = 43_200

// MARK: - Reading the machine

/// Reads an IORegistry boolean from IOPMrootDomain directly.
///
/// Deliberately not `ioreg` text: parsing it costs 50-100 ms per call, `ioreg -l | grep
/// AppleClamshellState` false-positives on an unrelated NVRAM blob, and `ioreg` prints
/// `18446744073709550889` for a negative amperage. The property API is the only honest read.
func rootDomainBool(_ key: String) -> Bool? {
    let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL),
                                              IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                    kCFAllocatorDefault, 0) else { return nil }
    return (raw.takeRetainedValue() as? NSNumber)?.boolValue
}

func rootDomainString(_ key: String) -> String? {
    let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL),
                                              IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                    kCFAllocatorDefault, 0) else { return nil }
    return raw.takeRetainedValue() as? String
}

func describe(_ value: Bool?) -> String {
    switch value {
    case .some(true): return "Yes"
    case .some(false): return "No"
    case .none: return "(absent)"
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

/// Power source, read through the API rather than by parsing `pmset -g batt`, which silently
/// loses a time estimate the API has.
struct Power {
    let onAC: Bool
    let percent: Int?

    static func read() -> Power {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return Power(onAC: true, percent: nil) }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let state = info[kIOPSPowerSourceStateKey] as? String
            // Never treat CurrentCapacity as a percentage; compute it.
            var percent: Int?
            if let current = info[kIOPSCurrentCapacityKey] as? Int,
               let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percent = Int((Double(current) * 100.0 / Double(maximum)).rounded())
            }
            return Power(onAC: state == kIOPSACPowerValue, percent: percent)
        }
        return Power(onAC: true, percent: nil)
    }
}

/// Sleep and dark-wake counters, from `pmset -g stats`. A shell-out is acceptable here and
/// only here: this is a diagnostic tool, not the product, and there is no API for these.
func sleepCounters() -> (sleep: Int?, darkWake: Int?) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g", "stats"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return (nil, nil) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""

    func count(_ label: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains(label) {
            let digits = line.split(whereSeparator: { !$0.isNumber })
            if let last = digits.last { return Int(last) }
        }
        return nil
    }
    return (count("Sleep Count"), count("Dark Wake Count"))
}

// MARK: - The arming half

/// Owns the mutation. Exactly one instance exists, and every exit path goes through `disarm`.
final class Armer {
    static let shared = Armer()

    private var connection: io_connect_t = 0
    private var assertionID: IOPMAssertionID = 0
    private(set) var armed = false
    private let lock = NSLock()

    private func openConnection() -> Bool {
        let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL),
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            FileHandle.standardError.write(Data("cannot find IOPMrootDomain\n".utf8))
            return false
        }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else {
            FileHandle.standardError.write(
                Data("IOServiceOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))\n".utf8))
            return false
        }
        return true
    }

    @discardableResult
    private func setClamshell(_ disabled: Bool) -> kern_return_t {
        var input: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(connection, kPMSetClamshellSleepStateSelector,
                                         &input, 1, nil, nil)
    }

    /// Clears the bit without ever setting it. The safety valve: it exists for the case where
    /// a previous run was killed in a way that defeated every net in this file.
    func forceClear() -> kern_return_t {
        lock.lock()
        defer { lock.unlock() }
        guard openConnection() else { return KERN_FAILURE }
        let kr = setClamshell(false)
        IOServiceClose(connection)
        connection = 0
        return kr
    }

    /// Opens the user client and returns immediately without changing anything. Used by
    /// `verify` to answer "is the mechanism reachable at all on this OS?" read-only.
    func probeReachable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openConnection() else { return false }
        IOServiceClose(connection)
        connection = 0
        return true
    }

    func arm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openConnection() else { return false }

        // Half one: stop the ordinary idle-sleep timer. powerd reaps this automatically if we
        // die, which is why it is not the dangerous half.
        let assertionResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "wingprobe experiment" as CFString,
            &assertionID)
        if assertionResult != kIOReturnSuccess {
            print("    WARNING: idle assertion failed: 0x\(String(UInt32(bitPattern: assertionResult), radix: 16))")
        }

        // Half two: stop the clamshell demand sleep. Nothing in the kernel releases this on
        // process death — RootDomainUserClient::clientClose() only calls terminate() — which
        // is the entire reason this file is so careful about exit paths.
        let kr = setClamshell(true)
        guard kr == KERN_SUCCESS else {
            print("    FAILED: selector 12 returned 0x\(String(UInt32(bitPattern: kr), radix: 16)) — the mechanism is refused here")
            if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
            IOServiceClose(connection)
            connection = 0
            return false
        }
        armed = true
        return true
    }

    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 {
            let kr = setClamshell(false)
            print("[\(stamp())] disarmed clamshell bit (kr=0x\(String(UInt32(bitPattern: kr), radix: 16)))")
            IOServiceClose(connection)
            connection = 0
        }
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        armed = false
    }
}

func stamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

// MARK: - Exit safety

var signalSources: [DispatchSourceSignal] = []

func installSafetyNets() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            print("\n[\(stamp())] signal \(sig) — disarming")
            Armer.shared.disarm()
            exit(1)
        }
        source.resume()
        signalSources.append(source)
    }
    // Last line of defence. Runs on any `exit`, including one we did not anticipate.
    atexit {
        Armer.shared.disarm()
    }
}

// MARK: - Reporting

func printStatus(_ label: String) {
    let power = Power.read()
    let counters = sleepCounters()
    print("[\(stamp())] \(label)")
    print("    AppleClamshellState        = \(describe(rootDomainBool("AppleClamshellState")))   (Yes = lid closed)")
    print("    AppleClamshellCausesSleep  = \(describe(rootDomainBool("AppleClamshellCausesSleep")))   (No = we are protected)")
    print("    SleepDisabled              = \(describe(rootDomainBool("SleepDisabled")))   (we never set this; must stay No or absent)")
    print("    DesktopMode                = \(describe(rootDomainBool("DesktopMode")))")
    print("    power source               = \(power.onAC ? "AC" : "battery")\(power.percent.map { ", \($0)%" } ?? "")")
    print("    Sleep Count                = \(counters.sleep.map(String.init) ?? "?")")
    print("    Dark Wake Count            = \(counters.darkWake.map(String.init) ?? "?")")
    print("    boot session               = \(sysctlString("kern.bootsessionuuid") ?? "?")")
}

// MARK: - Main

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "status"

switch command {
case "status":
    printStatus("STATUS (read-only)")

case "verify":
    // Answers "can this OS still do it?" without arming. This is the runtime probe the app
    // itself performs at launch, and it must never probe by arming.
    printStatus("VERIFY (read-only)")
    let reachable = Armer.shared.probeReachable()
    let hasClamshellKey = rootDomainBool("AppleClamshellState") != nil
    print("")
    print("    IOPMrootDomain user client openable : \(reachable ? "yes" : "NO")")
    print("    AppleClamshellState present         : \(hasClamshellKey ? "yes (portable)" : "no (lidless, or not reported yet)")")
    print("    uid                                 : \(getuid())  (non-zero means no root was needed)")
    exit(reachable ? 0 : 3)

case "disarm":
    // The safety valve. Deliberately unconditional, and it never arms on the way through.
    printStatus("BEFORE forced disarm")
    let kr = Armer.shared.forceClear()
    print("[\(stamp())] forced clear, kr=0x\(String(UInt32(bitPattern: kr), radix: 16))")
    printStatus("AFTER forced disarm")
    exit(kr == KERN_SUCCESS ? 0 : 3)

case "arm":
    var seconds = 90
    var logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("wingprobe-heartbeat.log").path
    var index = 2
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--log", index + 1 < arguments.count {
            logPath = arguments[index + 1]
            index += 2
        } else if let parsed = Int(argument) {
            seconds = parsed
            index += 1
        } else {
            print("unknown argument: \(argument)")
            exit(2)
        }
    }
    guard seconds > 0, seconds <= maximumArmSeconds else {
        print("duration must be 1...\(maximumArmSeconds) seconds")
        exit(2)
    }

    let beforeCounters = sleepCounters()
    printStatus("BEFORE")
    print("")
    print("Arming for \(seconds)s. Heartbeat log: \(logPath)")

    installSafetyNets()
    guard Armer.shared.arm() else { exit(3) }
    print("[\(stamp())] ARMED: clamshell bit set + idle-sleep assertion held")

    // The mechanism returns success while doing nothing. The only acceptance signal is the
    // machine's own answer, so wait for it before telling the operator to close the lid.
    var verified = false
    for _ in 0..<20 {
        if rootDomainBool("AppleClamshellCausesSleep") == false { verified = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if verified {
        print("[\(stamp())] VERIFIED: AppleClamshellCausesSleep = No")
    } else {
        print("[\(stamp())] NOT VERIFIED: AppleClamshellCausesSleep did not flip within 2s.")
        print("             Continuing anyway so the run still produces evidence, but treat a")
        print("             pass here with suspicion: the property is refreshed only by")
        print("             kernel clamshell events and may simply be stale.")
    }
    print("")
    print("  >>> CLOSE THE LID NOW. Keep it closed. The tool disarms by itself in \(seconds)s. <<<")
    print("")

    let start = Date()
    var lastTick = Date()
    var maximumGap: Double = 0
    var tickCount = 0
    let deadline = start.addingTimeInterval(TimeInterval(seconds))

    FileManager.default.createFile(atPath: logPath, contents: nil)
    let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
    handle?.write(Data("# wingprobe start=\(stamp(start)) duration=\(seconds)s\n".utf8))

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
    timer.setEventHandler {
        let now = Date()
        // A sleep shows up as a wall-clock gap between two one-second ticks. This is the
        // measurement; everything else in this file is scaffolding around it.
        let gap = now.timeIntervalSince(lastTick)
        if gap > maximumGap { maximumGap = gap }
        lastTick = now
        tickCount += 1

        let lid = describe(rootDomainBool("AppleClamshellState"))
        let protectedNow = describe(rootDomainBool("AppleClamshellCausesSleep"))
        let power = Power.read()
        let line = "\(stamp(now)) gap=\(String(format: "%.2f", gap))s lid_closed=\(lid) " +
                   "causes_sleep=\(protectedNow) power=\(power.onAC ? "ac" : "batt")" +
                   "\(power.percent.map { " pct=\($0)" } ?? "")\n"
        handle?.write(Data(line.utf8))

        guard now >= deadline else { return }
        timer.cancel()
        print("")
        print("[\(stamp())] window over")
        Armer.shared.disarm()
        let afterCounters = sleepCounters()
        printStatus("AFTER")
        try? handle?.close()

        func delta(_ before: Int?, _ after: Int?) -> Int? {
            guard let before, let after else { return nil }
            return after - before
        }
        let sleepDelta = delta(beforeCounters.sleep, afterCounters.sleep)
        let darkDelta = delta(beforeCounters.darkWake, afterCounters.darkWake)

        print("")
        print("=== RESULT ===")
        print("  ticks recorded      : \(tickCount) (expected ~\(seconds))")
        print("  largest gap         : \(String(format: "%.1f", maximumGap))s")
        print("  Sleep Count delta   : \(sleepDelta.map(String.init) ?? "?")")
        print("  Dark Wake delta     : \(darkDelta.map(String.init) ?? "?")")
        print("  ground truth verified at arm : \(verified)")

        // PASS needs all three to agree. A small gap with a non-zero sleep count is a sleep
        // that happened to be short, and it still means the mechanism did not hold.
        let gapOK = maximumGap < 5
        let countersOK = (sleepDelta ?? 0) == 0 && (darkDelta ?? 0) == 0
        if gapOK && countersOK {
            print("  VERDICT: PASS — no sleep observed, and the kernel's own counters agree.")
            exit(0)
        } else if gapOK {
            print("  VERDICT: FAIL — the heartbeat was continuous but a sleep counter moved.")
            print("           A sleep short enough to hide between ticks is still a sleep, and")
            print("           both known holes in the mechanism only open after the first one.")
            exit(1)
        } else {
            print("  VERDICT: FAIL — a gap of \(String(format: "%.0f", maximumGap))s. The Mac slept.")
            exit(1)
        }
    }
    timer.resume()
    dispatchMain()

default:
    print("usage: wingprobe [status | verify | arm SECONDS [--log PATH] | disarm]")
    exit(2)
}
