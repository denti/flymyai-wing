import XCTest
@testable import LidwingCore

/// The uninstall order is testable without a machine because it is data, and it is data
/// because reversing two of these steps leaves a Mac that has permanently lost lid-close sleep
/// with no process left alive to undo it.
final class UninstallTests: XCTestCase {

    func testDisarmIsAlwaysFirst() {
        XCTAssertEqual(UninstallPlan.steps.first, .disarmAndVerify,
                       "nothing may run while the machine is still held awake by us")
    }

    func testVerificationHappensBeforeWeTellTheUserWeAreDone() {
        let steps = UninstallPlan.steps
        let verify = steps.firstIndex(of: .verifyStock)
        let reveal = steps.firstIndex(of: .revealApp)
        XCTAssertNotNil(verify)
        XCTAssertNotNil(reveal)
        XCTAssertLessThan(verify ?? .max, reveal ?? 0)
    }

    func testWeRemoveOurHooksWhileOurBinaryStillExists() {
        let steps = UninstallPlan.steps
        let integrations = steps.firstIndex(of: .removeIntegrations) ?? .max
        let support = steps.firstIndex(of: .removeSupportDirectory) ?? 0
        XCTAssertLessThan(integrations, support,
                          "our own preferences hold what we displaced; they go last")
    }

    func testTheWatchdogOutlivesTheThingItWatches() {
        let steps = UninstallPlan.steps
        let disarm = steps.firstIndex(of: .disarmAndVerify) ?? .max
        let watchdog = steps.firstIndex(of: .removeWatchdog) ?? 0
        XCTAssertLessThan(disarm, watchdog)
    }

    func testEveryStepHasAStatedReason() {
        for step in UninstallPlan.steps {
            let reason = UninstallPlan.rationale(for: step)
            XCTAssertFalse(reason.isEmpty, "\(step) has no reason recorded")
            XCTAssertTrue(reason.hasSuffix("."))
        }
    }

    func testThePlanHasNoDuplicatesAndNoGaps() {
        XCTAssertEqual(Set(UninstallPlan.steps).count, UninstallPlan.steps.count)
        XCTAssertEqual(UninstallPlan.steps.count, 7)
    }

    /// Tier 1 installs no privileged helper at all. A file at any of these paths would mean a
    /// root daemon came back without this list being updated.
    func testTheForbiddenPathsAreTheLegacyPrivilegedOnes() {
        for path in UninstallSurface.mustNeverExist {
            XCTAssertTrue(path.hasPrefix("/Library/"), path)
            XCTAssertTrue(path.lowercased().contains("lidwing"), path)
        }
        XCTAssertTrue(UninstallSurface.mustNeverExist
            .contains("/Library/LaunchDaemons/ai.flymy.lidwing.helper.plist"))
    }

    func testWeNeverDeleteAThirdPartyFile() {
        // The third-party files are edited, never removed. If one of them ever appears in the
        // deletion list, this test is what stops it reaching a user's machine.
        for file in UninstallSurface.thirdPartyFiles {
            XCTAssertFalse(UninstallSurface.homeRelativePaths.contains(file), file)
            XCTAssertFalse(UninstallSurface.homeRelativePaths.contains { $0.contains(file) }, file)
        }
    }

    func testEverythingWeCreateIsInsideTheUsersOwnLibrary() {
        for path in UninstallSurface.homeRelativePaths {
            XCTAssertTrue(path.hasPrefix("Library/"), path)
            XCTAssertFalse(path.hasPrefix("/"), "\(path) is absolute; it must be home-relative")
        }
    }
}
