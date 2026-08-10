import Foundation

// MARK: - Vocabulary

public enum LidwingState: String, Equatable, Sendable {
    /// No lid, or the runtime probe failed on this OS.
    case unsupported
    /// Nothing armed. Ground truth stock.
    case idle
    /// Applying; verifying ground truth.
    case arming
    /// Bit set, assertion held, ground truth verified.
    case armed
    /// Armed, but a guard is warning. Still protecting.
    case degraded
    /// Releasing; verifying restoration.
    case disarming
    /// The write succeeded per its return code but the machine did not change, or the machine
    /// changed back underneath us, or it slept while we were armed. Loud, never silent.
    case failed
    /// At launch: ground truth is non-stock and we did not set it in this boot session.
    case repair

    /// The states in which we are holding, or believe we are holding, the mechanism.
    public var isProtecting: Bool {
        self == .armed || self == .degraded
    }
}

public enum LidwingMode: String, Equatable, Sendable {
    case manual
    /// Arm while a watched coding agent is running, disarm after it exits.
    case auto
}

public enum LidwingEvent: Equatable, Sendable {
    case launch
    case userArm
    case userDisarm
    case repairRequested
    case agentAppeared
    case agentDisappeared
    case lidChanged(LidState)
    case powerSourceChanged
    case displayReconfigured
    case thermalChanged
    /// The kernel is asking whether it may idle-sleep. Always acknowledged, never vetoed.
    case canSystemSleep(argument: UInt)
    /// The kernel has decided to sleep. Irrevocable; we acknowledge instantly and do no work.
    case systemWillSleep(argument: UInt)
    case systemHasPoweredOn
    case clamshellNotification
    /// The lid never reported. `AppleClamshellState` is absent on a laptop until the lid
    /// driver's first report, so "absent" alone is not evidence — but absent *and still silent
    /// after a grace period* is. Sent once, by the host, and reversible if a notification
    /// arrives later.
    case lidDeterminedAbsent
    /// 10 s: re-issue the write, because powerd and the dark-wake path can clear it.
    case reassertTick
    /// 5 s: evaluate every guard and compare ground truth against intent.
    case reconcileTick
    /// 100 ms while arming or disarming: poll for the machine to actually change.
    case verifyTick
    case watchdogLost
    case watchdogReportedRecovery(at: Date)
    case appWillTerminate
}

public enum LidwingTimer: String, Equatable, Sendable {
    case verify
    case reassert
    case reconcile
    /// Only runs in Auto mode. There is no notification for a command-line process starting,
    /// so this is the one place a poll is unavoidable — and it is the one place the user has
    /// explicitly asked for it by choosing Auto.
    case agentPoll
}

/// Sound is a courtesy channel for the moment the screen is not one.
///
/// The rule: never play for something the user can see, always play for something they
/// cannot. Toggling from the menu with the lid open plays nothing — the checkmark and the
/// glyph already said it, and a sound there trains the user to mute us, after which the sound
/// that matters never lands.
public enum Chime: String, Equatable, Sendable {
    /// The lid just closed and we are protecting. This is the one that matters.
    case sealed
    /// We stood down while the lid was closed: the Mac is about to sleep normally.
    case standingDown
    /// Something failed.
    case failure
    /// A coding agent is blocked and needs the user. Requested explicitly: with the lid shut
    /// this is the only way they find out before their run has been idle for an hour.
    case agentWaiting
}

public enum UserNotice: Equatable, Sendable {
    case firstArm
    case autoDisarmed(DisarmReason)
    case armFailed(MechanismError?)
    case releaseFailed
    case sleptWhileArmed(at: Date)
    case watchdogRecovered(at: Date)
    case degraded(SafetyWarning)
    /// We were armed and the machine stopped agreeing that it was protected.
    case groundTruthLost
    /// Shown at most once a week when arming on battery. We cannot detect a bag; we can warn.
    case bagWarning
}

/// Everything the state machine wants the host to do that is not a system read or write.
public enum LidwingEffect: Equatable, Sendable {
    case startTimer(LidwingTimer)
    case stopTimer(LidwingTimer)
    case chime(Chime)
    case notify(UserNotice)
    /// Acknowledge a power change. Never a veto: failing to acknowledge stalls the whole
    /// system's sleep transition for about thirty seconds and becomes "my Mac takes half a
    /// minute to sleep", attributed to us.
    case allowPowerChange(UInt)
    case requestSystemSleep
    case refuseArm(ArmRefusal)
    /// Ground truth is non-stock and we may have caused it. Offer one-click Repair; never act
    /// silently, because a silent clear can stomp powerd or another tool.
    case offerRepair(RepairCause)
    /// Ground truth is non-stock and the ledger says it was not us.
    case showForeignHolder
    /// Hold off App Nap and sudden termination for the armed session.
    case beginActivity
    case endActivity
    case uiNeedsRefresh
}

// MARK: - Injected collaborators

/// Durable intent. Separate from `SystemFacade` because ordering matters: the ledger is
/// written *before* the first mutation, so a panic between the two is recoverable.
public protocol LedgerStore: AnyObject {
    func read() -> Data?
    func write(_ ledger: Ledger) throws
    func delete()
}

public protocol AuditSink: AnyObject {
    func append(_ record: AuditRecord)
    func note(_ failure: AuditFailure, at date: Date, context: [String: String])
}

/// The dead-man. `RootDomainUserClient::clientClose()` does not clear the clamshell mask, so
/// nothing in the kernel undoes our write when we die. We refuse to hold the bit without a
/// live connection to a separate process that will.
public protocol WatchdogLink: AnyObject {
    var isConnected: Bool { get }
    /// Connect, or relaunch and connect. Returns false when no dead-man can be established.
    func connect() -> Bool
    func send(_ message: ControlMessage)
    func disconnect()
}

/// Messages on `control.sock`, app to watchdog.
public enum ControlMessage: Equatable, Sendable {
    case armed(bootSession: String, pid: Int32)
    case heartbeat(at: Date)
    case disarmed
}

/// Static facts about this build and this machine, for the audit record.
public struct RuntimeIdentity: Equatable, Sendable {
    public let osVersion: String
    public let arch: String
    public let appVersion: String

    public init(osVersion: String, arch: String, appVersion: String) {
        self.osVersion = osVersion
        self.arch = arch
        self.appVersion = appVersion
    }
}
