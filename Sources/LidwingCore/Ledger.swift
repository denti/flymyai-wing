import Foundation

/// What we intended, written to disk before we act and read back at every launch.
///
/// The ledger exists so that a crash, a force quit or a kernel panic cannot leave a Mac that
/// will not sleep with nobody knowing why. It records intent only; the machine's own state is
/// always the authority (invariant I9), and the ledger is only ever used to answer one
/// question: *was it us?*
public struct Ledger: Equatable, Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var bootSessionUUID: String
    public var capturedAt: Date
    public var tier: Int
    public var weSetClamshellBit: Bool
    public var weSetSleepDisabled: Bool
    public var reason: String
    public var appVersion: String

    public init(bootSessionUUID: String,
                capturedAt: Date,
                tier: Int = 1,
                weSetClamshellBit: Bool,
                weSetSleepDisabled: Bool = false,
                reason: String,
                appVersion: String) {
        self.schema = Ledger.currentSchema
        self.bootSessionUUID = bootSessionUUID
        self.capturedAt = capturedAt
        self.tier = tier
        self.weSetClamshellBit = weSetClamshellBit
        self.weSetSleepDisabled = weSetSleepDisabled
        self.reason = reason
        self.appVersion = appVersion
    }

    /// Unix seconds, so the file is readable by a human and by `jq`, and does not depend on
    /// Foundation's reference-date encoding.
    private enum CodingKeys: String, CodingKey {
        case schema, bootSessionUUID, capturedAt, tier
        case weSetClamshellBit, weSetSleepDisabled, reason, appVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        bootSessionUUID = try container.decode(String.self, forKey: .bootSessionUUID)
        capturedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .capturedAt))
        tier = try container.decode(Int.self, forKey: .tier)
        weSetClamshellBit = try container.decode(Bool.self, forKey: .weSetClamshellBit)
        weSetSleepDisabled = try container.decodeIfPresent(Bool.self, forKey: .weSetSleepDisabled) ?? false
        reason = try container.decode(String.self, forKey: .reason)
        appVersion = try container.decode(String.self, forKey: .appVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(bootSessionUUID, forKey: .bootSessionUUID)
        try container.encode(capturedAt.timeIntervalSince1970.rounded(), forKey: .capturedAt)
        try container.encode(tier, forKey: .tier)
        try container.encode(weSetClamshellBit, forKey: .weSetClamshellBit)
        try container.encode(weSetSleepDisabled, forKey: .weSetSleepDisabled)
        try container.encode(reason, forKey: .reason)
        try container.encode(appVersion, forKey: .appVersion)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> Ledger? {
        guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return nil }
        guard ledger.schema == Ledger.currentSchema else { return nil }
        return ledger
    }
}

/// The machine's observable power state at launch, as read from the IORegistry.
public struct GroundTruth: Equatable, Sendable {
    /// nil == key absent. Absent is not evidence of modification.
    public let clamshellCausesSleep: Bool?
    public let sleepDisabled: Bool?

    public init(clamshellCausesSleep: Bool?, sleepDisabled: Bool?) {
        self.clamshellCausesSleep = clamshellCausesSleep
        self.sleepDisabled = sleepDisabled
    }

    /// True when nothing on this machine is currently suppressing sleep in a way we recognise.
    public var isStock: Bool {
        if clamshellCausesSleep == false { return false }
        if sleepDisabled == true { return false }
        return true
    }
}

/// The only three things launch reconciliation is allowed to conclude.
public enum ReconcileDecision: Equatable, Sendable {
    /// Nothing is amiss. Delete any stale ledger and start idle.
    case stock(deleteStaleLedger: Bool)
    /// The machine is non-stock and it is plausibly our doing. Offer a one-click Repair.
    /// Never act silently: a silent clear can stomp powerd or another tool.
    case repair(RepairCause)
    /// The machine is non-stock and the ledger says it was not us. Say so, do nothing.
    case standDown
}

public enum RepairCause: String, Equatable, Sendable {
    /// Ground truth is modified and there is no ledger at all.
    case noLedger = "no_ledger"
    /// The ledger is from a previous boot: we crashed or the Mac restarted while armed.
    case staleBootSession = "stale_boot_session"
    /// The ledger says we set it and we are only now starting, so a previous instance died.
    case ourPreviousSession = "our_previous_session"
    /// The ledger file exists but cannot be parsed. We never treat that as permission to
    /// clear state silently.
    case corruptLedger = "corrupt_ledger"
}

public enum LedgerReconciler {
    /// Compare the machine against the ledger.
    ///
    /// - Parameters:
    ///   - rawLedger: the bytes on disk, or nil when the file is absent.
    ///   - truth: what the IORegistry says right now.
    ///   - currentBootSession: `kern.bootsessionuuid`.
    public static func decide(rawLedger: Data?,
                              truth: GroundTruth,
                              currentBootSession: String) -> ReconcileDecision {
        let parsed = rawLedger.flatMap { Ledger.decode($0) }
        let ledgerIsCorrupt = (rawLedger != nil && parsed == nil)

        if truth.isStock {
            // Tier 1 self-heals across a reboot because the clamshell mask is a kernel
            // variable initialised to zero, so a stale ledger here is expected and harmless.
            return .stock(deleteStaleLedger: rawLedger != nil)
        }

        if ledgerIsCorrupt {
            return .repair(.corruptLedger)
        }

        guard let ledger = parsed else {
            return .repair(.noLedger)
        }

        if ledger.bootSessionUUID != currentBootSession {
            return .repair(.staleBootSession)
        }

        if ledger.weSetClamshellBit || ledger.weSetSleepDisabled {
            return .repair(.ourPreviousSession)
        }

        return .standDown
    }
}
