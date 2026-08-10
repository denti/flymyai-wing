import XCTest
@testable import LidwingCore

final class LedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_500_000)

    private func ledger(boot: String = "BOOT-A", ours: Bool = true) -> Ledger {
        Ledger(bootSessionUUID: boot, capturedAt: now, weSetClamshellBit: ours,
               reason: "user", appVersion: "1.0.0")
    }

    func testRoundTrip() throws {
        let original = ledger()
        let decoded = try XCTUnwrap(Ledger.decode(original.encoded()))
        XCTAssertEqual(decoded, original)
    }

    func testEncodingUsesUnixSecondsSoTheFileIsReadable() throws {
        let text = String(data: try ledger().encoded(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"capturedAt\":1786500000"), "got: \(text)")
    }

    func testAFutureSchemaIsRejectedRatherThanMisread() throws {
        var data = try ledger().encoded()
        let text = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\"schema\":1",
                                                                            with: "\"schema\":99")
        data = Data(text.utf8)
        XCTAssertNil(Ledger.decode(data))
    }

    // MARK: reconciliation

    func testStockMachineIsIdleAndStaleLedgersAreDropped() throws {
        let truth = GroundTruth(clamshellCausesSleep: true, sleepDisabled: false)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: nil, truth: truth, currentBootSession: "BOOT-A"),
                       .stock(deleteStaleLedger: false))
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: try ledger().encoded(), truth: truth,
                                               currentBootSession: "BOOT-A"),
                       .stock(deleteStaleLedger: true))
    }

    func testAnAbsentKeyIsNotEvidenceOfModification() {
        // On a laptop `AppleClamshellCausesSleep` is absent until the lid driver's first
        // report. Reading that as "somebody disabled sleep" would show a repair prompt at
        // every login.
        let truth = GroundTruth(clamshellCausesSleep: nil, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: nil, truth: truth, currentBootSession: "BOOT-A"),
                       .stock(deleteStaleLedger: false))
    }

    func testModifiedWithNoLedgerAsksForRepair() {
        let truth = GroundTruth(clamshellCausesSleep: false, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: nil, truth: truth, currentBootSession: "BOOT-A"),
                       .repair(.noLedger))
    }

    func testALedgerFromAPreviousBootAsksForRepair() throws {
        let truth = GroundTruth(clamshellCausesSleep: false, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: try ledger(boot: "BOOT-OLD").encoded(),
                                               truth: truth, currentBootSession: "BOOT-A"),
                       .repair(.staleBootSession))
    }

    func testOurOwnLedgerFromThisBootAsksForRepair() throws {
        let truth = GroundTruth(clamshellCausesSleep: false, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: try ledger(boot: "BOOT-A").encoded(),
                                               truth: truth, currentBootSession: "BOOT-A"),
                       .repair(.ourPreviousSession))
    }

    func testALedgerSayingItWasNotUsStandsDown() throws {
        let truth = GroundTruth(clamshellCausesSleep: false, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: try ledger(boot: "BOOT-A", ours: false).encoded(),
                                               truth: truth, currentBootSession: "BOOT-A"),
                       .standDown)
    }

    /// A corrupt ledger is the one case where a naive implementation "cleans up" and clears a
    /// setting it has no evidence it owns.
    func testACorruptLedgerAsksForRepairAndNeverClearsSilently() {
        let truth = GroundTruth(clamshellCausesSleep: false, sleepDisabled: nil)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: Data("{not json".utf8), truth: truth,
                                               currentBootSession: "BOOT-A"),
                       .repair(.corruptLedger))
    }

    func testSleepDisabledAloneCountsAsModified() {
        let truth = GroundTruth(clamshellCausesSleep: true, sleepDisabled: true)
        XCTAssertFalse(truth.isStock)
        XCTAssertEqual(LedgerReconciler.decide(rawLedger: nil, truth: truth, currentBootSession: "B"),
                       .repair(.noLedger))
    }

    // MARK: the audit record

    func testAuditRecordJSONLShape() throws {
        var session = AuditSession(armedAt: now)
        session.observe(batteryPercent: 61)
        session.observe(batteryPercent: 44)
        session.observe(thermal: .fair)
        session.observe(thermal: .nominal)
        session.countReassert()
        session.countReassert()

        let record = session.finish(at: now.addingTimeInterval(28_800), reason: .timer, tier: 1,
                                    sleepCountDelta: 0, darkWakeCountDelta: 0,
                                    os: "15.5", arch: "arm64", appVersion: "1.0.0")

        XCTAssertEqual(record.minBatteryPercent, 44)
        XCTAssertEqual(record.maxThermal, "fair")
        XCTAssertEqual(record.reasserts, 2)
        XCTAssertTrue(record.isCleanSoak)

        let line = try record.jsonLine()
        let text = String(data: line, encoding: .utf8)!
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"reason\":\"timer\""))
        XCTAssertTrue(text.contains("\"min_battery_pct\":44"))
        let decoded = try JSONDecoder().decode(AuditRecord.self, from: line)
        XCTAssertEqual(decoded.reason, .timer)
        XCTAssertEqual(decoded.armedAt.timeIntervalSince1970, now.timeIntervalSince1970)
    }

    func testASoakWithASleepIsNotClean() {
        var session = AuditSession(armedAt: now)
        session.record(.sleptWhileArmed)
        let record = session.finish(at: now.addingTimeInterval(60), reason: .user, tier: 1,
                                    sleepCountDelta: 1, darkWakeCountDelta: 0,
                                    os: "15.5", arch: "arm64", appVersion: "1.0.0")
        XCTAssertFalse(record.isCleanSoak)
        XCTAssertEqual(record.groundTruthFailures, 1)
    }
}
