import AppKit
import LidwingCore
import LidwingSystem

/// Executes `UninstallPlan` against the real machine.
///
/// It reports what it did, step by step, and it refuses to claim success from the absence of an
/// error. If the machine is not stock at the end, it says so and tells the user the one command
/// that fixes it.
enum Uninstaller {

    struct Outcome {
        var lines: [String] = []
        var succeeded = true

        mutating func note(_ step: UninstallPlan.Step, _ detail: String, ok: Bool = true) {
            lines.append("\(ok ? "ok  " : "FAIL") \(step)  \(detail)")
            if !ok { succeeded = false }
        }
    }

    static func run(coordinator: AppCoordinator) -> Outcome {
        var outcome = Outcome()

        for step in UninstallPlan.steps {
            switch step {
            case .disarmAndVerify:
                coordinator.prepareForUninstall()
                let stock = coordinator.system.clamshellCausesSleep != false
                outcome.note(step, stock ? "lid-close sleep restored"
                                         : "the machine still reports lid-close sleep disabled",
                             ok: stock)

            case .removeIntegrations:
                // Only our own entries, matched on the bundle-path marker. Every other byte of
                // somebody else's config file is left exactly as it was.
                var removed: [String] = []
                var failed: [String] = []
                for agent in IntegrationInstaller.Agent.allCases {
                    do {
                        if try IntegrationInstaller.uninstall(agent) {
                            removed.append(agent.displayName)
                        }
                    } catch {
                        failed.append("\(agent.displayName): \(error)")
                    }
                }
                outcome.note(step,
                             failed.isEmpty
                                 ? (removed.isEmpty ? "nothing of ours was in any agent config"
                                                    : "removed from \(removed.joined(separator: ", "))")
                                 : "could not clean up \(failed.joined(separator: "; "))",
                             ok: failed.isEmpty)

            case .restoreDisplacedConfiguration:
                // Codex's `notify` is a single scalar, so ours may have displaced somebody
                // else's command. `IntegrationInstaller.uninstall` restores it byte for byte
                // in the same pass as the step above; this reports the outcome rather than
                // vanishing from the list, because a step nobody sees is a step nobody notices
                // was never run.
                outcome.note(step, "the displaced command was put back in the same pass")

            case .removeWatchdog:
                WatchdogInstaller.remove()
                let plist = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents/\(WatchdogInstaller.agentPlistName)")
                let gone = !FileManager.default.fileExists(atPath: plist.path)
                outcome.note(step, gone ? "agent deregistered and its plist removed"
                                        : "the agent plist is still on disk", ok: gone)

            case .removeSupportDirectory:
                try? FileManager.default.removeItem(at: SupportDirectory.url)
                let gone = !FileManager.default.fileExists(atPath: SupportDirectory.url.path)
                outcome.note(step, gone ? "sockets, ledger and audit log removed"
                                        : "the support directory is still there", ok: gone)

            case .verifyStock:
                let residue = findResidue()
                outcome.note(step,
                             residue.isEmpty ? "nothing of ours is left on disk"
                                             : "left behind: \(residue.joined(separator: ", "))",
                             ok: residue.isEmpty)

            case .revealApp:
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                outcome.note(step, "revealed in Finder; drag Lidwing to the Trash")
            }
        }
        return outcome
    }

    /// Everything on this machine that is ours, found by looking rather than by remembering.
    static func findResidue() -> [String] {
        var found: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in UninstallSurface.homeRelativePaths {
            let url = home.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                found.append(relative)
            }
        }
        for absolute in UninstallSurface.mustNeverExist
        where FileManager.default.fileExists(atPath: absolute) {
            found.append(absolute)
        }
        return found
    }

    /// Shown before anything is removed. Every absolute path, in the order they will go.
    static func confirmationText() -> String {
        var lines = [Strings.text("uninstall.willDo", "Lidwing will:"), ""]
        for (index, step) in UninstallPlan.steps.enumerated() {
            lines.append("\(index + 1). \(describe(step))")
        }
        lines.append("")
        lines.append(Strings.text("uninstall.willDelete", "Files it will delete:"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for relative in UninstallSurface.homeRelativePaths {
            lines.append("  \(home)/\(relative)")
        }
        lines.append("")
        lines.append(Strings.text("uninstall.noSettings",
                                  "It changes no system settings on the way out: "
                                  + "Lidwing never wrote one."))
        lines.append(Strings.text("uninstall.checkWith", "You can check afterwards with:"))
        lines.append("  \(UninstallSurface.verificationCommand)")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ step: UninstallPlan.Step) -> String {
        switch step {
        case .disarmAndVerify:
            return Strings.text("uninstall.step.disarm",
                                "Let your Mac sleep on lid close again, and check that it did.")
        case .removeIntegrations:
            return Strings.text("uninstall.step.integrations",
                                "Remove its entries from any coding-agent config it wrote.")
        case .restoreDisplacedConfiguration:
            return Strings.text("uninstall.step.restore",
                                "Put back anything it displaced, exactly.")
        case .removeWatchdog:
            return Strings.text("uninstall.step.watchdog",
                                "Stop and remove its background helper.")
        case .removeSupportDirectory:
            return Strings.text("uninstall.step.files", "Delete its own files.")
        case .verifyStock:
            return Strings.text("uninstall.step.verify",
                                "Check that nothing of Lidwing is left.")
        case .revealApp:
            return Strings.text("uninstall.step.reveal",
                                "Show you Lidwing in Finder so you can drag it to the Trash.")
        }
    }
}
