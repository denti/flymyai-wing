import XCTest
@testable import LidwingCore

/// The menu is the entire visible surface of this product, so its strings are tested like
/// code. They also have to be testable without a window server: CI has no Aqua session, and a
/// screenshot there proves nothing.
final class MenuPresenterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_500_000)

    private func snapshot(state: LidwingState,
                          battery: Int? = 61,
                          onAC: Bool = false,
                          thermal: ThermalState = .nominal,
                          armedSince: Date? = nil,
                          remaining: Int? = nil,
                          holder: ForeignHolder? = nil,
                          agent: String? = nil,
                          failure: Date? = nil) -> MenuPresenter.Snapshot {
        MenuPresenter.Snapshot(state: state, armedSince: armedSince, now: now,
                               batteryPercent: battery, onAC: onAC, thermal: thermal,
                               floorPercent: 20, remainingSeconds: remaining,
                               lastFailureAt: failure, foreignHolder: holder,
                               agentRunning: agent)
    }

    func testOffState() {
        let content = MenuPresenter.content(for: snapshot(state: .idle))
        XCTAssertEqual(content.headline, "Off - your Mac sleeps normally")
        XCTAssertFalse(content.toggleChecked)
        XCTAssertTrue(content.toggleEnabled)
        XCTAssertEqual(content.detail, "battery 61% \u{00B7} on battery")
    }

    func testArmedStateNamesTheAgentWhenThereIsOne() {
        let content = MenuPresenter.content(
            for: snapshot(state: .armed, armedSince: now.addingTimeInterval(-8_040),
                          remaining: 20_760, agent: "claude"))
        XCTAssertEqual(content.headline, "Awake - claude is running")
        XCTAssertEqual(content.detail, "5h 46m left \u{00B7} battery 61% \u{00B7} on battery")
        XCTAssertTrue(content.toggleChecked)
        XCTAssertTrue(content.accessibilityValue.contains("2 hours 14 minutes"))
    }

    func testDegradedStatesSayWhyRatherThanJustLookingDifferent() {
        let hot = MenuPresenter.content(for: snapshot(state: .degraded, thermal: .serious))
        XCTAssertEqual(hot.headline, "Awake - your Mac is running hot")
        XCTAssertEqual(hot.detail, "Lidwing turns off if it gets hotter.")

        let low = MenuPresenter.content(for: snapshot(state: .degraded, battery: 23))
        XCTAssertEqual(low.headline, "Awake - battery 23%")
        XCTAssertEqual(low.detail, "Lidwing turns off at 20%.")
    }

    /// The state a user meets when the mechanism let them down. It must never look like the
    /// armed state, and it must carry the time.
    func testFailedStateIsExplicitAboutTheSleep() {
        let content = MenuPresenter.content(
            for: snapshot(state: .failed, failure: now))
        XCTAssertTrue(content.headline.hasPrefix("Your Mac slept at "))
        XCTAssertFalse(content.toggleChecked, "a failed state never shows a checkmark")
        XCTAssertTrue(content.accessibilityValue.contains("not protected"))
    }

    func testForeignHolderIsNamedRatherThanFoughtOver() {
        let content = MenuPresenter.content(
            for: snapshot(state: .idle, holder: ForeignHolder(pid: 812, name: "Amphetamine")))
        XCTAssertEqual(content.headline, "Another app is keeping this Mac awake")
        XCTAssertEqual(content.detail, "Amphetamine (pid 812) - Lidwing stood down.")
    }

    func testNoLidIsHiddenNotMerelyDisabled() {
        let content = MenuPresenter.content(for: snapshot(state: .unsupported))
        XCTAssertEqual(content.headline, "This Mac has no lid")
        XCTAssertFalse(content.toggleEnabled)
    }

    func testArmingNeverClaimsSuccessEarly() {
        let content = MenuPresenter.content(for: snapshot(state: .arming))
        XCTAssertTrue(content.headline.contains("Checking"))
        XCTAssertTrue(content.detail?.contains("never says it is on") ?? false)
    }

    /// Typography rules from the craft spec, enforced rather than remembered.
    func testCopyStyleRules() {
        let states: [LidwingState] = [.idle, .arming, .armed, .degraded, .disarming,
                                      .failed, .repair, .unsupported]
        for state in states {
            let content = MenuPresenter.content(for: snapshot(state: state, failure: now))
            for text in [content.headline, content.detail ?? "", content.toggleTitle] {
                XCTAssertFalse(text.contains("\u{2014}"), "em dash in: \(text)")
                XCTAssertFalse(text.contains("\u{2013}"), "en dash in: \(text)")
                XCTAssertFalse(text.contains("..."), "three periods instead of U+2026: \(text)")
                XCTAssertFalse(text.isEmpty && text == content.headline)
            }
            XCTAssertFalse(content.accessibilityValue.isEmpty,
                           "\(state) has no spoken value; VoiceOver users get nothing")
        }
    }

    func testDurationFormatting() {
        XCTAssertEqual(MenuPresenter.compactDuration(0), "0s")
        XCTAssertEqual(MenuPresenter.compactDuration(59), "59s")
        XCTAssertEqual(MenuPresenter.compactDuration(60), "1m")
        XCTAssertEqual(MenuPresenter.compactDuration(3_600), "1h 0m")
        XCTAssertEqual(MenuPresenter.compactDuration(25_920), "7h 12m")
        XCTAssertEqual(MenuPresenter.compactDuration(-5), "0s")

        // VoiceOver reads "7h" as "seven aitch".
        XCTAssertEqual(MenuPresenter.spokenDuration(25_920), "7 hours 12 minutes")
        XCTAssertEqual(MenuPresenter.spokenDuration(3_600), "1 hour")
        XCTAssertEqual(MenuPresenter.spokenDuration(30), "less than a minute")
    }
}

/// After the worst thing this product can do happens — the Mac sleeping while armed — it
/// re-arms itself. These tests are about what the user sees afterwards, because a plain
/// "Awake" would tell them the run is fine when the most important fact about it is that it
/// is not.
final class RecoveredFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_500_000)

    private func snapshot(state: LidwingState, sleeps: Int) -> MenuPresenter.Snapshot {
        MenuPresenter.Snapshot(state: state, armedSince: now.addingTimeInterval(-3600), now: now,
                               batteryPercent: 61, onAC: false, thermal: .nominal,
                               floorPercent: 20, remainingSeconds: nil,
                               lastFailureAt: now.addingTimeInterval(-1800),
                               foreignHolder: nil, agentRunning: nil, sleepsObserved: sleeps)
    }

    func testASleepStaysVisibleAfterASuccessfulReArm() {
        let content = MenuPresenter.content(for: snapshot(state: .armed, sleeps: 1))
        XCTAssertTrue(content.headline.contains("slept"),
                      "the menu forgot the Mac slept: \(content.headline)")
        XCTAssertTrue(content.toggleChecked, "we are protecting again, and the checkmark says so")
        XCTAssertTrue(content.accessibilityValue.contains("slept"))
    }

    func testACleanSessionSaysNothingAboutSleeping() {
        let content = MenuPresenter.content(for: snapshot(state: .armed, sleeps: 0))
        XCTAssertFalse(content.headline.contains("slept"), content.headline)
        XCTAssertEqual(content.headline, "Awake - you can close the lid")
    }

    func testItSurvivesTheDegradedStateToo() {
        // A hot Mac that also slept has two things wrong with it, and the sleep is the one
        // that means the mechanism did not hold.
        let content = MenuPresenter.content(for: snapshot(state: .degraded, sleeps: 2))
        XCTAssertTrue(content.headline.contains("slept"), content.headline)
    }
}
