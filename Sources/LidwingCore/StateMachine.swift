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

// MARK: - The machine

/// The whole product's decision logic, with no reference to AppKit or IOKit.
///
/// Central rule (INVARIANT SLEEP-ZERO): while armed, the machine must never sleep even once.
/// Both known holes in the mechanism have the same precondition — the Mac must have slept at
/// least once — so a single observed sleep is a hard failure, not a recoverable event.
public final class StateMachine {
    public private(set) var state: LidwingState = .idle
    public private(set) var session: AuditSession?
    public private(set) var lastDisarmReason: DisarmReason?
    public private(set) var lastGroundTruthVerifiedAt: Date?
    public private(set) var repairCause: RepairCause?

    /// Set by the host from preferences before `launch`, read back after the first arm.
    public var hasEverArmed = false
    public var mode: LidwingMode = .manual
    public var settings: SafetySettings {
        didSet { policy = SafetyPolicy(settings: settings) }
    }

    /// True only between a successful `setClamshellSleepDisabled(true)` and its release.
    /// Invariant I7: we never clear a bit we did not set.
    public private(set) var weSetTheBit = false
    public private(set) var idleAssertionHeld = false

    private let facade: SystemFacade
    private let ledgerStore: LedgerStore
    private let audit: AuditSink
    private let watchdog: WatchdogLink
    private let identity: RuntimeIdentity
    private let pid: Int32

    private var policy: SafetyPolicy
    private var phaseStartedAt: Date?
    private var pendingDisarmReason: DisarmReason?
    private var warnedThisSession: Set<SafetyWarning> = []
    private var groundTruthMismatchSince: Date?
    private var agentGracePeriod: TimeInterval = 300
    private var agentGoneSince: Date?
    private var lastBagWarningAt: Date?
    /// Last known lid position, so a chime fires on the transition and not on every one of the
    /// four non-lid events that also deliver a clamshell notification.
    private var lidWasClosed = false

    /// How long a write has to take effect before we call it a lie.
    public static let verifyDeadline: TimeInterval = 2.0
    /// I1: an armed machine whose ground truth is older than this is not armed.
    public static let groundTruthMaxAge: TimeInterval = 5.0

    public init(facade: SystemFacade,
                ledgerStore: LedgerStore,
                audit: AuditSink,
                watchdog: WatchdogLink,
                identity: RuntimeIdentity,
                settings: SafetySettings = SafetySettings(),
                pid: Int32 = 0) {
        self.facade = facade
        self.ledgerStore = ledgerStore
        self.audit = audit
        self.watchdog = watchdog
        self.identity = identity
        self.settings = settings
        self.policy = SafetyPolicy(settings: settings)
        self.pid = pid
    }

    // MARK: Entry point

    @discardableResult
    public func handle(_ event: LidwingEvent) -> [LidwingEffect] {
        let before = state
        var effects = dispatch(event)
        if state != before {
            effects.append(.uiNeedsRefresh)
        }
        assertInvariants()
        return effects
    }

    private func dispatch(_ event: LidwingEvent) -> [LidwingEffect] {
        switch event {
        case .launch:
            return onLaunch()

        case .userArm:
            return onUserArm()

        case .agentAppeared:
            agentGoneSince = nil
            guard mode == .auto, state == .idle else { return [] }
            return onUserArm()

        case .agentDisappeared:
            guard mode == .auto else { return [] }
            if agentGoneSince == nil { agentGoneSince = facade.now }
            return []

        case .userDisarm:
            if state == .failed {
                // A failed state can still be holding the mechanism. The user asking us to
                // stop must always work, whatever we think our state is.
                return finishFailedSession(reason: .user)
            }
            guard state.isProtecting || state == .arming else { return [] }
            return beginDisarm(.user)

        case .appWillTerminate:
            guard state.isProtecting || state == .arming || state == .disarming
                    || state == .failed else { return [] }
            return terminateNow()

        case .repairRequested:
            return onRepairRequested()

        case .canSystemSleep(let argument):
            // Unconditional acknowledgement. `IOCancelPowerChange` is useless here anyway:
            // clamshell sleep is a demand sleep and only idle sleep can be vetoed.
            return [.allowPowerChange(argument)]

        case .systemWillSleep(let argument):
            return onSystemWillSleep(argument)

        case .systemHasPoweredOn:
            return onSystemHasPoweredOn()

        case .lidChanged(let lid):
            let justClosed = (lid == .closed && lidWasClosed == false)
            lidWasClosed = (lid == .closed)
            return onReassertTrigger(lidJustClosed: justClosed)

        case .clamshellNotification, .displayReconfigured, .powerSourceChanged, .reassertTick:
            return onReassertTrigger()

        case .thermalChanged:
            guard state.isProtecting else { return [] }
            return onReconcile()

        case .reconcileTick:
            return onReconcile()

        case .verifyTick:
            return onVerifyTick()

        case .watchdogLost:
            return onWatchdogLost()

        case .watchdogReportedRecovery(let date):
            audit.note(.watchdogRecovered, at: date, context: [:])
            return [.notify(.watchdogRecovered(at: date))]
        }
    }

    // MARK: Launch and reconciliation

    private func onLaunch() -> [LidwingEffect] {
        if facade.lidState == .noLid {
            state = .unsupported
            return []
        }

        let truth = GroundTruth(clamshellCausesSleep: facade.clamshellCausesSleep,
                                sleepDisabled: facade.sleepDisabled)
        let decision = LedgerReconciler.decide(rawLedger: ledgerStore.read(),
                                               truth: truth,
                                               currentBootSession: facade.bootSessionUUID)
        switch decision {
        case .stock(let deleteStale):
            if deleteStale { ledgerStore.delete() }
            state = .idle
            repairCause = nil
            return []
        case .repair(let cause):
            state = .repair
            repairCause = cause
            return [.offerRepair(cause)]
        case .standDown:
            state = .idle
            repairCause = nil
            return [.showForeignHolder]
        }
    }

    /// The user pressed Repair. This is the only path that clears a bit we are not certain we
    /// set, and it exists because doing it silently is worse.
    private func onRepairRequested() -> [LidwingEffect] {
        guard state == .repair else { return [] }
        _ = facade.setClamshellSleepDisabled(false)
        _ = facade.setIdleAssertion(false)
        weSetTheBit = false
        idleAssertionHeld = false
        ledgerStore.delete()

        let truth = GroundTruth(clamshellCausesSleep: facade.clamshellCausesSleep,
                                sleepDisabled: facade.sleepDisabled)
        if truth.isStock {
            state = .idle
            repairCause = nil
            return []
        }
        state = .failed
        audit.note(.releaseNoEffect, at: facade.now, context: ["phase": "repair"])
        return [.chime(.failure), .notify(.releaseFailed)]
    }

    // MARK: Arming

    private func onUserArm() -> [LidwingEffect] {
        switch state {
        case .idle:
            break
        case .failed:
            // A failed state can still be holding the mechanism and can still own an open
            // session record. Close both before starting a new one.
            if session != nil {
                releaseMechanism()
                finishSession(reason: .failure)
                watchdog.disconnect()
                ledgerStore.delete()
            }
        case .repair:
            return [.offerRepair(repairCause ?? .noLedger)]
        case .unsupported:
            return [.refuseArm(.unsupportedOS)]
        case .arming, .armed, .degraded, .disarming:
            return []
        }

        let power = currentPowerSample()
        if facade.onlineDisplayCount > 1 && power.onAC {
            // macOS already keeps a Mac awake with the lid closed when an external display is
            // attached on AC. Saying so costs a user and buys the credibility that carries the
            // other ninety-nine.
            return [.refuseArm(.externalDisplayOnAC)]
        }
        if let refusal = SafetyPolicy.refusalReason(power: power,
                                                    thermal: facade.thermalState,
                                                    settings: settings,
                                                    lid: facade.lidState,
                                                    foreignHolders: facade.foreignAssertionHolders) {
            return [.refuseArm(refusal)]
        }

        // The dead-man goes up first. We never hold the mechanism without one.
        guard watchdog.connect() else {
            audit.note(.watchdogUnavailable, at: facade.now, context: [:])
            return [.refuseArm(.watchdogUnavailable)]
        }

        // The ledger is written before the first mutation so a panic between them is
        // recoverable at next boot.
        let ledger = Ledger(bootSessionUUID: facade.bootSessionUUID,
                            capturedAt: facade.now,
                            weSetClamshellBit: true,
                            reason: "arming",
                            appVersion: identity.appVersion)
        do {
            try ledgerStore.write(ledger)
        } catch {
            // Not fatal — the watchdog covers process death and the mask clears on reboot —
            // but it is recorded, because it degrades our ability to explain ourselves later.
            audit.note(.ledgerWriteFailed, at: facade.now, context: ["error": "\(error)"])
        }

        if case .failure(let error) = facade.setClamshellSleepDisabled(true) {
            watchdog.disconnect()
            ledgerStore.delete()
            audit.note(.applyNoEffect, at: facade.now, context: ["mechanism": "clamshell"])
            state = .failed
            return [.chime(.failure), .notify(.armFailed(error))]
        }
        weSetTheBit = true

        if case .failure(let error) = facade.setIdleAssertion(true) {
            // Without the idle lease the machine still sleeps on the ordinary timer, so the
            // promise is not kept. Roll the whole thing back rather than half-arm.
            releaseMechanism()
            watchdog.disconnect()
            ledgerStore.delete()
            audit.note(.applyNoEffect, at: facade.now, context: ["mechanism": "assertion"])
            state = .failed
            return [.chime(.failure), .notify(.armFailed(error))]
        }
        idleAssertionHeld = true

        state = .arming
        phaseStartedAt = facade.now
        session = AuditSession(armedAt: facade.now)
        warnedThisSession = []
        groundTruthMismatchSince = nil
        pendingDisarmReason = nil

        var effects: [LidwingEffect] = [.beginActivity, .startTimer(.verify)]
        if !power.onAC, shouldShowBagWarning() {
            lastBagWarningAt = facade.now
            effects.append(.notify(.bagWarning))
        }
        return effects
    }

    private func shouldShowBagWarning() -> Bool {
        guard let last = lastBagWarningAt else { return true }
        return facade.now.timeIntervalSince(last) >= 7 * 24 * 3600
    }

    // MARK: Verification of both transitions

    private func onVerifyTick() -> [LidwingEffect] {
        guard let started = phaseStartedAt else { return [] }
        let elapsed = facade.now.timeIntervalSince(started)

        switch state {
        case .arming:
            // Both mechanisms return success while doing nothing. The only acceptance signal
            // is the machine's own answer.
            if facade.clamshellCausesSleep == false {
                return completeArming()
            }
            if elapsed >= StateMachine.verifyDeadline {
                releaseMechanism()
                watchdog.disconnect()
                ledgerStore.delete()
                audit.note(.applyNoEffect, at: facade.now, context: ["phase": "verify"])
                session = nil
                state = .failed
                phaseStartedAt = nil
                return [.stopTimer(.verify), .endActivity, .chime(.failure), .notify(.armFailed(.noEffect))]
            }
            return []

        case .disarming:
            if facade.clamshellCausesSleep != false {
                return completeDisarming()
            }
            if elapsed >= StateMachine.verifyDeadline {
                audit.note(.releaseNoEffect, at: facade.now, context: ["phase": "verify"])
                state = .failed
                phaseStartedAt = nil
                return [.stopTimer(.verify), .endActivity, .chime(.failure), .notify(.releaseFailed)]
            }
            return []

        default:
            return [.stopTimer(.verify)]
        }
    }

    private func completeArming() -> [LidwingEffect] {
        state = .armed
        phaseStartedAt = nil
        lastGroundTruthVerifiedAt = facade.now
        watchdog.send(.armed(bootSession: facade.bootSessionUUID, pid: pid))

        var effects: [LidwingEffect] = [
            .stopTimer(.verify),
            .startTimer(.reassert),
            .startTimer(.reconcile)
        ]
        // No chime here. The user is looking at the menu they just clicked.
        if !hasEverArmed {
            hasEverArmed = true
            effects.append(.notify(.firstArm))
        }
        return effects
    }

    private func completeDisarming() -> [LidwingEffect] {
        let reason = pendingDisarmReason ?? .user
        finishSession(reason: reason)
        ledgerStore.delete()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        state = .idle
        phaseStartedAt = nil
        pendingDisarmReason = nil
        lastGroundTruthVerifiedAt = nil

        var effects: [LidwingEffect] = [.stopTimer(.verify), .endActivity]
        if lidWasClosed {
            // The screen is not an output channel right now, so this is the one confirmation
            // the user can actually receive: the Mac is about to sleep normally.
            effects.append(.chime(.standingDown))
        }
        if reason.userFacingSentence != nil {
            effects.append(.notify(.autoDisarmed(reason)))
        }
        return effects
    }

    // MARK: Re-assertion

    private func onReassertTrigger(lidJustClosed: Bool = false) -> [LidwingEffect] {
        guard state.isProtecting else { return [] }
        // Idempotent by construction: the kernel term is a bit mask, and re-setting a set bit
        // is a no-op that also re-runs the clamshell evaluation, which refreshes the property
        // we verify against.
        if case .success = facade.setClamshellSleepDisabled(true) {
            session?.countReassert()
        }
        if !facade.ourAssertionLive {
            _ = facade.setIdleAssertion(true)
        }
        watchdog.send(.heartbeat(at: facade.now))
        // The defining moment of this product: the lid just shut and the Mac is still running.
        // The user cannot see anything, so say it out loud.
        return lidJustClosed ? [.chime(.sealed)] : []
    }

    // MARK: Reconciliation while armed

    private func onReconcile() -> [LidwingEffect] {
        guard state.isProtecting else { return [] }
        guard let armedSince = session?.armedAt else { return [] }

        let power = currentPowerSample()
        session?.observe(batteryPercent: power.percentage)
        session?.observe(thermal: facade.thermalState)

        // Ground truth first: a machine that is no longer protected is not "degraded", it has
        // failed, and the user must be told rather than shown a confident green icon.
        if facade.clamshellCausesSleep == true {
            if groundTruthMismatchSince == nil {
                groundTruthMismatchSince = facade.now
                _ = facade.setClamshellSleepDisabled(true)
                session?.countReassert()
            } else if facade.now.timeIntervalSince(groundTruthMismatchSince!) >= StateMachine.verifyDeadline {
                session?.record(.groundTruthLost)
                audit.note(.groundTruthLost, at: facade.now, context: [:])
                state = .failed
                groundTruthMismatchSince = nil
                return [.stopTimer(.reassert), .stopTimer(.reconcile), .chime(.failure),
                        .notify(.groundTruthLost)]
            }
        } else if facade.clamshellCausesSleep == false {
            groundTruthMismatchSince = nil
            lastGroundTruthVerifiedAt = facade.now
        }

        if !facade.ourAssertionLive {
            _ = facade.setIdleAssertion(true)
        }

        // Auto mode: the natural end of a session is the agent exiting.
        if mode == .auto, let gone = agentGoneSince,
           facade.now.timeIntervalSince(gone) >= agentGracePeriod,
           facade.runningAgentBinaries.isEmpty {
            return beginDisarm(.agentExited)
        }

        let verdict = policy.evaluate(power: power,
                                      thermal: facade.thermalState,
                                      armedSince: armedSince,
                                      now: facade.now)
        switch verdict {
        case .disarm(let reason):
            return beginDisarm(reason)

        case .degrade(let warning):
            state = .degraded
            if warnedThisSession.insert(warning).inserted {
                return [.notify(.degraded(warning))]
            }
            return []

        case .ok:
            if !facade.foreignAssertionHolders.isEmpty {
                state = .degraded
                if warnedThisSession.insert(.foreignHolder).inserted {
                    return [.notify(.degraded(.foreignHolder))]
                }
                return []
            }
            state = .armed
            return []
        }
    }

    // MARK: Sleep observation — invariant I5

    private func onSystemWillSleep(_ argument: UInt) -> [LidwingEffect] {
        // Acknowledge first and do no work: the decision is irrevocable, and disk or network
        // access here blocks the whole machine.
        var effects: [LidwingEffect] = [.allowPowerChange(argument)]
        guard state.isProtecting else { return effects }

        let at = facade.now
        session?.record(.sleptWhileArmed)
        audit.note(.sleptWhileArmed, at: at, context: [
            "lid": facade.lidState.rawValue,
            "onAC": String(facade.onAC),
            "displays": String(facade.onlineDisplayCount),
            "thermal": String(describing: facade.thermalState)
        ])
        state = .failed
        effects.append(contentsOf: [.stopTimer(.reassert), .stopTimer(.reconcile),
                                    .notify(.sleptWhileArmed(at: at))])
        return effects
    }

    private func onSystemHasPoweredOn() -> [LidwingEffect] {
        switch state {
        case .failed where session != nil:
            // We were protecting when the machine slept. Re-arm immediately rather than
            // leaving an eight-hour run unprotected for the rest of the night.
            return reArmAfterFailure()
        case .armed, .degraded:
            return onReassertTrigger()
        default:
            return []
        }
    }

    private func reArmAfterFailure() -> [LidwingEffect] {
        guard watchdog.isConnected || watchdog.connect() else {
            return finishFailedSession(reason: .watchdogLost)
        }
        if case .failure = facade.setClamshellSleepDisabled(true) {
            return finishFailedSession(reason: .unsupportedState)
        }
        weSetTheBit = true
        if case .failure = facade.setIdleAssertion(true) {
            return finishFailedSession(reason: .unsupportedState)
        }
        idleAssertionHeld = true
        state = .arming
        phaseStartedAt = facade.now
        return [.startTimer(.verify)]
    }

    private func finishFailedSession(reason: DisarmReason) -> [LidwingEffect] {
        releaseMechanism()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        ledgerStore.delete()
        finishSession(reason: reason)
        state = .idle
        return [.stopTimer(.reassert), .stopTimer(.reconcile), .endActivity, .uiNeedsRefresh]
    }

    // MARK: Watchdog

    private func onWatchdogLost() -> [LidwingEffect] {
        guard state.isProtecting || state == .arming else { return [] }
        if watchdog.connect() { return [] }
        // Invariant I2: no dead-man, no bit. Standing down is the safe direction.
        audit.note(.watchdogUnavailable, at: facade.now, context: ["phase": state.rawValue])
        return beginDisarm(.watchdogLost)
    }

    // MARK: Disarming

    private func beginDisarm(_ reason: DisarmReason) -> [LidwingEffect] {
        guard state.isProtecting || state == .arming else { return [] }
        pendingDisarmReason = reason
        releaseMechanism()
        state = .disarming
        phaseStartedAt = facade.now
        return [.stopTimer(.reassert), .stopTimer(.reconcile), .startTimer(.verify)]
    }

    /// Runs the whole disarm synchronously, because the process is about to stop existing and
    /// there will be no run loop left to deliver a verify tick.
    private func terminateNow() -> [LidwingEffect] {
        let reason: DisarmReason = pendingDisarmReason ?? .quit
        releaseMechanism()
        finishSession(reason: reason)
        ledgerStore.delete()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        state = .idle
        phaseStartedAt = nil
        pendingDisarmReason = nil
        return [.stopTimer(.reassert), .stopTimer(.reconcile), .stopTimer(.verify), .endActivity]
    }

    /// Invariant I7. Bit 0x02 of `clamshellSleepDisableMask` is shared with powerd and has no
    /// reference count, so clearing it in a configuration where powerd legitimately wants it
    /// set would sleep somebody else's lid-closed machine mid-operation.
    private func releaseMechanism() {
        if idleAssertionHeld {
            _ = facade.setIdleAssertion(false)
            idleAssertionHeld = false
        }
        guard weSetTheBit else { return }
        if facade.desktopMode && facade.onAC {
            weSetTheBit = false
            return
        }
        _ = facade.setClamshellSleepDisabled(false)
        weSetTheBit = false
    }

    private func finishSession(reason: DisarmReason) {
        guard let session else { return }
        let record = session.finish(at: facade.now,
                                    reason: reason,
                                    tier: 1,
                                    sleepCountDelta: nil,
                                    darkWakeCountDelta: nil,
                                    os: identity.osVersion,
                                    arch: identity.arch,
                                    appVersion: identity.appVersion)
        audit.append(record)
        lastDisarmReason = reason
        self.session = nil
        warnedThisSession = []
        agentGoneSince = nil
    }

    private func currentPowerSample() -> PowerSample {
        PowerSample(onAC: facade.onAC,
                    current: facade.batteryCurrent,
                    max: facade.batteryMax,
                    warning: facade.batteryWarningLevel)
    }

    // MARK: Invariants

    /// I3 and I1, checked on every transition. In debug these are hard preconditions; in
    /// release they become an audited record, because a violated invariant here means the
    /// machine may be unable to sleep and the user must find out.
    private func assertInvariants() {
        let quiescent = !(state.isProtecting || state == .arming || state == .disarming
                          || state == .failed || state == .repair)
        if quiescent && (weSetTheBit || idleAssertionHeld) {
            audit.note(.groundTruthLost, at: facade.now,
                       context: ["invariant": "I3", "state": state.rawValue])
            assertionFailure("I3 violated: quiescent in \(state) while still holding the mechanism")
        }
        if state.isProtecting, let verified = lastGroundTruthVerifiedAt,
           facade.now.timeIntervalSince(verified) > StateMachine.groundTruthMaxAge * 4 {
            // Deliberately generous: the reconcile tick refreshes this every five seconds, so
            // four times the budget means the run loop itself has stopped.
            audit.note(.groundTruthLost, at: facade.now,
                       context: ["invariant": "I1", "age": String(Int(facade.now.timeIntervalSince(verified)))])
        }
    }
}
