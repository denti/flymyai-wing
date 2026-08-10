import Foundation

/// Things that went wrong while we were supposed to be protecting the machine. Every one of
/// these is written to `audit.jsonl` and surfaced to the user; none of them is ever swallowed.
public enum AuditFailure: String, Equatable, Codable, Sendable {
    /// The write returned success and the machine's state did not change.
    case applyNoEffect = "APPLY_NO_EFFECT"
    /// The release returned success and the machine's state did not change back.
    case releaseNoEffect = "RELEASE_NO_EFFECT"
    /// The machine slept while we were armed. There is no benign case (invariant I5).
    case sleptWhileArmed = "SLEPT_WHILE_ARMED"
    /// Ground truth stopped agreeing with us mid-session.
    case groundTruthLost = "GROUND_TRUTH_LOST"
    /// The watchdog cleared a bit we left behind.
    case watchdogRecovered = "WATCHDOG_RECOVERED"
    /// We could not keep a dead-man watchdog alive, so we stood down.
    case watchdogUnavailable = "WATCHDOG_UNAVAILABLE"
    /// The durable intent record could not be written. Not fatal — the watchdog covers process
    /// death and the clamshell mask clears on reboot — but it degrades our ability to explain
    /// ourselves at the next launch, so it is never silent.
    case ledgerWriteFailed = "LEDGER_WRITE_FAILED"
}

/// One line of `audit.jsonl`, describing a completed armed session.
public struct AuditRecord: Equatable, Codable, Sendable {
    public var armedAt: Date
    public var disarmedAt: Date
    public var reason: DisarmReason
    public var tier: Int
    public var minBatteryPercent: Int?
    public var maxThermal: String
    public var reasserts: Int
    public var sleepCountDelta: Int?
    public var darkWakeCountDelta: Int?
    public var groundTruthFailures: Int
    public var failures: [AuditFailure]
    public var os: String
    public var arch: String
    public var appVersion: String

    private enum CodingKeys: String, CodingKey {
        case armedAt = "armed_at"
        case disarmedAt = "disarmed_at"
        case reason
        case tier
        case minBatteryPercent = "min_battery_pct"
        case maxThermal = "max_thermal"
        case reasserts
        case sleepCountDelta = "sleep_count_delta"
        case darkWakeCountDelta = "dark_wake_count_delta"
        case groundTruthFailures = "ground_truth_failures"
        case failures
        case os
        case arch
        case appVersion = "app_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        armedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .armedAt))
        disarmedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .disarmedAt))
        reason = try c.decode(DisarmReason.self, forKey: .reason)
        tier = try c.decode(Int.self, forKey: .tier)
        minBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .minBatteryPercent)
        maxThermal = try c.decode(String.self, forKey: .maxThermal)
        reasserts = try c.decode(Int.self, forKey: .reasserts)
        sleepCountDelta = try c.decodeIfPresent(Int.self, forKey: .sleepCountDelta)
        darkWakeCountDelta = try c.decodeIfPresent(Int.self, forKey: .darkWakeCountDelta)
        groundTruthFailures = try c.decode(Int.self, forKey: .groundTruthFailures)
        failures = try c.decodeIfPresent([AuditFailure].self, forKey: .failures) ?? []
        os = try c.decode(String.self, forKey: .os)
        arch = try c.decode(String.self, forKey: .arch)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "0.0.0"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(armedAt.timeIntervalSince1970.rounded(), forKey: .armedAt)
        try c.encode(disarmedAt.timeIntervalSince1970.rounded(), forKey: .disarmedAt)
        try c.encode(reason, forKey: .reason)
        try c.encode(tier, forKey: .tier)
        try c.encodeIfPresent(minBatteryPercent, forKey: .minBatteryPercent)
        try c.encode(maxThermal, forKey: .maxThermal)
        try c.encode(reasserts, forKey: .reasserts)
        try c.encodeIfPresent(sleepCountDelta, forKey: .sleepCountDelta)
        try c.encodeIfPresent(darkWakeCountDelta, forKey: .darkWakeCountDelta)
        try c.encode(groundTruthFailures, forKey: .groundTruthFailures)
        try c.encode(failures, forKey: .failures)
        try c.encode(os, forKey: .os)
        try c.encode(arch, forKey: .arch)
        try c.encode(appVersion, forKey: .appVersion)
    }

    public init(armedAt: Date, disarmedAt: Date, reason: DisarmReason, tier: Int,
                minBatteryPercent: Int?, maxThermal: String, reasserts: Int,
                sleepCountDelta: Int?, darkWakeCountDelta: Int?, groundTruthFailures: Int,
                failures: [AuditFailure], os: String, arch: String, appVersion: String) {
        self.armedAt = armedAt
        self.disarmedAt = disarmedAt
        self.reason = reason
        self.tier = tier
        self.minBatteryPercent = minBatteryPercent
        self.maxThermal = maxThermal
        self.reasserts = reasserts
        self.sleepCountDelta = sleepCountDelta
        self.darkWakeCountDelta = darkWakeCountDelta
        self.groundTruthFailures = groundTruthFailures
        self.failures = failures
        self.os = os
        self.arch = arch
        self.appVersion = appVersion
    }

    /// One JSONL line, newline included.
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// The assertion the project's own soak loop runs after every long run. A record that
    /// fails this is a product failure, not a warning.
    public var isCleanSoak: Bool {
        (sleepCountDelta ?? 0) == 0
            && (darkWakeCountDelta ?? 0) == 0
            && groundTruthFailures == 0
            && failures.isEmpty
    }
}

/// Accumulates the facts an `AuditRecord` needs over the life of one armed session.
public struct AuditSession: Equatable, Sendable {
    public let armedAt: Date
    public private(set) var minBatteryPercent: Int?
    public private(set) var maxThermal: ThermalState
    public private(set) var reasserts: Int
    public private(set) var groundTruthFailures: Int
    public private(set) var failures: [AuditFailure]

    public init(armedAt: Date) {
        self.armedAt = armedAt
        self.minBatteryPercent = nil
        self.maxThermal = .nominal
        self.reasserts = 0
        self.groundTruthFailures = 0
        self.failures = []
    }

    public mutating func observe(batteryPercent: Int?) {
        guard let pct = batteryPercent else { return }
        minBatteryPercent = min(minBatteryPercent ?? pct, pct)
    }

    public mutating func observe(thermal: ThermalState) {
        if thermal > maxThermal { maxThermal = thermal }
    }

    public mutating func countReassert() {
        reasserts += 1
    }

    public mutating func record(_ failure: AuditFailure) {
        failures.append(failure)
        if failure == .groundTruthLost || failure == .sleptWhileArmed {
            groundTruthFailures += 1
        }
    }

    /// Number of `SLEPT_WHILE_ARMED` records so far. Two in one session is the escalation
    /// trigger to offer the stronger method.
    public var sleepFailureCount: Int {
        failures.filter { $0 == .sleptWhileArmed }.count
    }

    public func finish(at end: Date, reason: DisarmReason, tier: Int,
                       sleepCountDelta: Int?, darkWakeCountDelta: Int?,
                       os: String, arch: String, appVersion: String) -> AuditRecord {
        AuditRecord(armedAt: armedAt,
                    disarmedAt: end,
                    reason: reason,
                    tier: tier,
                    minBatteryPercent: minBatteryPercent,
                    maxThermal: String(describing: maxThermal),
                    reasserts: reasserts,
                    sleepCountDelta: sleepCountDelta,
                    darkWakeCountDelta: darkWakeCountDelta,
                    groundTruthFailures: groundTruthFailures,
                    failures: failures,
                    os: os,
                    arch: arch,
                    appVersion: appVersion)
    }
}
