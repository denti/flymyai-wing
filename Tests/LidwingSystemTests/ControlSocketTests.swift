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
