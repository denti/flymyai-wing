import XCTest
@testable import LidwingCore

/// Noticing that macOS changed under the one undocumented selector this product rests on.
final class OSChangeWatchTests: XCTestCase {

    func testNoBaselineOnAFirstRun() {
        XCTAssertEqual(OSChangeWatch.compare(lastVerifiedOS: nil, current: "15.6 (24G84)"),
                       .noBaseline)
    }

    /// An empty string is what a `UserDefaults` read gives you if somebody registers a default
    /// for this key. It must read as "no baseline", not as an OS called "".
    func testAnEmptyStoredValueIsNotAnOSChange() {
        XCTAssertEqual(OSChangeWatch.compare(lastVerifiedOS: "", current: "15.6 (24G84)"),
                       .noBaseline)
    }

    func testSameBuildIsUnchanged() {
        XCTAssertEqual(OSChangeWatch.compare(lastVerifiedOS: "15.6 (24G84)",
                                             current: "15.6 (24G84)"),
                       .unchanged)
    }

    /// The case that matters most and is easiest to miss: a security update keeps the marketing
    /// version and changes only the build. That update can ship a new kernel.
    func testABuildOnlyChangeCounts() {
        XCTAssertEqual(OSChangeWatch.compare(lastVerifiedOS: "15.6 (24G84)",
                                             current: "15.6 (24G90)"),
                       .changed(from: "15.6 (24G84)", to: "15.6 (24G90)"))
    }

    func testAMajorUpgradeCounts() {
        XCTAssertEqual(OSChangeWatch.compare(lastVerifiedOS: "15.6 (24G84)",
                                             current: "26.0 (25A100)"),
                       .changed(from: "15.6 (24G84)", to: "26.0 (25A100)"))
    }
}

/// The same thing wired through the state machine, which is where it has to be right: the notice
/// must be earned by an arm that actually verified, and must never fire on its own.
/// A machine plus its mock, so the tests below need no implicitly-unwrapped state.
private struct Recheck {
    let mock: MockSystem
    let machine: StateMachine

    init(os: String, lastVerified: String?) {
        let (system, _, _, _, built) = TestFixture.harness(
            identity: RuntimeIdentity(osVersion: os, arch: "arm64", appVersion: "1.0.0"))
        mock = system
        machine = built
        machine.lastVerifiedOS = lastVerified
        machine.hasEverArmed = true
        _ = machine.handle(.launch)
    }

    /// Drives a full arm through to verification, the way the app does. `MockSystem` flips
    /// ground truth itself when `mechanismWorks`, so this is the honest path rather than a test
    /// reaching in to declare success.
    func armAndVerify(file: StaticString = #filePath, line: UInt = #line) -> [LidwingEffect] {
        var effects = machine.handle(.userArm)
        effects += machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed,
                       "the arm never verified, so the assertions below prove nothing",
                       file: file, line: line)
        return effects
    }

    func disarm() {
        _ = machine.handle(.userDisarm)
        _ = machine.handle(.verifyTick)
    }
}

private func notices(_ effects: [LidwingEffect]) -> [UserNotice] {
    effects.compactMap { if case .notify(let notice) = $0 { return notice } else { return nil } }
}

private func mentionsAnUpdate(_ effects: [LidwingEffect]) -> Bool {
    notices(effects).contains {
        if case .recheckedAfterOSUpdate = $0 { return true } else { return false }
    }
}

/// The same thing wired through the state machine, which is where it has to be right: the notice
/// must be earned by an arm that actually verified, and must never fire on its own.
final class OSRecheckIntegrationTests: XCTestCase {

    func testAVerifiedArmOnANewBuildSaysSoExactlyOnce() {
        let harness = Recheck(os: "26.0 (25A100)", lastVerified: "15.6 (24G84)")

        let first = notices(harness.armAndVerify())
        XCTAssertTrue(first.contains(.recheckedAfterOSUpdate(from: "15.6 (24G84)",
                                                             to: "26.0 (25A100)")),
                      "a verified arm after a macOS update said nothing: \(first)")

        harness.disarm()
        XCTAssertFalse(mentionsAnUpdate(harness.armAndVerify()),
                       "the update notice fired a second time")
    }

    func testTheOSIsRecordedOnlyByAnArmThatVerified() {
        let harness = Recheck(os: "26.0 (25A100)", lastVerified: "15.6 (24G84)")
        // The write reports success and the machine never agrees - the exact failure mode both
        // real mechanisms exhibit.
        harness.mock.mechanismWorks = false

        let applying = harness.machine.handle(.userArm)
        XCTAssertFalse(applying.contains(.recordVerifiedOS("26.0 (25A100)")),
                       "the new build was recorded before anything verified it")

        harness.mock.advance(StateMachine.verifyDeadline + 0.1)
        _ = harness.machine.handle(.verifyTick)
        XCTAssertEqual(harness.machine.state, .failed)
        XCTAssertEqual(harness.machine.lastVerifiedOS, "15.6 (24G84)",
                       "a failed arm recorded the new build as verified")
    }

    func testAVerifiedArmRecordsTheBuild() {
        let harness = Recheck(os: "26.0 (25A100)", lastVerified: "15.6 (24G84)")
        XCTAssertTrue(harness.armAndVerify().contains(.recordVerifiedOS("26.0 (25A100)")))
        XCTAssertEqual(harness.machine.lastVerifiedOS, "26.0 (25A100)")
    }

    /// The quiet case. A user who has not updated macOS must never see any of this.
    func testNothingIsSaidWhenTheOSDidNotChange() {
        let harness = Recheck(os: "15.6 (24G84)", lastVerified: "15.6 (24G84)")
        let effects = harness.armAndVerify()
        XCTAssertFalse(mentionsAnUpdate(effects))
        XCTAssertFalse(effects.contains(.recordVerifiedOS("15.6 (24G84)")),
                       "re-recorded an OS that was already stored")
    }

    /// A first run has no baseline, and telling a new user that macOS changed - before Lidwing
    /// has ever worked for them once - is noise about something they cannot act on.
    func testAFirstRunIsQuietAndStillRecordsItsBaseline() {
        let harness = Recheck(os: "15.6 (24G84)", lastVerified: nil)
        let effects = harness.armAndVerify()
        XCTAssertFalse(mentionsAnUpdate(effects), "a first run announced a macOS change")
        XCTAssertTrue(effects.contains(.recordVerifiedOS("15.6 (24G84)")),
                      "a first run must still record the build it verified on")
    }

    /// If the app is launched on a new build and never manages a verified arm, the question is
    /// still open at the next launch. Nothing about it is persisted early.
    func testThePendingCheckSurvivesALaunchWithNoArm() {
        let harness = Recheck(os: "26.0 (25A100)", lastVerified: "15.6 (24G84)")
        XCTAssertEqual(harness.machine.lastVerifiedOS, "15.6 (24G84)",
                       "the new build was recorded merely for having been launched on")
    }
}
