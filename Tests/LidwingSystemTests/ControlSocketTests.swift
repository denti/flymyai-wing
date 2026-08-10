import XCTest
import Foundation
@testable import LidwingCore
@testable import LidwingSystem

/// These run on a macOS runner without a window server, without hardware and without
/// privileges. They cover the parts of the Darwin layer that are ordinary code: the wire
/// format, the socket, and the two files that have to survive a crash.
final class ControlSocketTests: XCTestCase {

    func testWireRoundTrip() throws {
        let messages: [ControlMessage] = [
            .armed(bootSession: "BOOT-1234", pid: 4412),
            .heartbeat(at: Date(timeIntervalSince1970: 1_786_500_000)),
            .disarmed
        ]
        for message in messages {
            let encoded = ControlWire.encode(message, bootSession: "BOOT-1234", pid: 4412)
            XCTAssertEqual(encoded.last, 0x0A, "every message is one newline-terminated line")
            let line = encoded.dropLast()
            let decoded = try XCTUnwrap(ControlWire.decode(Data(line)),
                                        "failed to decode \(message)")
            XCTAssertEqual(decoded, message)
        }
    }

    /// The watchdog clears a bit that decides whether somebody's Mac can sleep. It rejects
    /// what it does not understand rather than guessing.
    func testWireRejectsGarbageAndWrongVersions() {
        XCTAssertNil(ControlWire.decode(Data("not json".utf8)))
        XCTAssertNil(ControlWire.decode(Data("{}".utf8)))
        XCTAssertNil(ControlWire.decode(Data(#"{"v":99,"cmd":"disarmed"}"#.utf8)))
        XCTAssertNil(ControlWire.decode(Data(#"{"v":1,"cmd":"selfDestruct"}"#.utf8)))
        XCTAssertNil(ControlWire.decode(Data(#"{"v":1,"cmd":"armed"}"#.utf8)),
                     "an armed message without a boot session is not usable")
    }

    func testLoopbackDeliversLines() throws {
        let path = NSTemporaryDirectory() + "lidwing-test-\(UUID().uuidString).sock"
        defer { unlink(path) }

        let listener = try XCTUnwrap(UnixSocket.listen(path: path))
        defer { close(listener) }

        let client = try XCTUnwrap(UnixSocket.connect(path: path))
        defer { close(client) }

        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        let payload = ControlWire.encode(.armed(bootSession: "B", pid: 7),
                                         bootSession: "B", pid: 7)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(accepted, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0, "an empty read is a failure, not a pass")
        let received = Data(buffer[0..<max(0, count)]).dropLast()
        XCTAssertEqual(ControlWire.decode(Data(received)), .armed(bootSession: "B", pid: 7))
    }

    /// The socket is created 0600. It is the channel that tells a process to stop protecting
    /// the machine, so it is not readable by other users.
    func testSocketIsPrivate() throws {
        let path = NSTemporaryDirectory() + "lidwing-mode-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let listener = try XCTUnwrap(UnixSocket.listen(path: path))
        defer { close(listener) }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o777, 0o600)
    }

    func testConnectingToNothingFailsQuicklyAndDoesNotThrow() {
        let path = NSTemporaryDirectory() + "lidwing-absent-\(UUID().uuidString).sock"
        let start = Date()
        XCTAssertNil(UnixSocket.connect(path: path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testAPathTooLongForSunPathIsRefusedRatherThanTruncated() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        XCTAssertNil(UnixSocket.makeAddress(path: path),
                     "a truncated socket path would connect to the wrong place")
    }
}

final class StorageTests: XCTestCase {

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
