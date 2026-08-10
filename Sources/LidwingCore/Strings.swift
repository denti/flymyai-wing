import Foundation

/// Every user-visible string, in one place, resolved through the bundle's localisations.
///
/// Two rules that outlive any particular translation:
///
/// * **Never concatenate a sentence from fragments.** `"Lidwing is " + state` produces
///   something no translator can fix and no screen reader reads naturally, and it forces UI
///   fragments where whole sentences belong. Interpolation uses positional specifiers so word
///   order can change.
/// * **Every key has a comment.** A translator seeing `"stop_at_percent"` with no context will
///   guess, and the guess will be wrong in the direction that matters — this app's strings are
///   mostly about safety limits.
///
/// The lookup falls back to the key's own English text when no catalogue is present, so the
/// product is fully functional before a single translation exists and a missing key is visible
/// rather than blank.
public enum Strings {

    /// Overridden by the host so `LidwingCore` needs no `Bundle.module` and stays portable.
    /// Set once at launch; read-only afterwards.
    public nonisolated(unsafe) static var localiser: ((_ key: String, _ fallback: String) -> String)?

    public static func text(_ key: String, _ english: String) -> String {
        localiser?(key, english) ?? english
    }

    /// Positional interpolation, so a translation can reorder the arguments.
    public static func text(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
        String(format: localiser?(key, english) ?? english, arguments: arguments)
    }
}

/// One catalogue entry. A struct rather than a tuple so the comment field cannot be dropped
/// silently when somebody adds a key in a hurry.
public struct StringEntry: Equatable, Sendable {
    public let key: String
    public let english: String
    /// Context for a translator, who will never see the code around this string.
    public let comment: String

    public init(_ key: String, _ english: String, _ comment: String) {
        self.key = key
        self.english = english
        self.comment = comment
    }
}

/// The keys, gathered so a test can assert that none is missing, duplicated, or written in a
/// way that cannot be translated.
public enum StringKey {
    public static let all: [StringEntry] = [
        // Menu — the entire visible surface of the product.
        StringEntry("menu.toggle", "Keep Awake with the Lid Closed",
         "The one command in the menu. Title case."),
        StringEntry("menu.off", "Off - your Mac sleeps normally",
         "Menu header when Lidwing is not protecting the machine."),
        StringEntry("menu.awake", "Awake - you can close the lid",
         "Menu header when protection is verified and active."),
        StringEntry("menu.awake.agent", "Awake - %1$@ is running",
         "%1$@ is a coding-agent binary name such as claude or codex."),
        StringEntry("menu.hot", "Awake - your Mac is running hot",
         "Still protecting, but the thermal guard is warning."),
        StringEntry("menu.hot.detail", "Lidwing turns off if it gets hotter.",
         "Explains what happens next if the Mac keeps heating up."),
        StringEntry("menu.battery", "Awake - battery %1$lld%%",
         "%1$lld is a whole-number percentage. Note the doubled percent sign."),
        StringEntry("menu.battery.detail", "Lidwing turns off at %1$lld%%.",
         "The user's configured battery floor."),
        StringEntry("menu.arming", "Checking that it worked\u{2026}",
         "Shown for up to two seconds while the machine is asked to confirm."),
        StringEntry("menu.arming.detail", "Lidwing never says it is on until your Mac agrees.",
         "Why there is a delay. This is a trust statement, not a progress message."),
        StringEntry("menu.disarming", "Putting your sleep setting back\u{2026}", "Shown while releasing."),
        StringEntry("menu.failed", "Your Mac slept at %1$@ despite protection",
         "%1$@ is a wall-clock time such as 03:12. The worst thing this app can report."),
        StringEntry("menu.failed.detail", "See Diagnostics. Protection is not active.", ""),
        StringEntry("menu.foreign", "Another app is keeping this Mac awake",
         "Something else holds a sleep assertion; Lidwing stood down rather than fighting it."),
        StringEntry("menu.foreign.detail", "%1$@ (pid %2$lld) - Lidwing stood down.",
         "%1$@ is the other app's name, %2$lld its process id."),
        StringEntry("menu.nolid", "This Mac has no lid",
         "Shown on a desktop Mac. The feature is hidden here, not merely disabled."),
        StringEntry("menu.nolid.detail", "There is no lid-close sleep to prevent here.", ""),
        StringEntry("menu.repair", "Something is keeping this Mac awake",
         "Launch found the machine in a non-stock state that Lidwing did not set this session."),
        StringEntry("menu.repair.detail", "It may be left over from Lidwing. Click Repair to put it back.",
         ""),
        StringEntry("menu.repair.action", "Repair Now\u{2026}", "Menu command. Real ellipsis, U+2026."),
        StringEntry("menu.sleepNow", "Sleep Now", "Releases protection, then sleeps the Mac."),
        StringEntry("menu.diagnostics", "Copy Diagnostics", ""),
        StringEntry("menu.settings", "Settings\u{2026}", "Real ellipsis, U+2026. Never 'Preferences'."),
        StringEntry("menu.uninstall", "Uninstall Lidwing\u{2026}", ""),
        StringEntry("menu.about", "About Lidwing", ""),
        StringEntry("menu.quit", "Quit Lidwing", ""),
        StringEntry("menu.agentWaiting", "%1$@ is waiting for you",
         "%1$@ is an agent name, or 'Your coding agent' when it did not say."),

        // Power and battery detail line.
        StringEntry("detail.left", "%1$@ left", "%1$@ is a duration such as 7h 12m."),
        StringEntry("detail.battery", "battery %1$lld%%",
         "%1$lld is a whole-number percentage. Note the doubled percent sign."),
        StringEntry("detail.pluggedIn", "plugged in", ""),
        StringEntry("detail.onBattery", "on battery", ""),

        // Refusals. Each one names a specific cause; there is no generic error string.
        StringEntry("refuse.noLid", "This Mac has no lid, so there is no lid-close sleep to prevent.", ""),
        StringEntry("refuse.unsupported",
         "This version of macOS changed how sleep works. Lidwing needs an update.", ""),
        StringEntry("refuse.batteryLow",
         "The battery is already at or below your stop limit. Plug in and try again.", ""),
        StringEntry("refuse.tooHot", "This Mac is too hot right now. Let it cool down and try again.", ""),
        StringEntry("refuse.foreign",
         "Another app is already keeping this Mac awake: %1$@ (pid %2$lld).",
         "%1$@ is the other app's name, %2$lld its process id."),
        StringEntry("refuse.externalDisplay",
         "macOS already does this for you while an external display is attached on power.",
         "Saying this costs a user and buys the credibility that carries the rest."),
        StringEntry("refuse.watchdog",
         "Lidwing could not start its safety watchdog, so it will not keep this Mac awake.",
         "Lidwing refuses to hold the mechanism without something that can undo it."),
        StringEntry("refuse.notInApplications", "Move Lidwing to your Applications folder first.", ""),

        // Notifications.
        StringEntry("notify.firstArm.title", "Lidwing is running", ""),
        StringEntry("notify.firstArm.body",
         "Look for the wing in your menu bar. You can close the lid now.", ""),
        StringEntry("notify.stopped.title", "Lidwing stopped", ""),
        StringEntry("notify.armFailed.title", "Lidwing could not keep this Mac awake", ""),
        StringEntry("notify.armFailed.body",
         "Your Mac will still sleep when you close the lid. Open Lidwing for details.", ""),
        StringEntry("notify.releaseFailed.title", "Lidwing could not put your sleep setting back", ""),
        StringEntry("notify.releaseFailed.body",
         "Open Lidwing and choose Repair, or restart your Mac.", ""),
        StringEntry("notify.slept.title", "Your Mac slept despite protection", ""),
        StringEntry("notify.slept.body",
         "Lidwing re-armed itself. See Diagnostics for the exact time.", ""),
        StringEntry("notify.recovered.title", "Lidwing quit unexpectedly", ""),
        StringEntry("notify.recovered.body", "Lid-close sleep has been restored.", ""),
        StringEntry("notify.bag.title", "Don't put your Mac in a bag while Lidwing is on", ""),
        StringEntry("notify.bag.body", "With the lid closed and no airflow it can get very hot.", "")
    ]
}
