import XCTest
@testable import LidwingSystem
@testable import LidwingCore

/// The state directory, on a real filesystem.
///
/// `StatePermissions` decides the rule and is tested on Linux. These are the syscalls: that an
/// existing directory is actually repaired, that a symlink is actually refused, and that the
/// files written inside are not readable by anyone else.
final class StorageTests: XCTestCase {

    /// A fresh directory per test. Not an implicitly-unwrapped property: a nil there fails
    /// inside whichever test ran first, which is the least useful place to find out.
    private let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lidwing-storage-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func mode(of url: URL) throws -> Int {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw XCTSkip("could not stat \(url.path)")
        }
        return Int(status.st_mode) & 0o7777
    }

    /// The defect this was written for: a directory that already existed kept whatever mode it
    /// had, forever, because the check returned as soon as the path existed.
    func testAnExistingTooOpenDirectoryIsRepaired() throws {
        let directory = sandbox.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(StatePermissions.isTooOpen(try mode(of: directory)),
                      "the fixture is not actually too open, so this test proves nothing")

        XCTAssertTrue(SupportDirectory.ensure(at: directory))
        XCTAssertFalse(StatePermissions.isTooOpen(try mode(of: directory)),
                       "a world-readable state directory survived the check")
    }

    func testAnAlreadyPrivateDirectoryIsAccepted() throws {
        let directory = sandbox.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(SupportDirectory.ensure(at: directory))
        XCTAssertEqual(try mode(of: directory), 0o700)
    }

    func testAMissingDirectoryIsCreatedPrivate() throws {
        let directory = sandbox.appendingPathComponent("state")
        XCTAssertTrue(SupportDirectory.ensure(at: directory))
        XCTAssertFalse(StatePermissions.isTooOpen(try mode(of: directory)))
    }

    /// `fileExists` follows symlinks, so a symlink to anywhere at all reported a perfectly good
    /// directory. Writing the ledger and the sockets through somebody else's symlink is not
    /// something to accept quietly, and it is not something that can be repaired either.
    func testASymlinkIsRefusedRatherThanFollowed() throws {
        let elsewhere = sandbox.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let directory = sandbox.appendingPathComponent("state")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)

        XCTAssertFalse(SupportDirectory.ensure(at: directory),
                       "a symlinked state directory was accepted")
    }

    /// A plain file where the directory should be is not something to write into either.
    func testAFileWhereTheDirectoryShouldBeIsRefused() throws {
        let directory = sandbox.appendingPathComponent("state")
        try Data("not a directory".utf8).write(to: directory)
        XCTAssertFalse(SupportDirectory.ensure(at: directory))
    }

    /// The socket has to be private from the instant it exists, not one call later.
    func testAListeningSocketIsOwnerOnly() throws {
        let path = sandbox.appendingPathComponent("s.sock").path
        // A umask that would otherwise leave the socket group- and world-readable.
        let previous = umask(0o000)
        defer { umask(previous) }

        guard let descriptor = UnixSocket.listen(path: path) else {
            throw XCTSkip("could not bind a socket in the sandbox")
        }
        defer { close(descriptor); unlink(path) }

        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertFalse(StatePermissions.isTooOpen(Int(status.st_mode) & 0o7777),
                       "the socket is reachable by other users on this Mac")
    }
}
