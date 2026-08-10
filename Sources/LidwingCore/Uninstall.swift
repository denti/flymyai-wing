import Foundation

/// The uninstall plan, as data.
///
/// It is a value rather than a procedure so that the **order** can be tested without a machine.
/// Order is load-bearing here: reverse two of these steps and the result is a Mac that has
/// permanently lost lid-close sleep with no process left alive to undo it. For an app
/// distributed outside the App Store that can disable sleep, no removal path is how a project
/// gets called malware — so this was written before the installer.
public struct UninstallPlan: Equatable, Sendable {

    public enum Step: Equatable, Sendable {
        /// Release the mechanism and confirm the machine agrees. Always first.
        case disarmAndVerify
        /// Remove only hook entries whose command contains our bundle path, leaving every
        /// other byte of the file identical.
        case removeIntegrations
        /// Put a third-party value we displaced back exactly as we found it.
        case restoreDisplacedConfiguration
        /// Stop and deregister the watchdog agent.
        case removeWatchdog
        /// Delete the sockets, the ledger and the audit log.
        case removeSupportDirectory
        /// Read the machine one more time and refuse to claim success if it is not stock.
        case verifyStock
        /// Show the user where the app is so they can move it to the Trash themselves.
        case revealApp
    }

    public static let steps: [Step] = [
        .disarmAndVerify,
        .removeIntegrations,
        .restoreDisplacedConfiguration,
        .removeWatchdog,
        .removeSupportDirectory,
        .verifyStock,
        .revealApp
    ]

    /// Why each step must come before the next one. Kept next to the order so that a future
    /// reader reordering them has to read the reason first.
    public static func rationale(for step: Step) -> String {
        switch step {
        case .disarmAndVerify:
            return "Nothing else may run while the machine is still held awake by us."
        case .removeIntegrations:
            return "Remove our hook while our binary still exists to be matched by path."
        case .restoreDisplacedConfiguration:
            return "Put back the tool we chained to, before our own preferences are deleted."
        case .removeWatchdog:
            return "The dead-man goes after the thing it was watching is already released."
        case .removeSupportDirectory:
            return "Our own files last: the ledger is what a repair path would have needed."
        case .verifyStock:
            return "Never report success from the absence of an error."
        case .revealApp:
            return "The user drags the app to the Trash; we never delete ourselves silently."
        }
    }
}

/// Paths an uninstall must account for, and the check that proves nothing was left.
///
/// Kept in the portable module so the list is testable and so it cannot drift from the list
/// the documentation shows the user.
public enum UninstallSurface {
    /// Everything Lidwing can create, relative to the user's home directory.
    public static let homeRelativePaths: [String] = [
        "Library/Application Support/Lidwing",
        "Library/LaunchAgents/ai.flymy.lidwing.watchdog.plist",
        "Library/Preferences/ai.flymy.lidwing.plist",
        "Library/Caches/ai.flymy.lidwing"
    ]

    /// Third-party files Lidwing may edit. It never deletes these — it removes exactly its own
    /// entries and leaves the rest byte-identical.
    public static let thirdPartyFiles: [String] = [
        ".claude/settings.json",
        ".codex/config.toml"
    ]

    /// Absolute paths that must **never** contain anything of ours. Tier 1 installs no
    /// privileged helper at all, so a file here means a regression back to a root daemon.
    public static let mustNeverExist: [String] = [
        "/Library/LaunchDaemons/ai.flymy.lidwing.helper.plist",
        "/Library/PrivilegedHelperTools/ai.flymy.lidwing.helper",
        "/Library/Application Support/ai.flymy.lidwing"
    ]

    /// The command a user can run to check us, printed in the docs and in the About panel.
    public static let verificationCommand =
        "find ~/Library /Library -iname '*lidwing*' 2>/dev/null"
}
