import XCTest
@testable import LidwingCore

final class SafetyPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_786_500_000)

    // MARK: percentage arithmetic

    /// The bug this test exists to prevent: treating `kIOPSCurrentCapacityKey` as a
    /// percentage. On a machine using raw mAh, comparing 3119 against a 20 % floor never
    /// trips, so the guard silently never fires and the laptop runs itself flat.
    func testPercentageIsComputedFromBothCapacities() {
        let sample = PowerSample(onAC: false, current: 3119, max: 4563, warning: .none)
        XCTAssertEqual(sample.percentage, 68)
        XCTAssertNotEqual(sample.percentage, 3119)
    }

    func testPercentageIsNilRatherThanWrongForUnusableSamples() {
        XCTAssertNil(PowerSample(onAC: false, current: nil, max: 4563, warning: .none).percentage)
        XCTAssertNil(PowerSample(onAC: false, current: 3119, max: nil, warning: .none).percentage)
        XCTAssertNil(PowerSample(onAC: false, current: 3119, max: 0, warning: .none).percentage)
        XCTAssertNil(PowerSample(onAC: false, current: -1, max: 4563, warning: .none).percentage)
    }

    func testPercentageIsClampedForAnOverfullBattery() {
        XCTAssertEqual(PowerSample(onAC: false, current: 5100, max: 5000, warning: .none).percentage, 100)
    }

    // MARK: the floor

    func testFloorNeedsTwoAgreeingSamplesTwoSecondsApart() {
        var policy = SafetyPolicy(settings: SafetySettings(batteryFloorPercent: 20))
        let low = PowerSample(onAC: false, current: 900, max: 5000, warning: .none)

        XCTAssertEqual(policy.evaluate(power: low, thermal: .nominal, armedSince: t0, now: t0),
                       .degrade(.batteryNearFloor))
        XCTAssertEqual(policy.evaluate(power: low, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(1.0)),
                       .degrade(.batteryNearFloor))
        XCTAssertEqual(policy.evaluate(power: low, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(2.1)),
                       .disarm(.batteryFloor))
    }

    /// At the instant of an AC flip the power-source dictionary is momentarily inconsistent.
    /// A single sample there must not end an eight-hour run.
    func testASingleTransientSampleDoesNotTripTheFloor() {
        var policy = SafetyPolicy(settings: SafetySettings(batteryFloorPercent: 20))
        let good = PowerSample(onAC: false, current: 4000, max: 5000, warning: .none)
        let transient = PowerSample(onAC: false, current: -1, max: 5000, warning: .none)

        XCTAssertEqual(policy.evaluate(power: good, thermal: .nominal, armedSince: t0, now: t0), .ok)
        XCTAssertEqual(policy.evaluate(power: transient, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(2.1)), .ok)
        XCTAssertEqual(policy.evaluate(power: good, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(4.2)), .ok)
    }

    func testTheOSFinalWarningTripsImmediatelyRegardlessOfPercentage() {
        var policy = SafetyPolicy(settings: SafetySettings(batteryFloorPercent: 20))
        // Percentage says 80 %, but the OS says the battery is about to die. The OS wins:
        // it fires on machines whose capacity keys we cannot interpret at all.
        let sample = PowerSample(onAC: false, current: 4000, max: 5000, warning: .final)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .nominal, armedSince: t0, now: t0),
                       .disarm(.batteryFloor))
    }

    func testTheFloorNeverTripsOnAC() {
        var policy = SafetyPolicy(settings: SafetySettings(batteryFloorPercent: 20))
        let low = PowerSample(onAC: true, current: 100, max: 5000, warning: .final)
        for step in 0..<5 {
            XCTAssertEqual(policy.evaluate(power: low, thermal: .nominal, armedSince: t0,
                                           now: t0.addingTimeInterval(Double(step) * 3)), .ok)
        }
    }

    func testFloorIsClampedIntoTheSafeRange() {
        XCTAssertEqual(SafetySettings(batteryFloorPercent: 0).batteryFloorPercent, 10)
        XCTAssertEqual(SafetySettings(batteryFloorPercent: 99).batteryFloorPercent, 50)
        XCTAssertEqual(SafetySettings(batteryFloorPercent: 30).batteryFloorPercent, 30)
    }

    // MARK: thermal

    func testThermalCriticalDisarmsOnlyAfterItPersists() {
        var policy = SafetyPolicy(settings: SafetySettings())
        let sample = PowerSample(onAC: true, current: 4000, max: 5000, warning: .none)

        // While the dwell runs we are still protecting, but the user is told the Mac is hot.
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .critical, armedSince: t0, now: t0),
                       .degrade(.thermalSerious))
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .critical, armedSince: t0,
                                       now: t0.addingTimeInterval(30)), .degrade(.thermalSerious))
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .critical, armedSince: t0,
                                       now: t0.addingTimeInterval(61)), .disarm(.thermal))
    }

    func testThermalSeriousOnlyDegrades() {
        var policy = SafetyPolicy(settings: SafetySettings())
        let sample = PowerSample(onAC: true, current: 4000, max: 5000, warning: .none)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .serious, armedSince: t0, now: t0),
                       .degrade(.thermalSerious))
    }

    func testThermalGuardCanBeTurnedOff() {
        var policy = SafetyPolicy(settings: SafetySettings(thermalGuardEnabled: false))
        let sample = PowerSample(onAC: true, current: 4000, max: 5000, warning: .none)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .critical, armedSince: t0,
                                       now: t0.addingTimeInterval(600)), .ok)
    }

    // MARK: the lease

    func testTheDurationLeaseDisarms() {
        var policy = SafetyPolicy(settings: SafetySettings(maxDurationSeconds: 8 * 3600))
        let sample = PowerSample(onAC: true, current: 4000, max: 5000, warning: .none)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(8 * 3600 - 1)), .ok)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(8 * 3600)), .disarm(.timer))
    }

    func testNoLimitMeansNoLimit() {
        var policy = SafetyPolicy(settings: SafetySettings(maxDurationSeconds: nil))
        let sample = PowerSample(onAC: true, current: 4000, max: 5000, warning: .none)
        XCTAssertEqual(policy.evaluate(power: sample, thermal: .nominal, armedSince: t0,
                                       now: t0.addingTimeInterval(72 * 3600)), .ok)
    }

    // MARK: arming refusals

    func testRefusalReasons() {
        let healthy = PowerSample(onAC: false, current: 4000, max: 5000, warning: .none)
        let settings = SafetySettings()

        XCTAssertEqual(SafetyPolicy.refusalReason(power: healthy, thermal: .nominal,
                                                  settings: settings, lid: .noLid,
                                                  foreignHolders: []), .noLid)
        XCTAssertEqual(SafetyPolicy.refusalReason(power: healthy, thermal: .critical,
                                                  settings: settings, lid: .open,
                                                  foreignHolders: []), .tooHot)
        XCTAssertEqual(SafetyPolicy.refusalReason(
            power: PowerSample(onAC: false, current: 500, max: 5000, warning: .none),
            thermal: .nominal, settings: settings, lid: .open, foreignHolders: []), .batteryTooLow)
        XCTAssertNil(SafetyPolicy.refusalReason(power: healthy, thermal: .fair,
                                                settings: settings, lid: .unknown,
                                                foreignHolders: []),
                     "an unknown lid is a laptop that has not reported yet, not a machine without one")
    }

    func testEveryRefusalHasItsOwnSentence() {
        let refusals: [ArmRefusal] = [
            .noLid, .unsupportedOS, .batteryTooLow, .tooHot,
            .foreignHolder(ForeignHolder(pid: 1, name: "caffeinate")),
            .externalDisplayOnAC, .watchdogUnavailable, .notInApplications
        ]
        let sentences = refusals.map(\.sentence)
        XCTAssertEqual(Set(sentences).count, refusals.count, "no two refusals share a message")
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains("error"), "never a generic error string")
        }
    }

    func testEveryAutomaticDisarmReasonExplainsItself() {
        for reason in DisarmReason.allCases where reason != .user && reason != .quit {
            XCTAssertNotNil(reason.userFacingSentence,
                            "\(reason.rawValue) would leave the user with no explanation")
        }
    }

    // MARK: the debouncer itself

    func testSustainedConditionResets() {
        var condition = SustainedCondition(interval: 2)
        XCTAssertFalse(condition.update(true, at: t0))
        XCTAssertFalse(condition.update(false, at: t0.addingTimeInterval(1)))
        XCTAssertFalse(condition.update(true, at: t0.addingTimeInterval(2)),
                       "the clock restarts after a disagreeing sample")
        XCTAssertTrue(condition.update(true, at: t0.addingTimeInterval(4.1)))
    }
}
