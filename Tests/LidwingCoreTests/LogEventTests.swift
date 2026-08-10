import XCTest
@testable import LidwingCore

/// The log is what a support ticket is answered from, so its contract is tested rather than
/// remembered: which events exist, at what level, and which fields are safe to record.
final class LogEventTests: XCTestCase {

    /// `log show` prints only default-level messages unless `--info` or `--debug` is passed,
    /// and those live in a ring buffer that rolls. A line at `.info` is a line that will not be
    /// in the bundle a user sends you.
    func testNothingIsLoggedBelowNotice() {
        for event in LogCatalogue.all {
            XCTAssertTrue([.notice, .error, .fault].contains(event.level),
                          "\(event.name) is below notice and would not survive to a support bundle")
        }
    }

    /// Invariant I5 has no benign case, so it has no level below fault.
    func testTheSleepFailureIsAFault() {
        XCTAssertEqual(LogCatalogue.sleptWhileArmed.level, .fault)
    }

    func testEveryFailureIsAtLeastAnError() {
        let failures = [LogCatalogue.armNoEffect, LogCatalogue.releaseNoEffect,
                        LogCatalogue.groundTruthLost, LogCatalogue.watchdogLost,
                        LogCatalogue.watchdogRecovered, LogCatalogue.ledgerWriteFailed,
                        LogCatalogue.integrationRefused]
        for event in failures {
            XCTAssertNotEqual(event.level, .notice, "\(event.name) is only a notice")
        }
    }

    func testEventNamesAreUniqueAndGreppable() {
        let names = LogCatalogue.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two events share a name")
        for name in names {
            XCTAssertFalse(name.contains(" "), name)
            XCTAssertEqual(name, name.lowercased(), name)
        }
    }

    /// The allowlist is the privacy decision, in one reviewable place. Nothing path-like,
    /// nothing user-derived, nothing carried in from another tool's output.
    func testNoFieldNameSuggestsSomethingPrivate() {
        let forbidden = ["path", "file", "user", "home", "dir", "url", "host", "serial",
                         "name", "title", "body", "message", "command", "token", "key"]
        for event in LogCatalogue.all {
            for field in event.publicFields {
                let lowered = field.lowercased()
                for word in forbidden {
                    XCTAssertFalse(lowered.contains(word),
                                   "\(event.name) records a public field called '\(field)'")
                }
            }
        }
    }

    func testTheDisarmEventCarriesEverythingASoakNeedsToBeJudged() {
        // These are the numbers the project's own stop condition is stated in.
        let fields = LogCatalogue.disarmed.publicFields
        for required in ["reason", "durationS", "minBattery", "maxThermal", "reasserts"] {
            XCTAssertTrue(fields.contains(required), "disarm does not record \(required)")
        }
    }

    /// `BEGINSWITH`, so it catches the watchdog's subsystem too, and no `--info --debug`: if a
    /// line is missing, the fix is to raise its level in the source rather than widen the query.
    func testTheDocumentedCommandMatchesBothSubsystems() {
        let command = LogCatalogue.showCommand
        XCTAssertTrue(command.contains("BEGINSWITH"))
        XCTAssertTrue(command.contains(LidwingID.bundleID))
        XCTAssertFalse(command.contains("--info"))
        XCTAssertFalse(command.contains("--debug"))
    }

    func testEveryCategoryIsUsedByAtLeastOneEventName() {
        // A category nothing logs to is a category that makes `log show` output misleading.
        XCTAssertEqual(LogCatalogue.Category.allCases.count, 7)
    }
}
