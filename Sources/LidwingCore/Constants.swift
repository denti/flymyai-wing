import Foundation

/// Identifiers that are baked into a launchd label, a code-signing requirement and markers
/// written into third-party configuration files. Renaming any of these later means shipping a
/// migration that edits other people's files, so they are frozen.
public enum LidwingID {
    public static let productName = "Lidwing"
    public static let bundleID = "ai.flymy.lidwing"
    public static let watchdogLabel = "ai.flymy.lidwing.watchdog"
    public static let helperLabel = "ai.flymy.lidwing.helper"
    public static let reconcilerLabel = "ai.flymy.lidwing.reconciler"
    public static let machService = "ai.flymy.lidwing.helper"
    public static let supportDomain = "lidwing.app"

    /// Directory under `~/Library/Application Support` holding the ledger, the audit log and
    /// the two sockets.
    public static let supportDirectoryName = "Lidwing"

    /// The substring an installed integration command must contain for the uninstaller to
    /// recognise it as ours. Deliberately the app-bundle path fragment: it is unique, it is
    /// visible to the user in the diff we show before writing, and it cannot collide with a
    /// third-party tool that merely mentions the word "lidwing".
    public static let integrationMarker = "/Lidwing.app/"

    /// Name of the notify helper as installed inside the bundle.
    public static let notifyHelperName = "lidwing-notify"

    public static let controlSocketName = "control.sock"
    public static let notifySocketName = "notify.sock"
    public static let ledgerFileName = "ledger.json"
    public static let auditFileName = "audit.jsonl"
}

/// Wire-protocol version for `control.sock`. Bumped only on an incompatible change; the
/// watchdog rejects messages it does not understand rather than guessing.
public let lidwingControlProtocolVersion = 1
