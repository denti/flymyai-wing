import Foundation
import Darwin
import LidwingCore

/// The wire format on `control.sock`: newline-delimited JSON, version-tagged.
///
/// Deliberately tiny and deliberately versioned. The watchdog rejects what it does not
/// understand rather than guessing, because the thing it does on a guess is clear a bit that
/// controls whether somebody's Mac can sleep.
public enum ControlWire {
    public static func encode(_ message: ControlMessage, bootSession: String, pid: Int32) -> Data {
        var object: [String: Any] = ["v": lidwingControlProtocolVersion]
        switch message {
        case .armed(let boot, let armedPID):
            object["cmd"] = "armed"
            object["boot"] = boot
            object["pid"] = Int(armedPID)
        case .heartbeat(let date):
            object["cmd"] = "hb"
            object["t"] = date.timeIntervalSince1970.rounded()
        case .disarmed:
            object["cmd"] = "disarmed"
        }
        _ = bootSession
        _ = pid
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> ControlMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let version = object["v"] as? Int, version == lidwingControlProtocolVersion,
              let command = object["cmd"] as? String else { return nil }
        switch command {
        case "armed":
            guard let boot = object["boot"] as? String, let pid = object["pid"] as? Int
            else { return nil }
            return .armed(bootSession: boot, pid: Int32(pid))
        case "hb":
            let seconds = object["t"] as? Double ?? 0
            return .heartbeat(at: Date(timeIntervalSince1970: seconds))
        case "disarmed":
            return .disarmed
        default:
            return nil
        }
    }
}

/// A `AF_UNIX` `SOCK_STREAM` path, created with mode 0600.
public enum UnixSocket {

    public static func makeAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= maximum else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximum + 1) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(byte) }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    public static func connect(path: String) -> Int32? {
        guard var address = makeAddress(path: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, size)
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    public static func listen(path: String, backlog: Int32 = 4) -> Int32? {
        unlink(path)
        guard var address = makeAddress(path: path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, size)
            }
        }
        guard bound == 0 else {
            close(descriptor)
            return nil
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, backlog) == 0 else {
            close(descriptor)
            unlink(path)
            return nil
        }
        return descriptor
    }
}

/// The app's end of the dead-man connection.
///
/// The app is the **client**. That inversion is the whole design: when the app dies for any
/// reason, including `SIGKILL`, the kernel closes the socket and the watchdog sees EOF within
/// milliseconds. A heartbeat is only the secondary detector, for an app that is hung but alive.
public final class WatchdogClient: WatchdogLink {
    private var descriptor: Int32 = -1
    private let socketPath: String
    private let bootSession: String
    private let pid: Int32
    /// Called when the connection drops from our side, so the state machine can stand down.
    public var onDisconnect: (() -> Void)?
    /// Attempts to (re)launch the agent when a connection cannot be made.
    public var launchWatchdog: (() -> Bool)?

    private var readSource: DispatchSourceRead?

    public init(socketPath: String = SupportDirectory.file(LidwingID.controlSocketName).path,
                bootSession: String,
                pid: Int32) {
        self.socketPath = socketPath
        self.bootSession = bootSession
        self.pid = pid
    }

    deinit { disconnect() }

    public var isConnected: Bool { descriptor >= 0 }

    public func connect() -> Bool {
        if isConnected { return true }
        if let fd = UnixSocket.connect(path: socketPath) {
            attach(fd)
            return true
        }
        // No listener. Ask the host to bootstrap the agent, then try again for a moment.
        guard launchWatchdog?() == true else { return false }
        for _ in 0..<40 {                       // up to 2 s, 50 ms apart
            usleep(50_000)
            if let fd = UnixSocket.connect(path: socketPath) {
                attach(fd)
                return true
            }
        }
        return false
    }

    private func attach(_ fd: Int32) {
        descriptor = fd
        // SIGPIPE on a dead socket would kill the app. The whole point of this connection is
        // to make the app's death detectable, not to cause it.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = read(self.descriptor, &buffer, buffer.count)
            if count <= 0 {
                self.disconnect()
                self.onDisconnect?()
            }
        }
        source.resume()
        readSource = source
    }

    public func send(_ message: ControlMessage) {
        guard descriptor >= 0 else { return }
        let data = ControlWire.encode(message, bootSession: bootSession, pid: pid)
        _ = data.withUnsafeBytes { buffer -> Int in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    public func disconnect() {
        readSource?.cancel()
        readSource = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }
}
