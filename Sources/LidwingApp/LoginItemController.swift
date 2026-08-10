import Foundation
import ServiceManagement
import LidwingCore

/// Opening Lidwing at login, through `SMAppService.mainApp` and nothing else.
///
/// The decision about what the UI shows lives in `LidwingCore.LoginItem`, where it is tested.
/// This file is only the part that has to touch the framework: reading the live status and
/// asking macOS to change it.
///
/// There is deliberately no stored preference anywhere in this file. The user can revoke a
/// login item in System Settings while Lidwing is not running, and any boolean of ours would
/// then be wrong in the direction that matters - a ticked box and nothing launching.
enum LoginItemController {

    /// The live status. Read every time it is shown; never cached.
    static var status: LoginItemStatus {
        guard #available(macOS 13.0, *) else { return .unavailable }
        // `SMAppService.mainApp` needs a real bundle. During development the executable runs
        // outside one, and registering would fail with an error the user cannot act on.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }

        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .notRegistered
        @unknown default:
            // A status this build has never heard of. Reporting it as "not registered" invites
            // the user to switch it on, which is the harmless direction: registering something
            // already registered is idempotent, while claiming it is enabled would be a lie.
            return .notRegistered
        }
    }

    /// Asks macOS to open Lidwing at login, or to stop.
    ///
    /// Returns the error message if macOS refused, and nil if it agreed. The caller shows the
    /// message rather than silently reverting a checkbox, because a checkbox that springs back
    /// with no explanation is the worst of the three possible behaviours.
    static func set(_ wanted: Bool) -> String? {
        guard #available(macOS 13.0, *) else {
            return Strings.text("login.unavailable",
                                "Opening at login needs macOS 13 or later.")
        }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return Strings.text("login.failed", "macOS would not change this: %1$@",
                                error.localizedDescription)
        }
    }
}
