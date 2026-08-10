import Foundation
import IOKit
import IOKit.pwr_mgt
import LidwingCore

/// The live implementation of `SystemFacade`.
///
/// Everything here is a thin adapter over one IOKit call. No policy, no caching of our own
/// intent — invariant I9: the displayed state is always derived from what the machine says,
/// never from what we believe we did.
public final class LiveSystem: SystemFacade {
    private let lock = ClamshellLock()
    private let lease = IdleLease()
    private let pid: Int32
    private let agentNames: Set<String>

    /// Set by the observer layer once a clamshell notification has been seen, so that an
    /// absent `AppleClamshellState` can be distinguished from a lid that has not reported yet.
    public var sawClamshellNotification = false

    /// Agent scanning costs a full process-table walk, so it is refreshed on a slow cadence
    /// and cached between reads.
    private var cachedAgents: Set<String> = []
    private var cachedAgentsAt: Date = .distantPast

    public init(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                agentNames: Set<String> = ProcessScanner.defaultAgentNames) {
        self.pid = pid
        self.agentNames = agentNames
        _ = lock.open()
    }

    // MARK: reads

    public var lidState: LidState {
        RootDomain.lidState(clamshellNotificationSeen: sawClamshellNotification)
    }

    public var clamshellCausesSleep: Bool? { RootDomain.clamshellCausesSleep }
    public var sleepDisabled: Bool? { RootDomain.sleepDisabled }
    public var desktopMode: Bool { RootDomain.desktopMode }

    public var onAC: Bool { PowerSourceReader.read().onAC }
    public var batteryCurrent: Int? { PowerSourceReader.read().current }
    public var batteryMax: Int? { PowerSourceReader.read().max }
    public var batteryWarningLevel: BatteryWarning { PowerSourceReader.warningLevel() }

    public var thermalState: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }

    public var onlineDisplayCount: Int { SystemObservers.onlineDisplayCount() }

    public var foreignAssertionHolders: [ForeignHolder] {
        AssertionInspector.foreignHolders(excluding: pid)
    }

    public var ourAssertionLive: Bool {
        AssertionInspector.ourAssertionLive(pid: pid)
    }

    public var runningAgentBinaries: Set<String> {
        if Date().timeIntervalSince(cachedAgentsAt) < 10 { return cachedAgents }
        cachedAgents = ProcessScanner.runningAgents(named: agentNames)
        cachedAgentsAt = Date()
        return cachedAgents
    }

    public var bootSessionUUID: String { RootDomain.bootSessionUUID }
    public var now: Date { Date() }

    // MARK: writes

    public func setClamshellSleepDisabled(_ on: Bool) -> Result<Void, MechanismError> {
        guard lock.open() else { return .failure(.userClientUnavailable) }
        let result: kern_return_t
        if on {
            result = lock.set(true)
        } else {
            // Invariant I7 lives in ClamshellLock.safeRelease, where it cannot be forgotten by
            // a caller.
            result = lock.safeRelease(desktopMode: desktopMode, onAC: onAC)
        }
        guard result == KERN_SUCCESS else { return .failure(.ioReturn(result)) }
        return .success(())
    }

    public func setIdleAssertion(_ on: Bool) -> Result<Void, MechanismError> {
        if on {
            let result = lease.acquire()
            guard result == kIOReturnSuccess else { return .failure(.ioReturn(result)) }
        } else {
            lease.release()
        }
        return .success(())
    }

    public func requestSystemSleep() {
        // Only ever called from the explicit "Sleep now" menu item, and only after a disarm.
        IOPMSleepSystem(IOPMFindPowerManagement(RootDomain.mainPort))
    }

    // MARK: extras the UI needs, not part of the portable seam

    public var weSetTheBit: Bool { lock.weSetTheBit }

    public func closeUserClient() {
        lease.release()
        lock.close()
    }

    public var instantaneousWatts: Double? { PowerSourceReader.instantaneousWatts() }

    /// The raw `AppleClamshellState` for the diagnostics panel, where "(absent)" is a
    /// meaningful answer and the four-state model would hide it.
    public var lidStateRaw: Bool? { RootDomain.clamshellState }
}
