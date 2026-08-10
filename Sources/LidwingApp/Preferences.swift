import Foundation
import LidwingCore

/// Everything the user can change, in one place, backed by `UserDefaults`.
///
/// Nothing here is ever trusted blindly: `SafetySettings` clamps what it is given, so a
/// corrupted or hand-edited preferences file cannot remove the battery floor or make the app
/// refuse to launch.
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let batteryFloor = "batteryFloorPercent"
        static let maxDuration = "maxDurationSeconds"
        static let noDurationLimit = "noDurationLimit"
        static let thermalGuard = "thermalGuardEnabled"
        static let mode = "mode"
        static let hasEverArmed = "hasEverArmed"
        static let lastBagWarning = "lastBagWarningAt"
        static let soundEnabled = "soundEnabled"
        static let lastVerifiedOS = "lastVerifiedOS"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.batteryFloor: SafetySettings.defaultFloorPercent,
            Key.maxDuration: 8 * 3600,
            Key.noDurationLimit: false,
            Key.thermalGuard: true,
            Key.mode: LidwingMode.manual.rawValue,
            Key.hasEverArmed: false,
            Key.soundEnabled: true
        ])
    }

    var safetySettings: SafetySettings {
        get {
            SafetySettings(batteryFloorPercent: defaults.integer(forKey: Key.batteryFloor),
                           maxDurationSeconds: defaults.bool(forKey: Key.noDurationLimit)
                               ? nil : defaults.integer(forKey: Key.maxDuration),
                           thermalGuardEnabled: defaults.bool(forKey: Key.thermalGuard))
        }
        set {
            defaults.set(newValue.batteryFloorPercent, forKey: Key.batteryFloor)
            defaults.set(newValue.maxDurationSeconds == nil, forKey: Key.noDurationLimit)
            if let seconds = newValue.maxDurationSeconds {
                defaults.set(seconds, forKey: Key.maxDuration)
            }
            defaults.set(newValue.thermalGuardEnabled, forKey: Key.thermalGuard)
        }
    }

    var mode: LidwingMode {
        get { LidwingMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .manual }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// The macOS build on which an arm last verified against ground truth. Deliberately not
    /// registered with a default: absent means "no arm has ever verified here", which is a
    /// first run, and an empty-string default would make a first run look like an OS change.
    var lastVerifiedOS: String? {
        get { defaults.string(forKey: Key.lastVerifiedOS) }
        set { defaults.set(newValue, forKey: Key.lastVerifiedOS) }
    }

    var hasEverArmed: Bool {
        get { defaults.bool(forKey: Key.hasEverArmed) }
        set { defaults.set(newValue, forKey: Key.hasEverArmed) }
    }

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.soundEnabled) }
        set { defaults.set(newValue, forKey: Key.soundEnabled) }
    }
}
