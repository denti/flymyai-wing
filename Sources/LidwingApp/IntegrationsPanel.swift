import AppKit
import LidwingCore
import LidwingSystem

/// The coding-agent integrations, and the disclosure that makes them acceptable.
///
/// Every integration is **off by default** and every one of them shows the literal diff of what
/// will be written before it writes anything. Writing to a file the user did not know about is
/// the behaviour that would end this product's credibility, and no amount of convenience is
/// worth it.
enum IntegrationsPanel {

    /// The helper the hook will run, inside our own bundle.
    static func helperPath() -> String {
        Bundle.main.resourceURL?.appendingPathComponent(LidwingID.notifyHelperName).path
            ?? "/Applications/Lidwing.app/Contents/Resources/\(LidwingID.notifyHelperName)"
    }

    /// Shows the diff, then writes only if the user says so. Returns true when installed.
    @discardableResult
    static func offerInstall(_ agent: IntegrationInstaller.Agent) -> Bool {
        guard IntegrationInstaller.isPresent(agent) else {
            inform(title: Strings.text("integration.absent.title", "%1$@ is not installed here",
                                       agent.displayName),
                   body: Strings.text("integration.absent.body",
                                      "Lidwing looked for ~/%1$@ and did not find it. It never "
                                      + "creates a configuration file for a tool you do not have.",
                                      agent.relativePath))
            return false
        }

        let preview: IntegrationInstaller.Preview
        do {
            preview = try IntegrationInstaller.previewInstall(agent, helperPath: helperPath())
        } catch {
            // A file we could not parse is a file we do not write to. Ever.
            inform(title: Strings.text("integration.unreadable.title",
                                       "Lidwing will not change %1$@'s settings",
                                       agent.displayName),
                   body: Strings.text("integration.unreadable.body",
                                      "It could not read ~/%1$@ well enough to be sure it would "
                                      + "change only its own line, so it changed nothing at all.",
                                      agent.relativePath) + "\n\n\(error)")
            return false
        }

        guard preview.willChange else {
            inform(title: Strings.text("integration.already.title", "Already set up"),
                   body: Strings.text("integration.already.body",
                                      "%1$@ already runs Lidwing's notifier. Nothing to do.",
                                      agent.displayName))
            return true
        }

        let alert = NSAlert()
        alert.messageText = Strings.text("integration.offer.title", "Add Lidwing to %1$@?",
                                         agent.displayName)
        var body = [Strings.text("integration.offer.body",
                                 "Lidwing will change exactly these lines in ~/%1$@, and keep a "
                                 + "dated backup of the file beside it.", agent.relativePath), ""]
        if let displaced = preview.displaced, !displaced.isEmpty {
            body.append(Strings.text("integration.offer.chaining",
                                     "%1$@ already runs something here. Lidwing will chain to it "
                                     + "rather than replace it, so it keeps working:",
                                     agent.displayName))
            body.append("  " + displaced.joined(separator: " "))
            body.append("")
        }
        body.append(preview.diff)
        alert.informativeText = body.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.text("integration.offer.confirm", "Write These Lines"))
        alert.addButton(withTitle: Strings.text("button.cancel", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try IntegrationInstaller.install(agent, helperPath: helperPath())
            inform(title: Strings.text("integration.done.title", "Done"),
                   body: Strings.text("integration.done.body",
                                      "%1$@ will tell Lidwing when it needs you, and Lidwing will "
                                      + "make a sound so you hear it with the lid closed.",
                                      agent.displayName))
            return true
        } catch {
            inform(title: Strings.text("integration.writeFailed.title",
                                       "Lidwing could not write the file"), body: "\(error)")
            return false
        }
    }

    @discardableResult
    static func remove(_ agent: IntegrationInstaller.Agent) -> Bool {
        do {
            let removed = try IntegrationInstaller.uninstall(agent)
            inform(title: removed ? Strings.text("integration.removed.title", "Removed")
                                  : Strings.text("integration.nothing.title", "Nothing to remove"),
                   body: removed
                       ? Strings.text("integration.removed.body",
                                      "Lidwing's entry is gone from ~/%1$@. Everything else in "
                                      + "the file is exactly as it was.", agent.relativePath)
                       : Strings.text("integration.nothing.body",
                                      "Lidwing had not written anything to ~/%1$@.",
                                      agent.relativePath))
            return removed
        } catch {
            inform(title: Strings.text("integration.writeFailed.title",
                                       "Lidwing could not write the file"), body: "\(error)")
            return false
        }
    }

    private static func inform(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.text("button.ok", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
