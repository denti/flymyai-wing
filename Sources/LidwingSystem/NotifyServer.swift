import Foundation
import Darwin
import LidwingCore

/// The receiving end of `lidwing-notify`.
///
/// **Invariant I8: nothing arriving on this socket can arm anything.** Its only permitted
/// effects are a sound, a user notification, and the "your agent is waiting" indicator in the
/// menu. That is enforced here by construction: this type has no reference to the state
/// machine and no way to reach it.
///
/// Every byte that arrives is untrusted text written by somebody else's tool. It is never
/// rendered as markup, never executed, never used to decide anything privileged, and it is
/// truncated before it goes anywhere near a notification.
public final class NotifyServer {

    /// What a message is allowed to say. Anything else in the payload is discarded.
    public struct Signal: Equatable, Sendable {
        /// Which tool sent it: `claude`, `codex`, or `hook`.
        public let source: String
        /// Truncated, stripped of control characters, and safe to display as plain text.
        public let body: String

        public init(source: String, body: String) {
            self.source = source
            self.body = body
        }
    }

    public static let maximumBodyLength = 200

    private let socketPath: String
    private let handler: (Signal) -> Void
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [DispatchSourceRead] = []

    public init(socketPath: String = SupportDirectory.file(LidwingID.notifySocketName).path,
                handler: @escaping (Signal) -> Void) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        SupportDirectory.ensure()
        guard let descriptor = UnixSocket.listen(path: socketPath, backlog: 8) else { return false }
        listener = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        acceptSource = source
        return true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for client in clientSources { client.cancel() }
        clientSources.removeAll()
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(socketPath)
    }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }

        // A hook helper writes one short line and closes. Anything that does not is not a
        // conversation we are interested in having.
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        var buffer = Data()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = read(client, &chunk, chunk.count)
            if count <= 0 {
                source.cancel()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            // Bound the buffer: a peer that never sends a newline must not grow our memory.
            if buffer.count > 8 * 1024 {
                source.cancel()
                return
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let signal = NotifyServer.parse(line) {
                    self.handler(signal)
                }
            }
        }
        source.setCancelHandler {
            close(client)
        }
        source.resume()
        clientSources.append(source)
        clientSources.removeAll { $0.isCancelled }
    }

    /// Parses one line, keeping only the two fields that are allowed to have any effect.
    ///
    /// Pure and `static` so it can be tested without a socket, and so its refusal behaviour is
    /// visible rather than buried in an event handler.
    public static func parse(_ line: Data) -> Signal? {
        guard line.count <= 8 * 1024,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let version = object["v"] as? Int, version == 1 else { return nil }

        let source = (object["src"] as? String) ?? "hook"
        let allowedSources = ["claude", "codex", "hook"]
        let safeSource = allowedSources.contains(source) ? source : "hook"

        let raw = (object["body"] as? String) ?? ""
        return Signal(source: safeSource, body: sanitise(raw))
    }

    /// Strips control characters and truncates. The result is displayed as plain text and
    /// nothing else; it never reaches a shell, a web view or an attributed string.
    static func sanitise(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            guard output.count < maximumBodyLength else { break }
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            output.unicodeScalars.append(scalar)
        }
        return output.trimmingCharacters(in: .whitespaces)
    }
}
