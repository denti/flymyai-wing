import XCTest
@testable import LidwingCore

/// Whether an eight-hour run counts as clean.
///
/// This is the assertion the project's own soak loop runs, and it could not fail on either of
/// the two numbers it names: `isCleanSoak` read `(sleepCountDelta ?? 0) == 0`, and both counters
/// were passed as `nil` at every call site. An unmeasured counter read as a zero, so every
/// record without recorded failures was "clean" regardless of what the machine actually did.
final class AuditCleanlinessTests: XCTestCase {

    private func record(sleeps: Int?, darkWakes: Int?, failures: [AuditFailure] = [],
                        groundTruthFailures: Int = 0) -> AuditRecord {
        AuditRecord(armedAt: Date(timeIntervalSince1970: 1_000),
                    disarmedAt: Date(timeIntervalSince1970: 30_000),
                    reason: .user, tier: 1, minBatteryPercent: 55, maxThermal: "nominal",
                    reasserts: 12, sleepCountDelta: sleeps, darkWakeCountDelta: darkWakes,
                    groundTruthFailures: groundTruthFailures, failures: failures,
                    os: "15.5", arch: "arm64", appVersion: "1.0.0")
    }

    /// The defect. A run nobody measured is not a run that went well.
    func testAnUnmeasuredRunIsNotClean() {
        XCTAssertEqual(record(sleeps: nil, darkWakes: nil).cleanliness, .unmeasured)
        XCTAssertFalse(record(sleeps: nil, darkWakes: nil).isCleanSoak,
                       "a run with neither counter measured reported itself as clean")
    }

    /// Half-measured is still unmeasured. Dark wake is the counter this app cannot read yet, and
    /// rounding that gap to zero is exactly the mistake being fixed.
    func testHalfAMeasurementIsStillNotAPass() {
        XCTAssertEqual(record(sleeps: 0, darkWakes: nil).cleanliness, .unmeasured)
        XCTAssertEqual(record(sleeps: nil, darkWakes: 0).cleanliness, .unmeasured)
    }

    func testAFullyMeasuredQuietRunIsClean() {
        XCTAssertEqual(record(sleeps: 0, darkWakes: 0).cleanliness, .clean)
        XCTAssertTrue(record(sleeps: 0, darkWakes: 0).isCleanSoak)
    }

    /// A single sleep while armed is the failure this whole product exists to prevent.
    func testOneSleepIsDirty() {
        XCTAssertEqual(record(sleeps: 1, darkWakes: 0).cleanliness, .dirty)
        XCTAssertFalse(record(sleeps: 1, darkWakes: 0).isCleanSoak)
    }

    func testOneDarkWakeIsDirty() {
        XCTAssertEqual(record(sleeps: 0, darkWakes: 1).cleanliness, .dirty)
    }

    /// A recorded failure outranks the counters: it is dirty even if the numbers were never
    /// taken, because something is already known to have gone wrong.
    func testARecordedFailureIsDirtyEvenWithoutCounters() {
        XCTAssertEqual(record(sleeps: nil, darkWakes: nil,
                              failures: [.sleptWhileArmed]).cleanliness, .dirty)
        XCTAssertEqual(record(sleeps: nil, darkWakes: nil,
                              groundTruthFailures: 2).cleanliness, .dirty)
    }

    /// The three states are distinct on purpose: "we do not know" is a real answer and must not
    /// collapse into either of the other two.
    func testTheThreeVerdictsAreAllReachable() {
        XCTAssertEqual(Set([record(sleeps: 0, darkWakes: 0).cleanliness,
                            record(sleeps: 1, darkWakes: 0).cleanliness,
                            record(sleeps: nil, darkWakes: nil).cleanliness]).count, 3)
    }
}

/// The counter that a finished session actually writes.
final class SessionSleepCountTests: XCTestCase {

    func testAFinishedSessionRecordsTheSleepsItObserved() throws {
        let (system, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        // The machine slept while we were holding it. Invariant I5: never benign.
        machine.handle(.systemWillSleep(argument: 0))
        system.advance(1)
        machine.handle(.userDisarm)
        machine.handle(.verifyTick)

        let record = try XCTUnwrap(audit.records.last)
        XCTAssertEqual(record.sleepCountDelta, 1,
                       "the session recorded no sleeps despite observing one")
        XCTAssertEqual(record.cleanliness, .dirty)
    }

    /// A quiet session records a measured zero rather than a nil, so it can be judged at all.
    func testAQuietSessionRecordsAMeasuredZero() throws {
        let (_, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        machine.handle(.userDisarm)
        machine.handle(.verifyTick)

        let record = try XCTUnwrap(audit.records.last)
        XCTAssertEqual(record.sleepCountDelta, 0,
                       "a clean session left its sleep count unmeasured")
    }
}
