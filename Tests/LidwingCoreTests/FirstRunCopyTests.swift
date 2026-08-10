import XCTest
@testable import LidwingCore

/// The first-run copy is the product's honesty test, so it is tested like code. The
/// limitations have to be on the same screen as the promise: a user who learns them later
/// learns them from a hot laptop and a flat battery.
final class FirstRunCopyTests: XCTestCase {

    func testTheLimitationsAreStatedUpFront() {
        let limitations = FirstRunCopy.Explainer.limitations
        XCTAssertEqual(limitations.count, 3)

        let joined = limitations.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("hotter"), "heat is not mentioned")
        XCTAssertTrue(joined.contains("battery"), "battery drain is not mentioned")
        XCTAssertTrue(joined.contains("bag"), "the bag warning is not on the first screen")
    }

    func testThePermissionSentenceIsTrueForTheShippingMechanism() {
        let text = FirstRunCopy.Explainer.permissions.lowercased()
        // Tier 1 asks for nothing. If a future change makes that false, this copy becomes a
        // lie in the one place a user decides whether to trust the app.
        XCTAssertTrue(text.contains("no password"))
        XCTAssertTrue(text.contains("no permissions"))
        XCTAssertTrue(text.contains("puts that setting back"))
    }

    func testSafetyDefaultsQuoteTheUsersActualSettings() {
        let lines = FirstRunCopy.Explainer.safetyDefaults(floorPercent: 25, hours: 4)
        XCTAssertTrue(lines.contains { $0.contains("25%") })
        XCTAssertTrue(lines.contains { $0.contains("4 hours") })
        XCTAssertEqual(lines.count, 3)
    }

    func testTheProofScreenQuotesACommandTheUserCanRun() {
        XCTAssertTrue(FirstRunCopy.Proof.command.hasPrefix("ioreg "))
        XCTAssertTrue(FirstRunCopy.Proof.command.contains("AppleClamshellCausesSleep"))
        XCTAssertFalse(FirstRunCopy.Proof.command.contains("sudo"),
                       "a verification command that needs root is not one a user will run")
    }

    func testNoCopyUsesAnEmDashOrThreePeriods() {
        var everything = FirstRunCopy.Explainer.limitations
        everything.append(FirstRunCopy.Explainer.promise)
        everything.append(FirstRunCopy.Explainer.permissions)
        everything.append(FirstRunCopy.LocationCallout.headline)
        everything.append(FirstRunCopy.LocationCallout.body)
        everything.append(FirstRunCopy.Proof.body)
        for text in everything {
            XCTAssertFalse(text.contains("\u{2014}"), "em dash: \(text)")
            XCTAssertFalse(text.contains("..."), "three periods: \(text)")
        }
    }

    func testTheCalloutDoesNotWaitForever() {
        XCTAssertLessThanOrEqual(FirstRunCopy.LocationCallout.autoDismissSeconds, 10,
                                 "a first-launch window that waits for a click is a nag")
    }
}
