import Foundation
@testable import LidwingCore

/// A `SystemFacade` over plain stored properties.
///
/// Two behaviours matter for the tests to mean anything:
///  * writes are recorded, so a test can assert that we did or did not touch the machine;
///  * `clamshellCausesSleep` does **not** follow the write automatically unless
///    `mechanismWorks` is true. That is the whole point: on the real machine both mechanisms
///    return success while doing nothing, and the product's acceptance signal is the observed
///    state, never the return code.
final class MockSystem: SystemFacade {
    var lidState: LidState = .open
    var clamshellCausesSleep: Bool? = true
    var sleepDisabled: Bool?
    var desktopMode = false
    var onAC = false
    var batteryCurrent: Int? = 4000
    var batteryMax: Int? = 5000
    var batteryWarningLevel: BatteryWarning = .none
    var thermalState: ThermalState = .nominal
    var onlineDisplayCount = 1
    var foreignAssertionHolders: [ForeignHolder] = []
    var ourAssertionLive = false
    var runningAgentBinaries: Set<String> = []
    var bootSessionUUID = "BOOT-0000"
    var now = Date(timeIntervalSince1970: 1_786_500_000)

    /// When true, a successful write is reflected in the observable state, like a working Mac.
    var mechanismWorks = true
    /// Injected failure for the clamshell write.
    var clamshellWriteResult: Result<Void, MechanismError> = .success(())
    /// Injected failure for the assertion write.
    var assertionWriteResult: Result<Void, MechanismError> = .success(())

    /// Modelled because the real `ClamshellLock` refuses to clear a bit it did not set. A mock
    /// that writes unconditionally is more permissive than the machine, and it hid a bug where
    /// the Repair button reported success and did nothing.
    private(set) var lockOwnsTheBit = false
    private(set) var repairCalls = 0
    private(set) var clamshellWrites: [Bool] = []
    private(set) var assertionWrites: [Bool] = []
    private(set) var sleepRequests = 0

    func setClamshellSleepDisabled(_ on: Bool) -> Result<Void, MechanismError> {
        if !on && !lockOwnsTheBit {
            // Invariant I7 in the live implementation: never clear a bit we did not set. The
            // call is a no-op rather than an error, exactly as `ClamshellLock.safeRelease` is.
            clamshellWrites.append(on)
            return .success(())
        }
        clamshellWrites.append(on)
        if case .failure = clamshellWriteResult { return clamshellWriteResult }
        if mechanismWorks {
            clamshellCausesSleep = !on
            lockOwnsTheBit = on
        }
        return .success(())
    }

    func repairClamshellState() -> Result<Void, MechanismError> {
        repairCalls += 1
        clamshellWrites.append(false)
        if case .failure = clamshellWriteResult { return clamshellWriteResult }
        if mechanismWorks {
            clamshellCausesSleep = true
            lockOwnsTheBit = false
        }
        return .success(())
    }

    /// Puts the mock in the state a *previous* process left behind: the bit is set and this
    /// process does not own it.
    func simulateBitSetByAnotherProcess() {
        clamshellCausesSleep = false
        lockOwnsTheBit = false
    }

    func setIdleAssertion(_ on: Bool) -> Result<Void, MechanismError> {
        assertionWrites.append(on)
        if case .failure = assertionWriteResult { return assertionWriteResult }
        if mechanismWorks { ourAssertionLive = on }
        return .success(())
    }

    func requestSystemSleep() {
        sleepRequests += 1
    }

    // MARK: helpers for tests

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    var lastClamshellWrite: Bool? { clamshellWrites.last }
}

final class MockLedgerStore: LedgerStore {
    var stored: Data?
    var writeError: Error?
    private(set) var writes = 0
    private(set) var deletes = 0

    init(stored: Data? = nil) {
        self.stored = stored
    }

    func read() -> Data? { stored }

    func write(_ ledger: Ledger) throws {
        if let writeError { throw writeError }
        stored = try ledger.encoded()
        writes += 1
    }

    func delete() {
        stored = nil
        deletes += 1
    }

    var currentLedger: Ledger? { stored.flatMap { Ledger.decode($0) } }
}

struct RecordedFailure: Equatable {
    let failure: AuditFailure
    let context: [String: String]
}

final class MockAudit: AuditSink {
    private(set) var records: [AuditRecord] = []
    private(set) var failures: [RecordedFailure] = []

    func append(_ record: AuditRecord) {
        records.append(record)
    }

    func note(_ failure: AuditFailure, at date: Date, context: [String: String]) {
        failures.append(RecordedFailure(failure: failure, context: context))
    }

    func contains(_ failure: AuditFailure) -> Bool {
        failures.contains { $0.failure == failure }
    }
}

final class MockWatchdog: WatchdogLink {
    var canConnect = true
    private(set) var isConnected = false
    private(set) var sent: [ControlMessage] = []
    private(set) var connectAttempts = 0

    func connect() -> Bool {
        connectAttempts += 1
        guard canConnect else { return false }
        isConnected = true
        return true
    }

    func send(_ message: ControlMessage) {
        sent.append(message)
    }

    func disconnect() {
        isConnected = false
    }
}

enum TestFixture {
    static let identity = RuntimeIdentity(osVersion: "15.5", arch: "arm64", appVersion: "1.0.0")

    /// A machine that is a laptop, on battery, healthy, with nothing else holding assertions.
    static func healthyMachine() -> MockSystem {
        let system = MockSystem()
        system.lidState = .open
        system.clamshellCausesSleep = true
        system.onAC = false
        system.batteryCurrent = 4000
        system.batteryMax = 5000
        system.thermalState = .nominal
        return system
    }

    /// Builds a machine plus a state machine wired to fresh mocks.
    static func harness(settings: SafetySettings = SafetySettings(),
                        identity: RuntimeIdentity = TestFixture.identity)
        -> (MockSystem, MockLedgerStore, MockAudit, MockWatchdog, StateMachine) {
        let system = healthyMachine()
        let ledger = MockLedgerStore()
        let audit = MockAudit()
        let watchdog = MockWatchdog()
        let machine = StateMachine(facade: system,
                                   ledgerStore: ledger,
                                   audit: audit,
                                   watchdog: watchdog,
                                   identity: identity,
                                   settings: settings,
                                   pid: 4412)
        return (system, ledger, audit, watchdog, machine)
    }
}
