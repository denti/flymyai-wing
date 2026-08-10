import AppKit
import UserNotifications
import LidwingCore
import LidwingSystem

// Everything the user sees or hears, in its own file so the coordinator's own body stays a
// size a person can hold in their head. Same type, same rules.
extension AppCoordinator {

    // MARK: user-facing output

    func present(_ notice: UserNotice) {
        switch notice {
        case .sleptWhileArmed(let at):
            lastFailureAt = at
            log.emit(LogCatalogue.sleptWhileArmed, .power, [
                "lid": system.lidState.rawValue,
                "onAC": String(system.onAC),
                "displays": String(system.onlineDisplayCount),
                "thermal": String(describing: system.thermalState)
            ])
        case .groundTruthLost:
            log.emit(LogCatalogue.groundTruthLost, .power,
                     ["causesSleep": String(describing: system.clamshellCausesSleep)])
        case .armFailed:
            log.emit(LogCatalogue.armNoEffect, .power,
                     ["causesSleep": String(describing: system.clamshellCausesSleep)])
        case .releaseFailed:
            log.emit(LogCatalogue.releaseNoEffect, .power,
                     ["causesSleep": String(describing: system.clamshellCausesSleep)])
        case .autoDisarmed(let reason):
            log.emit(LogCatalogue.disarmed, .power, ["reason": reason.rawValue])
        case .watchdogRecovered(let at):
            log.emit(LogCatalogue.watchdogRecovered, .watchdog,
                     ["atUnix": String(Int(at.timeIntervalSince1970))])
        default:
            break
        }
        guard let (title, body) = Self.copy(for: notice) else { return }
        postNotification(title: title, body: body)
    }

    static func copy(for notice: UserNotice) -> (String, String)? {
        switch notice {
        case .firstArm:
            return (Strings.text("notify.firstArm.title", "Lidwing is running"),
                    Strings.text("notify.firstArm.body",
                                 "Look for the wing in your menu bar. You can close the lid now."))
        case .autoDisarmed(let reason):
            guard let sentence = reason.userFacingSentence else { return nil }
            return (Strings.text("notify.stopped.title", "Lidwing stopped"), sentence)
        case .armFailed:
            return (Strings.text("notify.armFailed.title",
                                 "Lidwing could not keep this Mac awake"),
                    Strings.text("notify.armFailed.body",
                                 "Your Mac will still sleep when you close the lid. "
                                 + "Open Lidwing for details."))
        case .releaseFailed:
            return (Strings.text("notify.releaseFailed.title",
                                 "Lidwing could not put your sleep setting back"),
                    Strings.text("notify.releaseFailed.body",
                                 "Open Lidwing and choose Repair, or restart your Mac."))
        case .sleptWhileArmed:
            return (Strings.text("notify.slept.title", "Your Mac slept despite protection"),
                    Strings.text("notify.slept.body",
                                 "Lidwing re-armed itself. See Diagnostics for the exact time."))
        case .watchdogRecovered:
            return (Strings.text("notify.recovered.title", "Lidwing quit unexpectedly"),
                    Strings.text("notify.recovered.body", "Lid-close sleep has been restored."))
        case .groundTruthLost:
            return (Strings.text("notify.groundTruthLost.title",
                                 "Lidwing is no longer protecting this Mac"),
                    Strings.text("notify.groundTruthLost.body",
                                 "Something else changed the sleep setting. "
                                 + "Open Lidwing for details."))
        case .degraded(let warning):
            switch warning {
            case .thermalSerious:
                return (Strings.text("notify.hot.title", "Your Mac is running hot"),
                        Strings.text("notify.hot.body",
                                     "Lidwing stops automatically if it gets hotter."))
            case .batteryNearFloor:
                return (Strings.text("notify.lowBattery.title", "Battery is getting low"),
                        Strings.text("notify.lowBattery.body",
                                     "Lidwing stops soon and lets your Mac sleep normally."))
            case .foreignHolder:
                return nil      // shown in the menu; a notification here would be noise
            }
        case .bagWarning:
            return (Strings.text("notify.bag.title",
                                 "Don't put your Mac in a bag while Lidwing is on"),
                    Strings.text("notify.bag.body",
                                 "With the lid closed and no airflow it can get very hot."))
        case .recheckedAfterOSUpdate(_, let to):
            // Said once, after the first arm that verifies on a new build. The reassurance is
            // only worth an interruption because the alternative - this product silently not
            // working after a macOS update - is the failure it is most likely to have.
            return (Strings.text("notify.osRechecked.title",
                                 "macOS changed, and Lidwing still works"),
                    Strings.text("notify.osRechecked.body",
                                 "Checked against %1$@ just now, not assumed.", to))
        }
    }

    /// Authorisation is requested lazily, on the first event that needs one — never at launch.
    func postNotification(title: String, body: String) {
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

    func runModal(_ build: () -> NSAlert) -> NSApplication.ModalResponse {
        guard !isPresentingModal else { return .cancel }
        isPresentingModal = true
        defer { isPresentingModal = false }
        NSApp.activate(ignoringOtherApps: true)
        return build().runModal()
    }

    func presentRefusal(_ refusal: ArmRefusal) {
        let alert = NSAlert()
        alert.messageText = Strings.text("dialog.didNotTurnOn.title", "Lidwing did not turn on")
        alert.informativeText = refusal.sentence
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.text("button.ok", "OK"))
        _ = runModal { alert }
    }

    func presentRepair(_ cause: RepairCause) {
        let alert = NSAlert()
        alert.messageText = Strings.text("dialog.repair.title",
                                         "This Mac is set not to sleep when you close the lid")
        alert.informativeText = Strings.text(
            "dialog.repair.body",
            "Lidwing did not set this in the session that is running now, so it will not change "
            + "anything without asking. This is usually left over from a previous run.")
            + "\n\n"
            + Strings.text("dialog.repair.body2",
                           "Repair puts the setting back the way macOS ships it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.text("dialog.repair.confirm", "Repair"))
        alert.addButton(withTitle: Strings.text("dialog.repair.decline", "Leave It Alone"))
        _ = cause
        if runModal({ alert }) == .alertFirstButtonReturn {
            deliver(machine.handle(.repairRequested))
        }
    }

    /// The watchdog leaves a record on disk when it cleans up after us. Reading it here is how
    /// the user finds out what happened, even though the process that noticed is long gone.
    func readWatchdogRecoveryRecord() {
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
            agentRunning: system.runningAgentBinaries.sorted().first,
            sleepsObserved: machine.session?.sleepFailureCount ?? 0)
    }

    func diagnosticsText() -> String {
        DiagnosticsReport.build(system: system, machine: machine, audit: audit,
                                soundWarning: soundSelfCheckWarning,
                                watchdogConnected: watchdog.isConnected)
    }

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
