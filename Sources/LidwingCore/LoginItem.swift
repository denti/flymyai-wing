import Foundation

/// What macOS says about opening Lidwing at login, and what the Settings window shows for it.
///
/// Three rules govern this feature, and all three are things apps get wrong often enough to
/// have their own entries on the antipattern list:
///
/// * **Never on by default.** Registering a login item without asking is the single most
///   disliked behaviour of menu-bar apps, and a checkbox that arrives pre-ticked is the same
///   act with a fig leaf.
/// * **Never cache our own boolean.** The user can revoke a login item in System Settings while
///   Lidwing is not running. A stored `launchAtLogin` flag then lies, and it lies in the
///   direction that matters: the checkbox says "on" and nothing launches.
/// * **`SMAppService` only.** `SMLoginItemSetEnabled` is deprecated, and a hand-written
///   `~/Library/LaunchAgents` plist is opaque in System Settings and reads as
///   software-that-installed-itself.
///
/// The third rule has a consequence worth stating plainly: `SMAppService` is macOS 13+, this
/// product's floor is 12.0, and the two pre-13 mechanisms are the two the rule forbids. So on
/// macOS 12 there is no checkbox at all, with a sentence saying why. Shipping the forbidden
/// mechanism to one OS version, or shipping a checkbox that silently does nothing there, are
/// both worse than not offering the feature.
public enum LoginItemStatus: Equatable, Sendable {
    /// No compliant mechanism exists on this OS. macOS 12.
    case unavailable
    case notRegistered
    case enabled
    /// Registered, and waiting for the user to approve it in System Settings.
    case requiresApproval
    /// macOS knows about a registration it can no longer find - the app moved, typically.
    case notFound
}

public struct LoginItemPresentation: Equatable, Sendable {
    public let isVisible: Bool
    public let isChecked: Bool
    public let isInteractive: Bool
    /// A sentence under the checkbox, or nil when there is nothing worth saying.
    public let note: String?

    public init(isVisible: Bool, isChecked: Bool, isInteractive: Bool, note: String?) {
        self.isVisible = isVisible
        self.isChecked = isChecked
        self.isInteractive = isInteractive
        self.note = note
    }
}

public enum LoginItem {

    /// Derives everything the UI shows from the live status, and from nothing else.
    ///
    /// The signature is the point: there is no stored preference to pass in, so there is nothing
    /// to disagree with the system. If this took a cached boolean it could be wrong, and the
    /// only way to guarantee it cannot is to give it no way to know.
    public static func presentation(for status: LoginItemStatus) -> LoginItemPresentation {
        switch status {
        case .unavailable:
            return LoginItemPresentation(
                isVisible: false, isChecked: false, isInteractive: false,
                note: Strings.text("login.unavailable",
                                   "Opening at login needs macOS 13 or later."))
        case .notRegistered:
            return LoginItemPresentation(isVisible: true, isChecked: false,
                                         isInteractive: true, note: nil)
        case .enabled:
            return LoginItemPresentation(isVisible: true, isChecked: true,
                                         isInteractive: true, note: nil)
        case .requiresApproval:
            // Checked, because Lidwing did register: showing it unticked would invite the user
            // to tick it again, which changes nothing. What is missing is their approval, so
            // that is what the sentence asks for.
            return LoginItemPresentation(
                isVisible: true, isChecked: true, isInteractive: true,
                note: Strings.text("login.approval",
                                   "Waiting for your approval in System Settings, "
                                   + "under General \u{25B8} Login Items."))
        case .notFound:
            return LoginItemPresentation(
                isVisible: true, isChecked: false, isInteractive: true,
                note: Strings.text("login.notFound",
                                   "macOS lost track of this. "
                                   + "Switch it on again to fix it."))
        }
    }

    /// Whether Lidwing will actually be launched at the next login.
    ///
    /// `requiresApproval` is deliberately **not** counted as yes. It looks like success from
    /// inside the app and does nothing at all at login, and a diagnostics report that calls it
    /// "on" sends the reader looking in the wrong place.
    public static func willLaunchAtLogin(_ status: LoginItemStatus) -> Bool {
        status == .enabled
    }
}
