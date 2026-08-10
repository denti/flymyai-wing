import Foundation

// MARK: - The machine

/// The whole product's decision logic, with no reference to AppKit or IOKit.
///
/// Central rule (INVARIANT SLEEP-ZERO): while armed, the machine must never sleep even once.
/// Both known holes in the mechanism have the same precondition — the Mac must have slept at
/// least once — so a single observed sleep is a hard failure, not a recoverable event.
public final class StateMachine {
    public internal(set) var state: LidwingState = .idle
    public internal(set) var session: AuditSession?
    public internal(set) var lastDisarmReason: DisarmReason?
    public internal(set) var lastGroundTruthVerifiedAt: Date?
    public internal(set) var repairCause: RepairCause?

    /// Set by the host from preferences before `launch`, read back after the first arm.
    public var hasEverArmed = false
    public var mode: LidwingMode = .manual {
        didSet {
            guard mode != oldValue else { return }
            agentGoneSince = nil
        }
    }
    public var settings: SafetySettings {
        didSet { policy = SafetyPolicy(settings: settings) }
    }

    /// True only between a successful `setClamshellSleepDisabled(true)` and its release.
    /// Invariant I7: we never clear a bit we did not set.
    public internal(set) var weSetTheBit = false
    public internal(set) var idleAssertionHeld = false

    // Collaborators and working state. `internal` rather than `private` only because the
    // transitions live in a neighbouring file, and a private member is not visible to an
    // extension in another file even inside the same module.

    internal let facade: SystemFacade
    internal let ledgerStore: LedgerStore
    internal let audit: AuditSink
    internal let watchdog: WatchdogLink
    internal let identity: RuntimeIdentity
    internal let pid: Int32

    internal var policy: SafetyPolicy
    internal var phaseStartedAt: Date?
    internal var pendingDisarmReason: DisarmReason?
    internal var warnedThisSession: Set<SafetyWarning> = []
    internal var groundTruthMismatchSince: Date?
    internal var agentGracePeriod: TimeInterval = 300
    internal var agentGoneSince: Date?
    internal var lastBagWarningAt: Date?

    /// The macOS build on which an arm last verified. Set by the host from storage at launch;
    /// updated by `.recordVerifiedOS` after each verified arm. `nil` means no arm has ever
    /// verified on this machine, which is a first run and must stay quiet.
    public var lastVerifiedOS: String?
    /// Set at launch when `lastVerifiedOS` differs from the OS running now, and cleared by the
    /// first arm that verifies. Deliberately not persisted: if the app never manages a verified
    /// arm, the check is still pending on the next launch, which is the correct answer.
    internal var pendingOSRecheck: (from: String, to: String)?

    /// Lidwing wanted to arm itself at launch but did not yet know whether this Mac has a lid.
    /// Consumed the moment the lid driver reports, dropped if the machine turns out to have no
    /// lid at all. Not persisted: it is an intent about *this* launch.
    internal var deferredArmAtLaunch = false

    /// True when this session was started by Lidwing itself at launch rather than by the user.
    ///
    /// It decides one thing: whether the idle-sleep assertion is held while the lid is open. See
    /// `idleAssertionIsNeeded`.
    internal var armedWithoutBeingAsked = false

    /// Whether Lidwing turns itself on when there is a reason to - at launch, and again after a
    /// wake. Set by the host from the preference of the same meaning; `true` is the product.
    public var armsItselfWhenThereIsAReason = true
    /// Last known lid position, so a chime fires on the transition and not on every one of the
    /// four non-lid events that also deliver a clamshell notification.
    internal var lidWasClosed = false

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

    /// Whether the idle-sleep assertion should be held right now.
    ///
    /// Both halves of the mechanism are required and orthogonal - the clamshell mask stops the
    /// *demand* sleep from a lid close, and this assertion stops the *idle* timer - but they are
    /// not needed at the same moments, and that difference stopped being academic when Lidwing
    /// began arming itself at launch.
    ///
    /// Holding it unconditionally means a Mac with Lidwing installed **never idle-sleeps again**,
    /// from login until the duration lease expires, whether or not anything is happening. A user
    /// who walks away with the lid open comes back to a hot laptop that never slept, for a
    /// feature they were not using. That is a change nobody asked for by installing a lid app.
    ///
    /// So it is held whenever there is a reason:
    ///
    /// * **the lid is shut** - the case the product exists for, and the assertion is essential
    ///   there because the clamshell mask alone leaves the idle timer running;
    /// * **an agent is running** - a run must survive the user walking away with the lid open,
    ///   which is the same promise in a different posture;
    /// * **the user asked for this explicitly** - they turned it on themselves and are entitled
    ///   to have it mean what it used to mean.
    ///
    /// The only case it is released is an automatic arm, lid open, nothing running - where the
    /// promise is not in play and the cost is real. It is re-taken the moment any of those
    /// changes, immediately on the clamshell notification and within five seconds by reconcile.
    internal var idleAssertionIsNeeded: Bool {
        guard state.isProtecting else { return false }
        if !armedWithoutBeingAsked { return true }
        if facade.lidState == .closed { return true }
        return !facade.runningAgentBinaries.isEmpty
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

    // One case per event, and the compiler checks that the set is exhaustive. Splitting this
    // into smaller functions to satisfy a complexity metric would hide exactly the property
    // that makes it safe to read.
    // swiftlint:disable:next cyclomatic_complexity
    internal func dispatch(_ event: LidwingEvent) -> [LidwingEffect] {
        switch event {
        case .launch:
            return onLaunch()

        case .armAtLaunch:
            return onArmAtLaunch()
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
            // The lid has reported, so a launch-time arm that was waiting for exactly this can
            // go ahead now.
            if deferredArmAtLaunch, lid != .noLid {
                deferredArmAtLaunch = false
                let armed = onArmAtLaunch()
                return armed + onReassertTrigger(lidJustClosed: justClosed)
            }
            return onReassertTrigger(lidJustClosed: justClosed)

        case .lidDeterminedAbsent:
            return onLidDeterminedAbsent()

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
}
