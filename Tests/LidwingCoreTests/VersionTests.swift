import XCTest
@testable import LidwingCore

final class VersionTests: XCTestCase {

    /// The reason the padding exists: a code-signing requirement compares
    /// `info[LWTrustBuild]` as a string. Unpadded, "1.10" sorts below "1.9" and a downgrade
    /// pin silently inverts, which is exactly the hole the pin was added to close.
    func testPaddedBuildNumbersSortLexicographicallyInNumericOrder() {
        let samples: [UInt64] = [1, 9, 10, 42, 99, 100, 142, 999, 1000, 9_999_999_999]
        let padded = samples.map { BuildNumber($0)!.padded }
        XCTAssertEqual(padded.sorted(), padded)
        XCTAssertTrue(padded.allSatisfy { $0.count == BuildNumber.digits })
        XCTAssertEqual(BuildNumber(142)!.padded, "0000000142")
    }

    func testUnpaddedComparisonWouldHaveBeenWrong() {
        // Positive control for the test above: the naive form really does invert.
        XCTAssertTrue("1.10" < "1.9")
        XCTAssertTrue(BuildNumber(9)! < BuildNumber(10)!)
        XCTAssertTrue(BuildNumber(9)!.padded < BuildNumber(10)!.padded)
    }

    func testBuildNumberRejectsWhatItCannotRepresent() {
        XCTAssertNil(BuildNumber(BuildNumber.maximum + 1))
        XCTAssertNil(BuildNumber(string: ""))
        XCTAssertNil(BuildNumber(string: "12a"))
        XCTAssertNil(BuildNumber(string: "-4"))
        XCTAssertEqual(BuildNumber(string: "0000000142")?.value, 142)
        XCTAssertEqual(BuildNumber(string: " 142 ")?.value, 142)
    }

    func testSemanticVersionParsingAndOrdering() {
        XCTAssertEqual(SemanticVersion(string: "v1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion(string: "1.2"), SemanticVersion(1, 2, 0))
        XCTAssertEqual(SemanticVersion(string: "1"), SemanticVersion(1, 0, 0))
        XCTAssertNil(SemanticVersion(string: "1.2.3.4"))
        XCTAssertNil(SemanticVersion(string: "1.x.3"))
        XCTAssertNil(SemanticVersion(string: ""))

        XCTAssertTrue(SemanticVersion(1, 9, 0) < SemanticVersion(1, 10, 0))
        XCTAssertTrue(SemanticVersion(0, 9, 9) < SemanticVersion(1, 0, 0))
        XCTAssertEqual(SemanticVersion(1, 0, 0).description, "1.0.0")
    }

    func testIdentifiersAreConsistent() {
        // These strings end up in a launchd label, a code-signing requirement and inside
        // third-party config files. A typo here is a migration that edits other people's files.
        XCTAssertEqual(LidwingID.bundleID, "ai.flymy.lidwing")
        XCTAssertTrue(LidwingID.watchdogLabel.hasPrefix(LidwingID.bundleID))
        XCTAssertTrue(LidwingID.helperLabel.hasPrefix(LidwingID.bundleID))
        XCTAssertTrue(LidwingID.reconcilerLabel.hasPrefix(LidwingID.bundleID))
        XCTAssertEqual(LidwingID.machService, LidwingID.helperLabel)
        XCTAssertTrue(LidwingID.integrationMarker.contains(LidwingID.productName))
    }
}
