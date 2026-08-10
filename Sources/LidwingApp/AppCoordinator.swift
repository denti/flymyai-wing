import AppKit
import UserNotifications
import LidwingCore
import LidwingSystem

/// Wires the machine to the state machine and back.
///
/// It owns every timer and every observer, and it is the only place where an effect returned
/// by `StateMachine` turns into something the user can see or hear.
final class AppCoordinator {

    let system: LiveSystem
    let machine: StateMachine
    let audit: FileAuditSink
    private let ledger: FileLedgerStore
    let watchdog: WatchdogClient
    let chimes = ChimePlayer()
    let log = Log.shared
    let preferences = Preferences.shared
    var observers: SystemObservers?
    private var notifyServer: NotifyServer?
    /// Why the machine looked non-stock at launch, kept so the menu item can explain it when the
    /// user asks. Set without ever opening a dialog.
    private(set) var pendingRepairCause: RepairCause?
    /// Set when a coding agent says it is blocked, cleared when the user opens the menu.
    /// Advisory only: invariant I8 means nothing on that socket can arm anything, and this
    /// property is the entire extent of its reach into the app.
    var agentIsWaiting: (source: String, at: Date)?

    private var verifyTimer: DispatchSourceTimer?
    private var reassertTimer: DispatchSourceTimer?
    private var reconcileTimer: DispatchSourceTimer?
    private var agentPollTimer: DispatchSourceTimer?
    private var lastSeenAgents: Set<String> = []
    private var activity: NSObjectProtocol?

    // `private(set)` would confine the setter to this file, and the code that observes a
    // failure lives in the presentation extension next door.
    var lastFailureAt: Date?
    var armedSince: Date?
    /// Set once the user has been asked, so a notification prompt never appears at launch.
    var askedForNotificationPermission = false

    var onStateChange: (() -> Void)?

    init() {
        let pid = ProcessInfo.processInfo.processIdentifier
        system = LiveSystem(pid: pid)
        audit = FileAuditSink()
        ledger = FileLedgerStore()
        watchdog = WatchdogClient(bootSession: RootDomain.bootSessionUUID, pid: pid)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        machine = StateMachine(facade: system,
                               ledgerStore: ledger,
                               audit: audit,
                               watchdog: watchdog,
                               identity: RuntimeIdentity(
                                   osVersion: ProcessInfo.processInfo
                                       .operatingSystemVersionString,
                                   arch: Self.architecture(),
                                   appVersion: version),
                               settings: preferences.safetySettings,
                               pid: pid)
        machine.mode = preferences.mode
        machine.hasEverArmed = preferences.hasEverArmed
        machine.lastVerifiedOS = preferences.lastVerifiedOS
        // Logged here rather than from the state machine, which has no logger and should not
        // grow one. Same pure comparison, so there is only one rule about what counts as a
        // change - and it is recorded even if the user never arms again, because this is the
        // line that explains a support report six weeks from now.
        if case .changed(let from, let to) = OSChangeWatch.compare(
            lastVerifiedOS: preferences.lastVerifiedOS,
            current: ProcessInfo.processInfo.operatingSystemVersionString) {
            Log.shared.emit(LogCatalogue.osChanged, .lifecycle, ["from": from, "to": to])
        }
        chimes.enabled = preferences.soundEnabled

        watchdog.launchWatchdog = { WatchdogInstaller.ensureRunning() }
        watchdog.onDisconnect = { [weak self] in
            self?.deliver(self?.machine.handle(.watchdogLost) ?? [])
        }
    }

    // MARK: lifecycle

    func start() {
        SupportDirectory.ensure()
        // The watchdog is started eagerly, not at arm time: bringing it up takes a moment and
        // the arm path refuses to proceed without it.
        WatchdogInstaller.ensureRunning()

        let observers = SystemObservers { [weak self] signal in
            self?.handle(signal)
        }
        observers.start()
        self.observers = observers

        // Advisory only. This server has no reference to the state machine and no way to
        // reach one.
        let notify = NotifyServer { [weak self] signal in
            self?.agentSignalled(signal)
        }
        // Advisory, but not silent. If the socket cannot be created the agent-waiting
        // notification simply never arrives, and a feature that quietly does not exist is the
        // hardest kind to diagnose from a support report.
        if notify.start() {
            notifyServer = notify
        } else {
            log.emit(LogCatalogue.notifyServerUnavailable, .integrations)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        readWatchdogRecoveryRecord()
        deliver(machine.handle(.launch))

        // `AppleClamshellState` is absent on a laptop until the lid driver's first report, so
        // an absent key at launch is not evidence of a desktop — coercing it would disable the
        // product at every login. Absent *and still silent after ten seconds* is evidence.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.system.sawClamshellNotification,
                  self.system.lidStateRaw == nil else { return }
            self.system.sawClamshellNotification = true      // makes lidState report .noLid
            self.deliver(self.machine.handle(.lidDeterminedAbsent))
        }
        log.emit(LogCatalogue.launch, .lifecycle, [
            "version": version, "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": Self.architecture(), "state": machine.state.rawValue
        ])
        if machine.mode == .auto { startTimer(.agentPoll) }
        // No timer is started here. The guards exist to end an armed session, so they run for
        // exactly as long as one lasts; the menu computes its own state when it is opened.
        // An idle Lidwing does no work at all.
    }

    func stop() {
        log.emit(LogCatalogue.terminating, .lifecycle, ["state": machine.state.rawValue])
        deliver(machine.handle(.appWillTerminate))
        observers?.stop()
        observers = nil
        notifyServer?.stop()
        notifyServer = nil
        stopTimer(.verify)
        stopTimer(.reassert)
        stopTimer(.reconcile)
        stopTimer(.agentPoll)
        system.closeUserClient()
    }

    // MARK: user actions

    func toggle() {
        if machine.state.isProtecting || machine.state == .arming {
            deliver(machine.handle(.userDisarm))
            return
        }
        // Checked before the state machine sees the request, because the honest message here
        // is "move me", not "the watchdog would not start" — which is what the machine would
        // otherwise report, since a translocated bundle cannot register a launchd agent that
        // outlives it.
        guard WatchdogInstaller.isInAStablePlace else {
            log.emit(LogCatalogue.armRefused, .power, ["reason": "notInApplications"])
            presentRefusal(.notInApplications)
            return
        }

        let power = PowerSourceReader.read()
        let sample = PowerSample(onAC: power.onAC, current: power.current, max: power.max,
                                 warning: power.warning)
        log.emit(LogCatalogue.armRequested, .power, [
            "mode": machine.mode.rawValue,
            "onAC": String(power.onAC),
            "battery": sample.percentage.map(String.init) ?? "unknown",
            "thermal": String(describing: system.thermalState),
            "displays": String(system.onlineDisplayCount)
        ])
        deliver(machine.handle(.userArm))
    }

    /// The menu item. This is a user action, so a confirmation dialog is expected here and is
    /// the one place it is safe - the menu title ends in an ellipsis precisely because it
    /// promises one.
    func repairNow() {
        presentRepair(pendingRepairCause ?? .noLedger)
    }

    func sleepNow() {
        deliver(machine.handle(.userDisarm))
        // Give the disarm its verification window before handing the machine to the kernel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.system.requestSystemSleep()
        }
    }

    /// Runs the full disarm through the normal path, so the timers stop, the watchdog is told
    /// and the session record is closed. Calling the state machine directly would leave those
    /// behind, which is exactly the kind of residue an uninstaller exists to prevent.
    func prepareForUninstall() {
        deliver(machine.handle(.appWillTerminate))
        observers?.stop()
        observers = nil
        system.closeUserClient()
    }

    /// Auto mode: arm while a watched coding agent is running, stand down after it exits.
    ///
    /// The user's mental model is "stay awake while my agent is running", not "stay awake
    /// until I remember to turn it off" — and the natural disarm independently mitigates the
    /// battery, thermal and orphan-state problems, because a session that ends by itself
    /// cannot be forgotten.
    func setMode(_ mode: LidwingMode) {
        preferences.mode = mode
        machine.mode = mode
        if mode == .auto {
            startTimer(.agentPoll)
            pollForAgents()
        } else {
            stopTimer(.agentPoll)
            lastSeenAgents = []
        }
        onStateChange?()
    }

    private func pollForAgents() {
        let running = system.runningAgentBinaries
        defer { lastSeenAgents = running }
        guard running != lastSeenAgents else { return }
        if !running.isEmpty && lastSeenAgents.isEmpty {
            deliver(machine.handle(.agentAppeared))
        } else if running.isEmpty && !lastSeenAgents.isEmpty {
            deliver(machine.handle(.agentDisappeared))
        }
        onStateChange?()
    }

    func soundEnabledChanged() {
        chimes.enabled = preferences.soundEnabled
    }

    func setSafetySettings(_ settings: SafetySettings) {
        preferences.safetySettings = settings
        machine.settings = settings
        onStateChange?()
    }

    // MARK: signals in

    private func handle(_ signal: SystemSignal) {
        switch signal {
        case .clamshell(let closed, _):
            // A notification after the grace period means the lid exists after all: a slow
            // driver, or hardware that reports late. The conclusion is reversible.
            system.sawClamshellNotification = true
            if machine.state == .unsupported, system.lidStateRaw != nil {
                deliver(machine.handle(.launch))
            }
            if let closed {
                deliver(machine.handle(.lidChanged(closed ? .closed : .open)))
            } else {
                deliver(machine.handle(.clamshellNotification))
            }
        case .canSystemSleep(let argument):
            deliver(machine.handle(.canSystemSleep(argument: argument)))
        case .systemWillSleep(let argument):
            deliver(machine.handle(.systemWillSleep(argument: argument)))
        case .systemHasPoweredOn:
            deliver(machine.handle(.systemHasPoweredOn))
        case .powerSourceChanged:
            deliver(machine.handle(.powerSourceChanged))
        case .displayReconfigured:
            deliver(machine.handle(.displayReconfigured))
        case .thermalChanged:
            deliver(machine.handle(.thermalChanged))
        }
    }

    /// A coding agent said it is blocked. The only three things this is allowed to do.
    private func agentSignalled(_ signal: NotifyServer.Signal) {
        agentIsWaiting = (source: signal.source, at: Date())
        chimes.play(.agentWaiting)
        let name = signal.source == "hook" ? "Your coding agent" : signal.source
        postNotification(title: "\(name) is waiting for you",
                         body: signal.body.isEmpty ? "It needs an answer before it can carry on."
                                                   : signal.body)
        onStateChange?()
    }

    /// Cleared when the user looks at the menu: they have seen it, so it stops being news.
    func acknowledgeAgentWaiting() {
        guard agentIsWaiting != nil else { return }
        agentIsWaiting = nil
        onStateChange?()
    }

    // MARK: sound self-check

    /// What is wrong with sound on this Mac, in the user's words, or nil when nothing is.
    var soundSelfCheckWarning: String? { chimes.selfCheckWarning }

    /// Plays the lid-close chime because the user asked to hear it.
    func previewChime() { chimes.preview(.sealed) }

    // MARK: effects out

    /// Performs one effect. Returns whether the menu has to be rebuilt afterwards.
    ///
    /// Split out of `deliver` when the switch crossed the complexity limit. That limit earns its
    /// keep here: this is the one function every effect in the product passes through, and a
    /// long switch is where a `case` quietly gets added next to the wrong neighbour.
    private func perform(_ effect: LidwingEffect) -> Bool {
        switch effect {
        case .startTimer(let timer):
            startTimer(timer)
        case .stopTimer(let timer):
            stopTimer(timer)
        case .chime(let chime):
            chimes.play(chime)
        case .notify(let notice):
            present(notice)
        case .allowPowerChange(let argument):
            observers?.allowPowerChange(argument)
        case .requestSystemSleep:
            system.requestSystemSleep()
        case .refuseArm(let refusal):
            log.emit(LogCatalogue.armRefused, .power,
                     ["reason": String(describing: refusal)])
            presentRefusal(refusal)
        case .offerRepair(let cause, let prompt):
            switch prompt {
            case .quietly:
                // Never a modal here. This arrives from `onLaunch`, which runs inside
                // `applicationDidFinishLaunching`, which is itself inside the Apple Event
                // handler - and a nested modal run loop there pops an autorelease pool the
                // launch machinery still owns. That crashed on a user's Mac at 0x94.
                //
                // The menu already carries this state in words, with a "Repair Now..." item, and
                // the glyph already shows it. So the launch path draws the eye and says nothing
                // it cannot say without blocking.
                pendingRepairCause = cause
                return true
            case .askNow:
                presentRepair(cause)
            }
        case .beginActivity:
            beginActivity()
        case .endActivity:
            endActivity()
        case .recordVerifiedOS(let os):
            preferences.lastVerifiedOS = os
            log.emit(LogCatalogue.osRecheckPassed, .lifecycle, ["to": os])
        case .showForeignHolder, .uiNeedsRefresh:
            return true
        }
        return false
    }

    func deliver(_ effects: [LidwingEffect]) {
        var needsRefresh = false
        for effect in effects where perform(effect) {
            needsRefresh = true
        }
        if preferences.hasEverArmed != machine.hasEverArmed {
            preferences.hasEverArmed = machine.hasEverArmed
        }
        armedSince = machine.session?.armedAt

        // Refresh only when the user-visible state actually changed. `deliver` runs on every
        // reconcile tick, and re-rendering the status item twelve times a minute for a picture
        // that has not changed is exactly the idle work this app promises not to do.
        if needsRefresh || machine.state != lastPresentedState {
            lastPresentedState = machine.state
            onStateChange?()
        }
    }

    var lastPresentedState: LidwingState?

    /// True while a modal is on screen. A modal runs its own run loop, so the reconcile timer
    /// keeps firing underneath it — without this, a second dialog can land on top of the first
    /// and the user has to dismiss a stack.
    ///
    /// Stored here rather than next to the code that uses it, because Swift has no stored
    /// properties in extensions.
    var isPresentingModal = false

    // MARK: timers
    //
    // Every repeating timer is a `DispatchSourceTimer` with leeway. An app that promises to
    // save your battery must not show up in Activity Monitor's Energy tab, and an unqualified
    // 1-second timer with no tolerance does exactly that.

    func startTimer(_ which: LidwingTimer) {
        stopTimer(which)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        switch which {
        case .verify:
            // The only fast one, and it lives for at most two seconds.
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                self?.deliver(self?.machine.handle(.verifyTick) ?? [])
            }
            verifyTimer = timer
        case .reassert:
            timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                self?.deliver(self?.machine.handle(.reassertTick) ?? [])
            }
            reassertTimer = timer
        case .reconcile:
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                self?.deliver(self?.machine.handle(.reconcileTick) ?? [])
            }
            reconcileTimer = timer
        case .agentPoll:
            // Fifteen seconds with two of leeway. A GUI app would get a launch notification;
            // `claude` and `codex` are command-line processes and there is no such thing for
            // them, so this is the one unavoidable poll in the product.
            timer.schedule(deadline: .now() + 2, repeating: 15, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.pollForAgents() }
            agentPollTimer = timer
        }
        timer.resume()
    }

    func stopTimer(_ which: LidwingTimer) {
        switch which {
        case .verify: verifyTimer?.cancel(); verifyTimer = nil
        case .reassert: reassertTimer?.cancel(); reassertTimer = nil
        case .reconcile: reconcileTimer?.cancel(); reconcileTimer = nil
        case .agentPoll: agentPollTimer?.cancel(); agentPollTimer = nil
        }
    }

    // MARK: App Nap and sudden termination

    func beginActivity() {
        guard activity == nil else { return }
        // Deliberately not `.idleSystemSleepDisabled`: that would ship a misleading assertion
        // which provably does nothing for lid close. This is only about not being napped.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                         reason: "Keeping this Mac awake")
        // macOS enables sudden termination for LSUIElement apps by default, which is exactly
        // wrong when quitting has to run a restore first.
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            ProcessInfo.processInfo.enableSuddenTermination()
        }
    }
}
