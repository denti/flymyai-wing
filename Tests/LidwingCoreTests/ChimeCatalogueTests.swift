import XCTest
@testable import LidwingCore

/// Sound is the only channel this product has once the lid is shut, so "it silently stopped
/// working" is not a cosmetic bug here.
final class ChimeCatalogueTests: XCTestCase {

    private func everythingPresent(_ path: String) -> Bool { path.hasSuffix(".aiff") }

    func testEveryChimeResolvesOnAStockMac() {
        let chosen = ChimeCatalogue.resolve(exists: everythingPresent)
        XCTAssertEqual(chosen[.sealed], "Submarine")
        XCTAssertEqual(chosen[.standingDown], "Bottle")
        XCTAssertEqual(chosen[.failure], "Basso")
        XCTAssertEqual(chosen[.agentWaiting], "Ping")
        XCTAssertTrue(ChimeCatalogue.missing(from: chosen).isEmpty)
    }

    /// The case that matters and that nobody has a machine for: exactly one sound is gone.
    func testAMissingPreferredSoundFallsBackInsteadOfGoingSilent() {
        let chosen = ChimeCatalogue.resolve { path in
            !path.hasSuffix("Submarine.aiff") && path.hasSuffix(".aiff")
        }
        XCTAssertEqual(chosen[.sealed], "Bottle", "the lid-close chime went silent")
        XCTAssertTrue(ChimeCatalogue.missing(from: chosen).isEmpty)
    }

    func testItFallsThroughMoreThanOneLevel() {
        let chosen = ChimeCatalogue.resolve { path in
            !path.hasSuffix("Submarine.aiff") && !path.hasSuffix("Bottle.aiff")
                && path.hasSuffix(".aiff")
        }
        XCTAssertEqual(chosen[.sealed], "Glass")
    }

    func testAChimeWithNothingLeftIsReportedRatherThanDropped() {
        let chosen = ChimeCatalogue.resolve { path in
            !["Submarine", "Bottle", "Glass"].contains { path.hasSuffix("\($0).aiff") }
                && path.hasSuffix(".aiff")
        }
        XCTAssertNil(chosen[.sealed])
        XCTAssertEqual(ChimeCatalogue.missing(from: chosen), [.sealed])
        XCTAssertNotNil(ChimeCatalogue.selfCheckWarning(missing: [.sealed]))
    }

    func testAMacWithNoSoundsAtAllReportsEveryChime() {
        let chosen = ChimeCatalogue.resolve { _ in false }
        XCTAssertEqual(Set(ChimeCatalogue.missing(from: chosen)),
                       Set([.sealed, .standingDown, .failure, .agentWaiting]))
    }

    /// A self-check that says "all good" on every launch is noise, and noise is how a real
    /// warning gets ignored six months later.
    func testTheSelfCheckIsSilentWhenNothingIsWrong() {
        XCTAssertNil(ChimeCatalogue.selfCheckWarning(missing: []))
    }

    func testTheWarningNamesWhatIsMissing() {
        let warning = ChimeCatalogue.selfCheckWarning(missing: [.sealed, .failure])
        XCTAssertEqual(warning?.contains("sealed"), true)
        XCTAssertEqual(warning?.contains("failure"), true)
    }

    /// Every candidate must be a stock macOS sound. A bundled file would have to be copied into
    /// the bundle by a build step, and a sound that silently stops shipping is this whole bug
    /// again one layer down.
    func testEveryCandidateIsAStockSystemSound() {
        for (chime, options) in ChimeCatalogue.candidates {
            XCTAssertFalse(options.isEmpty, "\(chime) has no candidates at all")
            for option in options {
                XCTAssertEqual(ChimeCatalogue.path(for: option),
                               "/System/Library/Sounds/\(option).aiff")
                XCTAssertFalse(option.contains("/"), "\(option) is a path, not a stock sound name")
            }
        }
    }

    /// Every chime the state machine can emit needs a sound. Adding a case to `Chime` and
    /// forgetting this table would produce a chime that is silent by construction.
    func testEveryChimeInTheEnumHasCandidates() {
        for chime in [Chime.sealed, .standingDown, .failure, .agentWaiting] {
            XCTAssertNotNil(ChimeCatalogue.candidates[chime], "\(chime) has no sound at all")
        }
    }

    /// The failure sound must not be pretty, and must not be the same as a confirmation - a
    /// user who hears the "everything is fine" chime when it is not has been actively misled.
    func testFailureDoesNotShareASoundWithAnyConfirmation() {
        let failure = Set(ChimeCatalogue.candidates[.failure] ?? [])
        let confirmations = Set((ChimeCatalogue.candidates[.sealed] ?? [])
                                + (ChimeCatalogue.candidates[.standingDown] ?? []))
        XCTAssertTrue(failure.isDisjoint(with: confirmations),
                      "a failure could sound exactly like a success")
    }
}
