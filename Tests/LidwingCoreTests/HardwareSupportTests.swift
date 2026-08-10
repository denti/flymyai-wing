import XCTest
@testable import LidwingCore

/// "There are many different MacBooks" - the constraint that keeps this table honest.
final class HardwareSupportTests: XCTestCase {

    func testTheOwnersMacIsTheOneMachineWithEvidence() {
        let level = HardwareSupport.level(model: "Mac14,2", macOSMajor: 15, arch: "arm64")
        guard case .mechanismSeen(let evidence) = level else {
            return XCTFail("expected mechanismSeen, got \(level)")
        }
        XCTAssertTrue(evidence.contains("M0"), evidence)
    }

    /// The M0 short form is twelve seconds. It is not an acceptance run, and the difference is
    /// the whole point of having two levels.
    func testTwelveSecondsIsNotAnAcceptanceRun() {
        for record in HardwareSupport.records {
            if case .accepted = record.level {
                XCTFail("\(record.model) claims acceptance; no acceptance run has happened yet")
            }
        }
    }

    /// A model one digit away is a different machine with a different thermal envelope.
    func testANeighbouringModelIsNotCovered() {
        XCTAssertEqual(HardwareSupport.level(model: "Mac14,3", macOSMajor: 15, arch: "arm64"),
                       .untested)
        XCTAssertEqual(HardwareSupport.level(model: "Mac15,2", macOSMajor: 15, arch: "arm64"),
                       .untested)
    }

    /// A macOS major is exactly where power management changes.
    func testANewerMacOSIsNotCovered() {
        XCTAssertEqual(HardwareSupport.level(model: "Mac14,2", macOSMajor: 26, arch: "arm64"),
                       .untested)
        XCTAssertEqual(HardwareSupport.level(model: "Mac14,2", macOSMajor: 14, arch: "arm64"),
                       .untested)
    }

    /// Intel is a different power-management world, and nobody has run this there.
    func testIntelIsNotCovered() {
        XCTAssertEqual(HardwareSupport.level(model: "Mac14,2", macOSMajor: 15, arch: "x86_64"),
                       .untested)
        XCTAssertEqual(HardwareSupport.level(model: "MacBookPro16,1", macOSMajor: 15,
                                             arch: "x86_64"),
                       .untested)
    }

    /// The default has to be "no evidence", not "probably fine". This is the assertion that
    /// stops the table quietly becoming a wish list.
    func testAnythingNotListedIsUntested() {
        for model in ["Mac16,1", "MacBookAir10,1", "MacBookPro18,3", "iMac21,1", ""] {
            XCTAssertEqual(HardwareSupport.level(model: model, macOSMajor: 15, arch: "arm64"),
                           .untested, model)
        }
    }

    /// An untested Mac says so. Silence would be the app implying a claim it cannot support.
    func testUntestedIsSaidOutLoud() {
        let notice = HardwareSupport.notice(for: .untested)
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.contains("not been tested"), true, notice ?? "nil")
    }

    /// It must not read as a failure warning. The mechanism may work perfectly here; what is
    /// missing is evidence, and the wording has to carry that difference.
    func testTheUntestedNoticeDoesNotClaimItWillFail() {
        let notice = HardwareSupport.notice(for: .untested) ?? ""
        for alarming in ["will not work", "unsupported", "incompatible", "error", "fail to"] {
            XCTAssertFalse(notice.lowercased().contains(alarming),
                           "\"\(notice)\" reads as a prediction of failure")
        }
    }

    /// A product that congratulates itself on every launch for working is noise.
    func testAnAcceptedMacIsToldNothing() {
        XCTAssertNil(HardwareSupport.notice(for: .accepted(evidence: "A1-A10, run 1")))
    }

    func testPartialEvidenceSaysItIsPartial() {
        let notice = HardwareSupport.notice(for: .mechanismSeen(evidence: "M0 short form"))
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.lowercased().contains("not for a full run"), true, notice ?? "nil")
    }

    /// Diagnostics always says something: it is read by somebody who cannot see the machine.
    func testDiagnosticsAlwaysReportsSomething() {
        let known = HardwareSupport.diagnosticsLine(model: "Mac14,2", macOSMajor: 15,
                                                    arch: "arm64")
        XCTAssertTrue(known.contains("mechanism seen"), known)
        let unknown = HardwareSupport.diagnosticsLine(model: "Mac99,9", macOSMajor: 26,
                                                      arch: "x86_64")
        XCTAssertTrue(unknown.contains("untested"), unknown)
        // The specific combination, so a support reply does not have to ask for it.
        XCTAssertTrue(unknown.contains("Mac99,9") && unknown.contains("26")
                      && unknown.contains("x86_64"), unknown)
    }

    /// Every record must carry the run that justifies it. A row with no evidence string is a
    /// claim somebody made up.
    func testEveryRecordCitesItsEvidence() {
        for record in HardwareSupport.records {
            switch record.level {
            case .accepted(let evidence), .mechanismSeen(let evidence):
                XCTAssertFalse(evidence.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(record.model) has no evidence recorded")
            case .untested:
                XCTFail("\(record.model) is listed as a record but claims nothing")
            }
        }
    }
}
