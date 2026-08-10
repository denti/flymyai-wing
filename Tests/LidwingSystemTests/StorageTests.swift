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
        defer { _ = umask(previous) }

        guard let descriptor = UnixSocket.listen(path: path) else {
            throw XCTSkip("could not bind a socket in the sandbox")
        }
        defer { _ = close(descriptor); _ = unlink(path) }

        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertFalse(StatePermissions.isTooOpen(Int(status.st_mode) & 0o7777),
                       "the socket is reachable by other users on this Mac")
    }

    // MARK: the files themselves
    //
    // Moved here from ControlSocketTests.swift, where this class used to live under another
    // file's name. That is how the repository ended up with two classes called StorageTests and
    // a macOS build that would not compile: the numbers in TESTING.md count *classes*, and I
    // read them as files.

    private func temporaryURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidwing-\(name)-\(UUID().uuidString)")
    }

    func testLedgerRoundTripsThroughTheRealFilesystem() throws {
        let url = temporaryURL("ledger")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileLedgerStore(url: url)

        XCTAssertNil(store.read())
        let ledger = Ledger(bootSessionUUID: "BOOT-A", capturedAt: Date(),
                            weSetClamshellBit: true, reason: "user", appVersion: "1.0.0")
        try store.write(ledger)

        let raw = try XCTUnwrap(store.read())
        let decoded = try XCTUnwrap(Ledger.decode(raw))
        XCTAssertEqual(decoded.bootSessionUUID, "BOOT-A")
        XCTAssertTrue(decoded.weSetClamshellBit)

        store.delete()
        XCTAssertNil(store.read())
    }

    /// The write is a temp file plus `rename(2)`, so a reader never sees a partial record.
    func testLedgerLeavesNoTemporaryFileBehind() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidwing-ledger-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileLedgerStore(url: directory.appendingPathComponent("ledger.json"))
        try store.write(Ledger(bootSessionUUID: "B", capturedAt: Date(),
                               weSetClamshellBit: true, reason: "user", appVersion: "1.0.0"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["ledger.json"], "got: \(contents)")
    }

    func testAuditSinkAppendsOneLinePerRecordAndReadsThemBack() throws {
        let url = temporaryURL("audit")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = FileAuditSink(url: url)

        for index in 0..<3 {
            var session = AuditSession(armedAt: Date(timeIntervalSince1970: 1_000 + Double(index)))
            session.observe(batteryPercent: 50 + index)
            sink.append(session.finish(at: Date(timeIntervalSince1970: 2_000 + Double(index)),
                                       reason: .timer, tier: 1,
                                       sleepCountDelta: 0, darkWakeCountDelta: 0,
                                       os: "15.5", arch: "arm64", appVersion: "1.0.0"))
        }
        sink.note(.sleptWhileArmed, at: Date(), context: ["lid": "closed"])

        // The sink writes on its own queue; wait for it rather than sleeping a fixed amount.
        let deadline = Date().addingTimeInterval(5)
        var lines: [String] = []
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                lines = text.split(separator: "\n").map(String.init)
                if lines.count == 4 { break }
            }
            usleep(50_000)
        }
        XCTAssertEqual(lines.count, 4, "expected three records and one failure note")

        let records = sink.recentRecords(limit: 3)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first?.minBatteryPercent, 52, "newest first")

        let noteLine = try XCTUnwrap(lines.last)
        XCTAssertTrue(noteLine.contains("SLEPT_WHILE_ARMED"))
        XCTAssertTrue(noteLine.contains("closed"))
    }
}
