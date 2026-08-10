import Foundation
import IOKit
import IOKit.pwr_mgt
import LidwingCore

/// Reads of `IOPMrootDomain`, through the property API.
///
/// Never by parsing `ioreg` text. That costs 50-100 ms per call, `ioreg -l | grep
/// AppleClamshellState` false-positives on an unrelated NVRAM `Stats` blob, and `ioreg` prints
/// `18446744073709550889` for a negative amperage. Shell-outs are permitted only inside the
/// read-only diagnostics panel.
public enum RootDomain {

    /// The default main port. `kIOMainPortDefault` is macOS 12+; its value is
    /// `MACH_PORT_NULL`, and passing that literal works on every version, which keeps this
    /// file free of availability branches.
    public static var mainPort: mach_port_t { mach_port_t(MACH_PORT_NULL) }

    public static func matchingService() -> io_service_t {
        IOServiceGetMatchingService(mainPort, IOServiceMatching("IOPMrootDomain"))
    }

    public static func bool(_ key: String) -> Bool? {
        let service = matchingService()
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.boolValue
    }

    /// `AppleClamshellState`. nil means the key is absent, which on a laptop is a transient
    /// state until the lid driver makes its first report — **not** evidence that the machine
    /// has no lid.
    public static var clamshellState: Bool? { bool("AppleClamshellState") }

    /// `AppleClamshellCausesSleep`. Written only by `sendClientClamshellNotification()`, which
    /// fires on lid, AC and desktop-mode events, so it is stale between events. Arming itself
    /// calls `handlePowerNotification(kLocalEvalClamshellCommand)`, which refreshes it — which
    /// is what makes it usable as the acceptance signal for an arm.
    public static var clamshellCausesSleep: Bool? { bool("AppleClamshellCausesSleep") }

    /// `SleepDisabled`. We never write this. It is read so that launch reconciliation can tell
    /// the user when something else has.
    public static var sleepDisabled: Bool? { bool("SleepDisabled") }

    public static var desktopMode: Bool { bool("DesktopMode") ?? false }

    /// Derives the four-state lid model. `unknown` is deliberately distinct from `noLid`:
    /// coercing a not-yet-reported lid to "this Mac has no lid" would disable the product at
    /// every login.
    public static func lidState(clamshellNotificationSeen: Bool) -> LidState {
        guard let closed = clamshellState else {
            return clamshellNotificationSeen ? .noLid : .unknown
        }
        return closed ? .closed : .open
    }

    public static var bootSessionUUID: String {
        sysctlString("kern.bootsessionuuid") ?? "unknown-boot-session"
    }

    /// Hardware model, for the diagnostics header. Not a serial number and not an identifier.
    public static func sysctlModel() -> String? {
        sysctlString("hw.model")
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Sets and clears `clamshellSleepDisableMask` through `IOPMrootDomain` selector 12.
///
/// One connection is held open for the life of an armed session. Opening it per call would be
/// slower and would make the re-assert loop, which runs every ten seconds, do a service lookup
/// each time for no reason.
public final class ClamshellLock {
    private var connection: io_connect_t = 0
    public private(set) var weSetTheBit = false

    public init() {}

    deinit {
        // Not a substitute for an explicit release — `deinit` does not run on `kill -9`, which
        // is exactly why a separate watchdog process exists — but it closes the honest cases.
        close()
    }

    @discardableResult
    public func open() -> Bool {
        guard connection == 0 else { return true }
        let service = RootDomain.matchingService()
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    /// `true` sets `clamshellSleepDisableMask |= kClamshellDisableSystemSleep`, which makes
    /// `shouldSleepOnClamshellClosed()` return false, which means no
    /// `privateSleepSystem(kIOPMSleepReasonClamshell)` on lid close.
    @discardableResult
    public func set(_ disable: Bool) -> kern_return_t {
        guard connection != 0 else { return KERN_INVALID_ARGUMENT }
        var input: UInt64 = disable ? 1 : 0
        let result = IOConnectCallScalarMethod(connection, kPMSetClamshellSleepStateSelector,
                                               &input, 1, nil, nil)
        if result == KERN_SUCCESS { weSetTheBit = disable }
        return result
    }

    /// Invariant I7. Bit 0x02 is shared with powerd and carries no reference count: clearing it
    /// in a configuration where powerd legitimately wants it set — an external display on AC —
    /// would sleep somebody else's lid-closed machine in the middle of their work.
    @discardableResult
    public func safeRelease(desktopMode: Bool, onAC: Bool) -> kern_return_t {
        guard weSetTheBit else { return KERN_SUCCESS }
        guard !(desktopMode && onAC) else {
            weSetTheBit = false
            return KERN_SUCCESS
        }
        return set(false)
    }

    /// Clears the bit whoever set it. The `weSetTheBit` guard is deliberately absent; the
    /// powerd guard is deliberately not.
    @discardableResult
    public func forceRelease(desktopMode: Bool, onAC: Bool) -> kern_return_t {
        guard !(desktopMode && onAC) else { return KERN_SUCCESS }
        let result = set(false)
        weSetTheBit = false
        return result
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }
}

/// Blocks the ordinary idle-sleep timer.
///
/// Deliberately **not** `PreventUserIdleDisplaySleep`: with the lid shut there is no display to
/// keep awake, holding it burns power, and it is the assertion users complain about.
public final class IdleLease {
    private var identifier: IOPMAssertionID = 0
    public var isHeld: Bool { identifier != 0 }

    public init() {}

    deinit { release() }

    /// Named so that `pmset -g assertions` and Activity Monitor tell the user exactly who is
    /// keeping their Mac awake. An anonymous assertion looks like malware to anyone who checks,
    /// and Apple's own `caffeinate` names itself.
    @discardableResult
    public func acquire() -> kern_return_t {
        guard identifier == 0 else { return kIOReturnSuccess }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertPreventUserIdleSystemSleep as String,
            kIOPMAssertionNameKey as String: "Lidwing is keeping this Mac awake",
            // World-readable via IOPMCopyAssertionsByProcess. Never put the user's tooling or
            // timings here: "agent: claude-code" would leak their stack to every process.
            kIOPMAssertionDetailsKey as String: "Lid can stay closed",
            kIOPMAssertionHumanReadableReasonKey as String:
                "Lidwing is keeping this Mac awake so a long-running task can finish."
        ]
        return IOPMAssertionCreateWithProperties(properties as CFDictionary, &identifier)
    }

    public func release() {
        if identifier != 0 {
            IOPMAssertionRelease(identifier)
            identifier = 0
        }
    }
}

/// Verification of our own assertion.
public enum AssertionInspector {
    /// The assertion name we look for. It must match `IdleLease.acquire` exactly.
    public static let ourAssertionName = "Lidwing is keeping this Mac awake"

    /// `IOPMCopyAssertionsByProcess` answers through an out-parameter and returns an
    /// `IOReturn`, unlike most Copy functions.
    private static func assertionsByProcess() -> [NSNumber: [[String: Any]]]? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess else { return nil }
        return raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    }

    /// True when *this process* holds a `PreventUserIdleSystemSleep` assertion with our name.
    ///
    /// Never `IOPMCopyAssertionsStatus`: that counts configd's, powerd's and caffeinate's
    /// assertions together, and it will happily report success for us while we hold nothing.
    public static func ourAssertionLive(pid: Int32) -> Bool {
        guard let byProcess = assertionsByProcess() else { return false }
        guard let ours = byProcess[NSNumber(value: pid)] else { return false }
        return ours.contains { entry in
            (entry[kIOPMAssertionTypeKey as String] as? String)
                == (kIOPMAssertPreventUserIdleSystemSleep as String)
                && (entry[kIOPMAssertionNameKey as String] as? String) == ourAssertionName
        }
    }

    /// Other processes holding an assertion that keeps this Mac awake.
    ///
    /// We surface these rather than fight them: `caffeinate`, Amphetamine and KeepingYouAwake
    /// hold their own, and breaking someone else's assertion on the way past is worse than
    /// standing down.
    public static func foreignHolders(excluding pid: Int32) -> [ForeignHolder] {
        guard let byProcess = assertionsByProcess() else { return [] }
        var holders: [ForeignHolder] = []
        for (key, entries) in byProcess {
            let holderPID = key.int32Value
            guard holderPID != pid else { continue }
            for entry in entries {
                guard let type = entry[kIOPMAssertionTypeKey as String] as? String else { continue }
                // Only a hold that stops the machine sleeping outright reaches the UI.
                //
                // This used to accept idle-sleep holds too, and the result was the first thing a
                // user ever saw from this app: "Another app is already keeping this Mac awake:
                // powerd (pid 368)." On every Mac, on every launch, naming the operating system
                // as an app. Lidwing blocks the clamshell *demand* sleep; idle assertions are a
                // different layer and we coexist with them. See decision 0014.
                let kind = PowerAssertions.kind(ofAssertionNamed: type)
                let process = (entry["Process Name"] as? String) ?? "pid \(holderPID)"
                let assertionName = (entry[kIOPMAssertionNameKey as String] as? String) ?? ""
                let candidate = PowerAssertions.Assertion(pid: holderPID, process: process,
                                                          kind: kind, name: assertionName)
                guard ConflictPolicy.tier(for: candidate) == .quietNote else { continue }

                // `Timeout` is seconds remaining when the owner set one. `caffeinate -t 300`
                // does; a persistent holder does not.
                let timeout = (entry["TimeoutSeconds"] as? NSNumber)?.intValue
                    ?? (entry[kIOPMAssertionTimeoutKey as String] as? NSNumber)?.intValue
                let transient = (timeout ?? .max) <= ConflictPolicy.transientThresholdSeconds

                holders.append(ForeignHolder(
                    pid: holderPID,
                    name: ConflictPolicy.displayName(process: process,
                                                     assertionName: assertionName),
                    kind: kind,
                    isTransient: transient))
                break
            }
        }
        return holders.sorted { $0.pid < $1.pid }
    }
}
