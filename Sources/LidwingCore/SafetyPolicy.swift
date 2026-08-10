import Foundation

/// Why an armed session ended. Persisted into the audit record and shown to the user on the
/// next interaction, so it is never allowed to be "unknown".
public enum DisarmReason: String, Equatable, Sendable, CaseIterable, Codable {
    case user
    case quit
    case agentExited = "agent_exited"
    case batteryFloor = "battery_floor"
    case thermal
    case timer
    case watchdogLost = "watchdog_lost"
    case unsupportedState = "unsupported_state"
    /// The session ended because protection was lost, not because anyone asked.
    case failure

    /// Copy for the notification the user sees when the machine stood down on its own.
    public var userFacingSentence: String? {
        switch self {
        case .batteryFloor: return "Stopped at the battery limit. Your Mac is sleeping normally now."
        case .thermal: return "Your Mac got too hot. Lidwing stopped so it can cool down."
        case .timer: return "The time limit elapsed. Lidwing stopped."
        case .agentExited: return "Your coding agent finished. Lidwing stopped."
        case .watchdogLost: return "Lidwing lost its safety watchdog and stood down."
        case .unsupportedState: return "Lidwing stood down because this Mac's state changed."
        case .failure: return "Lidwing stopped protecting this Mac. Open Lidwing for details."
        case .user, .quit: return nil
        }
    }
}

/// User-visible safety settings. Every default here is the conservative one.
public struct SafetySettings: Equatable, Sendable {
    public static let minimumFloorPercent = 10
    public static let maximumFloorPercent = 50
    public static let defaultFloorPercent = 20

    /// Stop and let the Mac sleep at or below this battery percentage, on battery only.
    public let batteryFloorPercent: Int
    /// Stop after this many seconds regardless. nil is "no limit" and is behind a two-step
    /// confirmation in the UI.
    public let maxDurationSeconds: Int?
    /// Stop when the machine reports a critical thermal state.
    public let thermalGuardEnabled: Bool

    public init(batteryFloorPercent: Int = SafetySettings.defaultFloorPercent,
                maxDurationSeconds: Int? = 8 * 3600,
                thermalGuardEnabled: Bool = true) {
        // Clamped, not rejected: a corrupted preferences file must not be able to remove the
        // floor entirely, and it must not be able to make the app refuse to launch either.
        self.batteryFloorPercent = min(max(batteryFloorPercent, SafetySettings.minimumFloorPercent),
                                       SafetySettings.maximumFloorPercent)
        if let seconds = maxDurationSeconds {
            self.maxDurationSeconds = max(60, seconds)
        } else {
            self.maxDurationSeconds = nil
        }
        self.thermalGuardEnabled = thermalGuardEnabled
    }
}

/// What the guards want to happen right now.
public enum SafetyVerdict: Equatable, Sendable {
    case ok
    /// Still protecting, but something is wrong enough that the user should be told.
    case degrade(SafetyWarning)
    case disarm(DisarmReason)
}

public enum SafetyWarning: String, Equatable, Sendable {
    case thermalSerious = "thermal_serious"
    case batteryNearFloor = "battery_near_floor"
    case foreignHolder = "foreign_holder"
}

/// One reading of the power source.
public struct PowerSample: Equatable, Sendable {
    public let onAC: Bool
    public let current: Int?
    public let max: Int?
    public let warning: BatteryWarning

    public init(onAC: Bool, current: Int?, max: Int?, warning: BatteryWarning) {
        self.onAC = onAC
        self.current = current
        self.max = max
        self.warning = warning
    }

    /// Battery charge as a percentage, computed from the two raw capacity values.
    ///
    /// `kIOPSCurrentCapacityKey` is **not** a percentage on every machine — raw-mAh
    /// conventions exist in the wild. Comparing a raw 3119 against a 20 % floor never trips,
    /// so a guard written that way silently never fires, which is the worst possible failure
    /// for a safety net. nil means "we do not know", which is never treated as "low".
    public var percentage: Int? {
        guard let current, let max, max > 0, current >= 0 else { return nil }
        let pct = Int((Double(current) * 100.0 / Double(max)).rounded())
        return min(pct, 100)
    }
}

/// Two-sample debouncer.
///
/// At the instant of an AC flip the power-source dictionary is momentarily inconsistent — a
/// single sample there reports nonsense and would kill an eight-hour run on a charger reseat.
/// A condition has to hold across two samples at least `interval` apart before it counts.
public struct SustainedCondition: Equatable, Sendable {
    public let interval: TimeInterval
    private var since: Date?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Feed one observation. Returns true once the condition has held for `interval`.
    public mutating func update(_ holds: Bool, at now: Date) -> Bool {
        guard holds else {
            since = nil
            return false
        }
        guard let start = since else {
            since = now
            return false
        }
        return now.timeIntervalSince(start) >= interval
    }

    /// Discard any accumulated agreement, e.g. after an unusable sample.
    public mutating func reset() {
        since = nil
    }

    public var isAccumulating: Bool { since != nil }
}

/// The battery, thermal and duration guards. Pure: it is fed samples and returns a verdict.
public struct SafetyPolicy: Sendable {
    public static let debounceInterval: TimeInterval = 2.0
    /// Distance above the floor at which we start warning the user rather than acting.
    public static let earlyWarningMargin = 5
    /// A critical thermal reading has to persist before we tear down a user's work: a single
    /// spike while a build links is not a reason to end an overnight run.
    public static let thermalCriticalDwell: TimeInterval = 60.0

    public let settings: SafetySettings

    private var lowBattery = SustainedCondition(interval: SafetyPolicy.debounceInterval)
    private var criticalThermal = SustainedCondition(interval: SafetyPolicy.thermalCriticalDwell)

    public init(settings: SafetySettings) {
        self.settings = settings
    }

    /// Evaluate every guard against one observation.
    ///
    /// - Parameters:
    ///   - armedSince: when the current session started, for the duration lease.
    /// - Returns: the most severe verdict. Disarm always beats degrade.
    public mutating func evaluate(power: PowerSample,
                                  thermal: ThermalState,
                                  armedSince: Date,
                                  now: Date) -> SafetyVerdict {
        // 1. Thermal ceiling. `.critical` must persist; `.serious` is advisory.
        if settings.thermalGuardEnabled {
            let criticalNow = (thermal == .critical)
            if criticalThermal.update(criticalNow, at: now) {
                return .disarm(.thermal)
            }
        } else {
            criticalThermal.reset()
        }

        // 2. Duration lease.
        if let limit = settings.maxDurationSeconds,
           now.timeIntervalSince(armedSince) >= Double(limit) {
            return .disarm(.timer)
        }

        // 3. Battery floor. Never on AC: there is nothing to run out of, and disarming a
        //    plugged-in Mac because the battery reads low while it charges is a bug, not a
        //    safety feature.
        if power.onAC {
            lowBattery.reset()
        } else {
            // The OS's own final warning is authoritative and bypasses the percentage
            // entirely: it fires on machines whose capacity keys we cannot interpret.
            if power.warning == .final {
                return .disarm(.batteryFloor)
            }
            if let pct = power.percentage {
                if lowBattery.update(pct <= settings.batteryFloorPercent, at: now) {
                    return .disarm(.batteryFloor)
                }
                if pct <= settings.batteryFloorPercent + SafetyPolicy.earlyWarningMargin {
                    return .degrade(.batteryNearFloor)
                }
            } else {
                // An unusable sample breaks the agreement chain rather than counting as low.
                lowBattery.reset()
            }
        }

        if settings.thermalGuardEnabled && thermal >= .serious {
            return .degrade(.thermalSerious)
        }

        return .ok
    }

    /// Whether arming should be refused outright, and why, before anything is written.
    public static func refusalReason(power: PowerSample,
                                     thermal: ThermalState,
                                     settings: SafetySettings,
                                     lid: LidState,
                                     foreignHolders: [ForeignHolder]) -> ArmRefusal? {
        if lid == .noLid { return .noLid }
        if !power.onAC {
            if power.warning == .final { return .batteryTooLow }
            if let pct = power.percentage, pct <= settings.batteryFloorPercent {
                return .batteryTooLow
            }
        }
        if settings.thermalGuardEnabled && thermal == .critical { return .tooHot }
        if let holder = foreignHolders.first { return .foreignHolder(holder) }
        return nil
    }
}

/// Why we will not arm. Each maps to one specific sentence in the UI — never a generic error.
public enum ArmRefusal: Equatable, Sendable {
    case noLid
    case unsupportedOS
    case batteryTooLow
    case tooHot
    case foreignHolder(ForeignHolder)
    case externalDisplayOnAC
    case watchdogUnavailable
    case notInApplications

    public var sentence: String {
        switch self {
        case .noLid:
            return "This Mac has no lid, so there is no lid-close sleep to prevent."
        case .unsupportedOS:
            return "This version of macOS changed how sleep works. Lidwing needs an update."
        case .batteryTooLow:
            return "The battery is already at or below your stop limit. Plug in and try again."
        case .tooHot:
            return "This Mac is too hot right now. Let it cool down and try again."
        case .foreignHolder(let holder):
            return "Another app is already keeping this Mac awake: \(holder.name) (pid \(holder.pid))."
        case .externalDisplayOnAC:
            return "macOS already does this for you while an external display is attached on power."
        case .watchdogUnavailable:
            return "Lidwing could not start its safety watchdog, so it will not keep this Mac awake."
        case .notInApplications:
            return "Move Lidwing to your Applications folder first."
        }
    }
}
