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
            inform(title: "\(agent.displayName) is not installed here",
                   body: "Lidwing looked for ~/\(agent.relativePath) and did not find it. It "
                       + "never creates a configuration file for a tool you do not have.")
            return false
        }

        let preview: IntegrationInstaller.Preview
        do {
            preview = try IntegrationInstaller.previewInstall(agent, helperPath: helperPath())
        } catch {
            // A file we could not parse is a file we do not write to. Ever.
            inform(title: "Lidwing will not change \(agent.displayName)'s settings",
                   body: "It could not read ~/\(agent.relativePath) well enough to be sure it "
                       + "would change only its own line, so it changed nothing at all.\n\n"
                       + "\(error)")
            return false
        }

        guard preview.willChange else {
            inform(title: "Already set up",
                   body: "\(agent.displayName) already runs Lidwing's notifier. Nothing to do.")
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Add Lidwing to \(agent.displayName)?"
        var body = ["Lidwing will change exactly these lines in ~/\(agent.relativePath), and "
                    + "keep a dated backup of the file beside it.", ""]
        if let displaced = preview.displaced, !displaced.isEmpty {
            body.append("\(agent.displayName) already runs something here. Lidwing will chain "
                        + "to it rather than replace it, so it keeps working:")
            body.append("  " + displaced.joined(separator: " "))
            body.append("")
        }
        body.append(preview.diff)
        alert.informativeText = body.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Write These Lines")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try IntegrationInstaller.install(agent, helperPath: helperPath())
            inform(title: "Done",
                   body: "\(agent.displayName) will tell Lidwing when it needs you, and Lidwing "
                       + "will make a sound so you hear it with the lid closed.")
            return true
        } catch {
            inform(title: "Lidwing could not write the file", body: "\(error)")
            return false
        }
    }

    @discardableResult
    static func remove(_ agent: IntegrationInstaller.Agent) -> Bool {
        do {
            let removed = try IntegrationInstaller.uninstall(agent)
            inform(title: removed ? "Removed" : "Nothing to remove",
                   body: removed
                       ? "Lidwing's entry is gone from ~/\(agent.relativePath). Everything else "
                         + "in the file is exactly as it was."
                       : "Lidwing had not written anything to ~/\(agent.relativePath).")
            return removed
        } catch {
            inform(title: "Lidwing could not change the file", body: "\(error)")
            return false
        }
    }

    private static func inform(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
