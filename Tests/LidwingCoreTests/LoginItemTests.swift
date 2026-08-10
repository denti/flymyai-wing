import XCTest
@testable import LidwingCore

/// Opening at login is a feature with a bad reputation, earned by apps that turn it on without
/// asking and then keep their own boolean that disagrees with the system.
final class LoginItemTests: XCTestCase {

    private let everyStatus: [LoginItemStatus] =
        [.unavailable, .notRegistered, .enabled, .requiresApproval, .notFound]

    /// The rule with the worst failure mode: the checkbox is derived from the live status, so a
    /// user who revoked the login item in System Settings while Lidwing was not running sees an
    /// unticked box rather than a confident lie.
    func testTheCheckboxFollowsTheSystemAndNothingElse() {
        XCTAssertTrue(LoginItem.presentation(for: .enabled).isChecked)
        XCTAssertFalse(LoginItem.presentation(for: .notRegistered).isChecked)
        XCTAssertFalse(LoginItem.presentation(for: .notFound).isChecked)
    }

    /// Nothing anywhere may present this as on by default. `.notRegistered` is what a fresh
    /// install reports, and it must be unticked.
    func testAFreshInstallIsNotTicked() {
        let fresh = LoginItem.presentation(for: .notRegistered)
        XCTAssertFalse(fresh.isChecked)
        XCTAssertTrue(fresh.isVisible)
        XCTAssertNil(fresh.note, "a fresh install has nothing to explain")
    }

    /// macOS 12 has no compliant mechanism: SMAppService is 13+, and the two pre-13 routes are
    /// the two the antipattern list forbids. No checkbox is better than a dead one.
    func testTheCheckboxIsAbsentWhereNoCompliantMechanismExists() {
        let unavailable = LoginItem.presentation(for: .unavailable)
        XCTAssertFalse(unavailable.isVisible)
        XCTAssertNotNil(unavailable.note, "the feature vanished with no explanation")
    }

    /// Approval pending looks like success from inside the app and does nothing at login.
    func testApprovalPendingIsCheckedButExplained() {
        let pending = LoginItem.presentation(for: .requiresApproval)
        XCTAssertTrue(pending.isChecked, "unticking it invites a click that changes nothing")
        XCTAssertNotNil(pending.note)
        XCTAssertEqual(pending.note?.contains("Login Items"), true,
                       "the note has to say where to go")
    }

    func testApprovalPendingIsNotReportedAsWorking() {
        XCTAssertFalse(LoginItem.willLaunchAtLogin(.requiresApproval),
                       "this reads as on inside the app and launches nothing at login")
        XCTAssertTrue(LoginItem.willLaunchAtLogin(.enabled))
        for status in everyStatus where status != .enabled {
            XCTAssertFalse(LoginItem.willLaunchAtLogin(status), "\(status) reported as working")
        }
    }

    /// A state the user cannot act on is a dead end. Every visible state either needs no
    /// explanation or carries one.
    func testEveryVisibleStateIsEitherObviousOrExplained() {
        for status in everyStatus {
            let presentation = LoginItem.presentation(for: status)
            guard presentation.isVisible else { continue }
            XCTAssertTrue(presentation.isInteractive,
                          "\(status) shows a checkbox the user cannot use")
        }
    }

    func testTheNotesCarryNoFancyDashesOrTrailingSpace() {
        for status in everyStatus {
            guard let note = LoginItem.presentation(for: status).note else { continue }
            XCTAssertFalse(note.contains("\u{2014}") || note.contains("\u{2013}"),
                           "\(status): \"\(note)\" contains an em or en dash")
            XCTAssertEqual(note, note.trimmingCharacters(in: .whitespaces))
        }
    }
}
