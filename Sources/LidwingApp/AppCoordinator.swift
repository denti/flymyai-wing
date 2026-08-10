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
    private let audit: FileAuditSink
    private let ledger: FileLedgerStore
    private let watchdog: WatchdogClient
    private let chimes = ChimePlayer()
    private let preferences = Preferences.shared
    private var observers: SystemObservers?

    private var verifyTimer: DispatchSourceTimer?
    private var reassertTimer: DispatchSourceTimer?
    private var reconcileTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    private(set) var lastFailureAt: Date?
    private(set) var armedSince: Date?
    /// Set once the user has been asked, so a notification prompt never appears at launch.
    private var askedForNotificationPermission = false

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

        readWatchdogRecoveryRecord()
        deliver(machine.handle(.launch))
        // No timer is started here. The guards exist to end an armed session, so they run for
        // exactly as long as one lasts; the menu computes its own state when it is opened.
        // An idle Lidwing does no work at all.
    }

    func stop() {
        deliver(machine.handle(.appWillTerminate))
        observers?.stop()
        observers = nil
        stopTimer(.verify)
        stopTimer(.reassert)
        stopTimer(.reconcile)
        system.closeUserClient()
    }

    // MARK: user actions

    func toggle() {
        if machine.state.isProtecting || machine.state == .arming {
            deliver(machine.handle(.userDisarm))
        } else {
            deliver(machine.handle(.userArm))
        }
    }

    func repairNow() {
        deliver(machine.handle(.repairRequested))
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
            system.sawClamshellNotification = true
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

    // MARK: effects out

    private func deliver(_ effects: [LidwingEffect]) {
        var needsRefresh = false
        for effect in effects {
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
                presentRefusal(refusal)
            case .offerRepair(let cause):
                presentRepair(cause)
            case .showForeignHolder:
                needsRefresh = true
            case .beginActivity:
                beginActivity()
            case .endActivity:
                endActivity()
            case .uiNeedsRefresh:
                needsRefresh = true
            }
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

    private var lastPresentedState: LidwingState?

    // MARK: timers
    //
    // Every repeating timer is a `DispatchSourceTimer` with leeway. An app that promises to
    // save your battery must not show up in Activity Monitor's Energy tab, and an unqualified
    // 1-second timer with no tolerance does exactly that.

    private func startTimer(_ which: LidwingTimer) {
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
        }
        timer.resume()
    }

    private func stopTimer(_ which: LidwingTimer) {
        switch which {
        case .verify: verifyTimer?.cancel(); verifyTimer = nil
        case .reassert: reassertTimer?.cancel(); reassertTimer = nil
        case .reconcile: reconcileTimer?.cancel(); reconcileTimer = nil
        }
    }

    // MARK: App Nap and sudden termination

    private func beginActivity() {
        guard activity == nil else { return }
        // Deliberately not `.idleSystemSleepDisabled`: that would ship a misleading assertion
        // which provably does nothing for lid close. This is only about not being napped.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                         reason: "Keeping this Mac awake")
        // macOS enables sudden termination for LSUIElement apps by default, which is exactly
        // wrong when quitting has to run a restore first.
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            ProcessInfo.processInfo.enableSuddenTermination()
        }
    }

    // MARK: user-facing output

    private func present(_ notice: UserNotice) {
        switch notice {
        case .sleptWhileArmed(let at):
            lastFailureAt = at
        default:
            break
        }
        guard let (title, body) = Self.copy(for: notice) else { return }
        postNotification(title: title, body: body)
    }

    static func copy(for notice: UserNotice) -> (String, String)? {
        switch notice {
        case .firstArm:
            return ("Lidwing is running",
                    "Look for the wing in your menu bar. You can close the lid now.")
        case .autoDisarmed(let reason):
            guard let sentence = reason.userFacingSentence else { return nil }
            return ("Lidwing stopped", sentence)
        case .armFailed:
            return ("Lidwing could not keep this Mac awake",
                    "Your Mac will still sleep when you close the lid. Open Lidwing for details.")
        case .releaseFailed:
            return ("Lidwing could not put your sleep setting back",
                    "Open Lidwing and choose Repair, or restart your Mac.")
        case .sleptWhileArmed:
            return ("Your Mac slept despite protection",
                    "Lidwing re-armed itself. See Diagnostics for the exact time.")
        case .watchdogRecovered:
            return ("Lidwing quit unexpectedly",
                    "Lid-close sleep has been restored.")
        case .groundTruthLost:
            return ("Lidwing is no longer protecting this Mac",
                    "Something else changed the sleep setting. Open Lidwing for details.")
        case .degraded(let warning):
            switch warning {
            case .thermalSerious:
                return ("Your Mac is running hot",
                        "Lidwing stops automatically if it gets hotter.")
            case .batteryNearFloor:
                return ("Battery is getting low",
                        "Lidwing stops soon and lets your Mac sleep normally.")
            case .foreignHolder:
                return nil      // shown in the menu; a notification here would be noise
            }
        case .bagWarning:
            return ("Don't put your Mac in a bag while Lidwing is on",
                    "With the lid closed and no airflow it can get very hot.")
        }
    }

    /// Authorisation is requested lazily, on the first event that needs one — never at launch.
    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
        if askedForNotificationPermission {
            deliver()
            return
        }
        askedForNotificationPermission = true
        // Never `.criticalAlert`: it needs an entitlement Apple grants by written request and
        // effectively never for a utility.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { deliver() }
        }
    }

    /// True while a modal is on screen. A modal runs its own run loop, so the reconcile timer
    /// keeps firing underneath it — without this, a second dialog can land on top of the first
    /// and the user has to dismiss a stack.
    private var isPresentingModal = false

    private func runModal(_ build: () -> NSAlert) -> NSApplication.ModalResponse {
        guard !isPresentingModal else { return .cancel }
        isPresentingModal = true
        defer { isPresentingModal = false }
        NSApp.activate(ignoringOtherApps: true)
        return build().runModal()
    }

    private func presentRefusal(_ refusal: ArmRefusal) {
        let alert = NSAlert()
        alert.messageText = "Lidwing did not turn on"
        alert.informativeText = refusal.sentence
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = runModal { alert }
    }

    private func presentRepair(_ cause: RepairCause) {
        let alert = NSAlert()
        alert.messageText = "This Mac is set not to sleep when you close the lid"
        alert.informativeText = """
        Lidwing did not set this in the session that is running now, so it will not change \
        anything without asking. This is usually left over from a previous run.

        Repair puts the setting back the way macOS ships it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Leave It Alone")
        _ = cause
        if runModal({ alert }) == .alertFirstButtonReturn {
            deliver(machine.handle(.repairRequested))
        }
    }

    /// The watchdog leaves a record on disk when it cleans up after us. Reading it here is how
    /// the user finds out what happened, even though the process that noticed is long gone.
    private func readWatchdogRecoveryRecord() {
        let url = SupportDirectory.file("recovered.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = object["at"] as? Double else { return }
        try? FileManager.default.removeItem(at: url)
        deliver(machine.handle(.watchdogReportedRecovery(at: Date(timeIntervalSince1970: seconds))))
    }

    // MARK: presentation

    func snapshot() -> MenuPresenter.Snapshot {
        // One read, not three: `onAC`, `batteryCurrent` and `batteryMax` each copy the whole
        // power-source blob, and the menu needs all three at once.
        let power = PowerSourceReader.read()
        let sample = PowerSample(onAC: power.onAC, current: power.current, max: power.max,
                                 warning: power.warning)
        var remaining: Int?
        if let limit = machine.settings.maxDurationSeconds, let since = armedSince {
            remaining = max(0, limit - Int(Date().timeIntervalSince(since)))
        }
        return MenuPresenter.Snapshot(
            state: machine.state,
            armedSince: armedSince,
            now: Date(),
            batteryPercent: sample.percentage,
            onAC: power.onAC,
            thermal: system.thermalState,
            floorPercent: machine.settings.batteryFloorPercent,
            remainingSeconds: remaining,
            lastFailureAt: lastFailureAt,
            foreignHolder: system.foreignAssertionHolders.first,
            agentRunning: system.runningAgentBinaries.sorted().first)
    }

    func diagnosticsText() -> String {
        DiagnosticsReport.build(system: system, machine: machine, audit: audit,
                                watchdogConnected: watchdog.isConnected)
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
