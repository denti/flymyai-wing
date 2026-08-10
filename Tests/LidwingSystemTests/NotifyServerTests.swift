import XCTest
import Foundation
@testable import LidwingCore
@testable import LidwingSystem

/// Invariant I8: nothing arriving on `notify.sock` can arm anything. These tests cover the
/// other half of that promise — that the bytes on it are treated as what they are, which is
/// untrusted text written by somebody else's tool and delivered by a binary anyone can run.
final class NotifyServerTests: XCTestCase {

    func testAWellFormedMessageIsAccepted() throws {
        let line = Data(#"{"v":1,"src":"claude","body":"needs permission to run tests"}"#.utf8)
        let signal = try XCTUnwrap(NotifyServer.parse(line))
        XCTAssertEqual(signal.source, "claude")
        XCTAssertEqual(signal.body, "needs permission to run tests")
    }

    /// The source string goes into a notification title. It is not a free-text field.
    func testAnUnknownSourceBecomesTheGenericOne() throws {
        let line = Data(#"{"v":1,"src":"<script>","body":"x"}"#.utf8)
        XCTAssertEqual(try XCTUnwrap(NotifyServer.parse(line)).source, "hook")
    }

    func testControlCharactersAreStripped() {
        // A terminal escape sequence in a notification body is somebody else's tool getting to
        // draw on our UI.
        let escape = String(UnicodeScalar(27)) + "[31mred"
        XCTAssertEqual(NotifyServer.sanitise(escape), "[31mred")
        XCTAssertEqual(NotifyServer.sanitise("a\u{0}b\u{7}c"), "abc")
        XCTAssertEqual(NotifyServer.sanitise("line\nbreak"), "linebreak")
    }

    func testLongBodiesAreTruncated() throws {
        let long = String(repeating: "x", count: 5_000)
        let line = Data("{\"v\":1,\"src\":\"codex\",\"body\":\"\(long)\"}".utf8)
        let signal = try XCTUnwrap(NotifyServer.parse(line))
        XCTAssertEqual(signal.body.count, NotifyServer.maximumBodyLength)
    }

    func testGarbageIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(NotifyServer.parse(Data("not json".utf8)))
        XCTAssertNil(NotifyServer.parse(Data("{}".utf8)))
        XCTAssertNil(NotifyServer.parse(Data(#"{"v":2,"src":"codex"}"#.utf8)))
        XCTAssertNil(NotifyServer.parse(Data("[1,2,3]".utf8)))
    }

    /// The hook may have nothing useful to say. That is still a signal worth acting on.
    func testAMissingBodyIsEmptyRatherThanAFailure() throws {
        let signal = try XCTUnwrap(NotifyServer.parse(Data(#"{"v":1,"src":"claude"}"#.utf8)))
        XCTAssertEqual(signal.body, "")
    }

    /// The structural half of invariant I8, asserted the only way a test can: the type that
    /// receives these messages holds no reference through which it could arm anything.
    func testTheServerCannotReachTheStateMachine() {
        let server = NotifyServer(socketPath: "/tmp/lidwing-unused.sock") { _ in }
        let mirror = Mirror(reflecting: server)
        for child in mirror.children {
            let type = String(describing: type(of: child.value))
            XCTAssertFalse(type.contains("StateMachine"), "found: \(type)")
            XCTAssertFalse(type.contains("SystemFacade"), "found: \(type)")
            XCTAssertFalse(type.contains("ClamshellLock"), "found: \(type)")
        }
    }

    func testTheSocketIsPrivateAndIsRemovedOnStop() throws {
        let path = NSTemporaryDirectory() + "lidwing-notify-\(UUID().uuidString).sock"
        let server = NotifyServer(socketPath: path) { _ in }
        XCTAssertTrue(server.start())

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o777, 0o600)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "a stale socket would make the next start fail")
    }

    func testAMessageDeliveredOverTheRealSocketArrives() throws {
        let path = NSTemporaryDirectory() + "lidwing-notify-live-\(UUID().uuidString).sock"
        let received = expectation(description: "signal delivered")
        var signal: NotifyServer.Signal?

        let server = NotifyServer(socketPath: path) { incoming in
            signal = incoming
            received.fulfill()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        let client = try XCTUnwrap(UnixSocket.connect(path: path))
        let payload = Data("{\"v\":1,\"src\":\"codex\",\"body\":\"waiting\"}\n".utf8)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        close(client)

        wait(for: [received], timeout: 5)
        XCTAssertEqual(signal?.source, "codex")
        XCTAssertEqual(signal?.body, "waiting")
    }
}
