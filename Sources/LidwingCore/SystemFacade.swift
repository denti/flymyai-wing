import Foundation

/// Lid position as the kernel reports it.
///
/// `unknown` is a real state and must not be collapsed into `noLid`: `AppleClamshellState` is
/// absent on a laptop until the lid driver makes its first report, and treating that as "this
/// Mac has no lid" would disable the entire product at login.
public enum LidState: String, Equatable, Sendable {
    case open
    case closed
    case noLid
    case unknown
}

public enum BatteryWarning: Int, Equatable, Comparable, Sendable {
    case none = 0
    case early = 1
    case final = 2

    public static func < (lhs: BatteryWarning, rhs: BatteryWarning) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ThermalState: Int, Equatable, Comparable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why a mechanism write did not produce the state we asked for.
public enum MechanismError: Equatable, Error, Sendable {
    /// The IOKit user client could not be opened at all.
    case userClientUnavailable
    /// The call returned a non-success kern_return_t. The raw value is carried for diagnostics.
    case ioReturn(Int32)
    /// The call reported success but the machine's observable state did not change.
    case noEffect
    /// This OS build does not expose the mechanism.
    case unsupported
}

/// A process other than us that is holding a sleep-blocking assertion.
public struct ForeignHolder: Equatable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// The single seam between the portable logic and the machine.
///
/// Every read is a plain property so a test can script it; every write returns a `Result` so a
/// test can inject a failure. `LidwingCore` links neither AppKit nor IOKit — a CI grep enforces
/// that — so this protocol is the only thing the state machine knows about the world.
public protocol SystemFacade: AnyObject {
    // MARK: reads — ground truth, never cached intent

    var lidState: LidState { get }
    /// `AppleClamshellCausesSleep`. nil means the key is absent (stale until the first
    /// clamshell event on a laptop).
    var clamshellCausesSleep: Bool? { get }
    /// `SleepDisabled` in the IORegistry. nil means the key is absent, which is the state of a
    /// machine on which it has never been set.
    var sleepDisabled: Bool? { get }
    var desktopMode: Bool { get }
    var onAC: Bool { get }
    /// Raw battery units. Never a percentage: raw-mAh conventions exist in the wild, and
    /// comparing raw 3119 against a 20% floor never trips, so the guard silently never fires.
    var batteryCurrent: Int? { get }
    var batteryMax: Int? { get }
    var batteryWarningLevel: BatteryWarning { get }
    var thermalState: ThermalState { get }
    var onlineDisplayCount: Int { get }
    var foreignAssertionHolders: [ForeignHolder] { get }
    /// Our own assertion, verified by pid and name — never a global assertion count, which
    /// reports success for us while we hold nothing.
    var ourAssertionLive: Bool { get }
    var runningAgentBinaries: Set<String> { get }
    var bootSessionUUID: String { get }
    var now: Date { get }

    // MARK: writes — the only mutating surface

    func setClamshellSleepDisabled(_ on: Bool) -> Result<Void, MechanismError>
    func setIdleAssertion(_ on: Bool) -> Result<Void, MechanismError>
    func requestSystemSleep()
}
