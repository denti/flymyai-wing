import XCTest
@testable import LidwingCore

/// The state directory holds the ledger, the audit log and both sockets. The audit log records
/// when this Mac was kept awake and which agent binaries ran, so "owner only" is a promise this
/// product makes rather than a default it inherited.
final class StatePermissionsTests: XCTestCase {

    func testAPrivateDirectoryIsLeftAlone() {
        XCTAssertFalse(StatePermissions.isTooOpen(0o700))
        XCTAssertEqual(StatePermissions.tightened(0o700), 0o700)
    }

    /// The modes a directory actually turns up with: the usual default, a group-writable one
    /// from a restored backup, and world-readable.
    func testTheModesThatTurnUpInPracticeAreCaught() {
        for mode in [0o755, 0o750, 0o775, 0o777, 0o701, 0o710, 0o740] {
            XCTAssertTrue(StatePermissions.isTooOpen(mode),
                          "\(String(mode, radix: 8)) lets somebody else in and was accepted")
            XCTAssertFalse(StatePermissions.isTooOpen(StatePermissions.tightened(mode)),
                           "\(String(mode, radix: 8)) was still too open after tightening")
        }
    }

    /// Repairing must not take away the owner's own access, which would leave a directory
    /// Lidwing cannot write to - a fix that breaks the product is not a fix.
    func testTighteningNeverRemovesTheOwnersAccess() {
        for mode in [0o755, 0o777, 0o700, 0o644] {
            let tightened = StatePermissions.tightened(mode)
            XCTAssertEqual(tightened & 0o700, mode & 0o700,
                           "\(String(mode, radix: 8)) lost owner bits when tightened")
        }
    }

    /// Bits this rule has no opinion about must survive. A check that demanded exactly 0700
    /// would keep "repairing" a directory that is already private, every launch, forever.
    func testUnrelatedBitsAreNotDisturbed() {
        let sticky = 0o1700
        XCTAssertFalse(StatePermissions.isTooOpen(sticky))
        XCTAssertEqual(StatePermissions.tightened(sticky), sticky)
    }

    func testTheDeclaredModesAreThemselvesPrivate() {
        XCTAssertFalse(StatePermissions.isTooOpen(StatePermissions.directoryMode))
        XCTAssertFalse(StatePermissions.isTooOpen(StatePermissions.fileMode))
        // A file that the owner cannot read is not a file we can use.
        XCTAssertEqual(StatePermissions.fileMode & 0o600, 0o600)
    }
}
