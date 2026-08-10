// lidwingd — the dead man's switch.
//
// Why this process exists at all: `RootDomainUserClient::clientClose()` only calls
// `terminate()`. **Nothing in the kernel clears `clamshellSleepDisableMask` when the process
// that set it dies.** A `kill -9`, a jetsam kill or a crash would otherwise leave the user's
// Mac unable to sleep on lid close until the next reboot, with no UI left to explain why.
// Amphetamine ships this as a separate optional download called "Amphetamine Enhancer"; ours
// is not optional and not visible.
//
// It is an ordinary unprivileged LaunchAgent. Any process can call selector 12, so there is no
// admin prompt, no daemon, and no privilege anywhere in this design.
//
// Detection is by EOF, not by heartbeat. The app *connects* to us; when it dies for any
// reason the kernel closes the socket and we find out in milliseconds. The 5-second heartbeat
// is only the secondary detector, for an app that is hung but still alive.

import Foundation
import Darwin
import LidwingCore
import LidwingSystem

/// Seconds of silence from a connected app before we assume it is wedged.
let heartbeatDeadline: TimeInterval = 15
/// At RunAtLoad, how long we wait for the app to reconnect before treating a stale marker as
/// evidence that it died.
let orphanGrace: TimeInterval = 10

let socketPath = SupportDirectory.file(LidwingID.controlSocketName).path
let markerPath = SupportDirectory.file("armed.json").path
let recoveredPath = SupportDirectory.file("recovered.json").path

// MARK: - State

final class Watchdog {
    private let lock = ClamshellLock()
    private var armedBootSession: String?
    private var appPID: Int32?
    private var lastHeartbeat = Date()
    private var clientDescriptor: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var pending = Data()

    var isWatching: Bool { armedBootSession != nil }

    // MARK: marker file

    /// The marker survives our own death as well as the app's, which is what makes the
    /// RunAtLoad path meaningful.
    private func writeMarker(bootSession: String, pid: Int32) {
        SupportDirectory.ensure()
        let payload: [String: Any] = ["boot": bootSession, "pid": Int(pid),
                                      "at": Date().timeIntervalSince1970.rounded()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        chmod(markerPath, 0o600)
    }

    private func clearMarker() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    static func readMarker() -> (boot: String, pid: Int32)? {
        guard let data = FileManager.default.contents(atPath: markerPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boot = object["boot"] as? String else { return nil }
        return (boot, Int32(object["pid"] as? Int ?? 0))
    }

    // MARK: recovery

    /// Clear the bit, but only under the same rule the app itself obeys.
    ///
    /// Invariant I7: bit 0x02 is shared with powerd and carries no reference count. Clearing it
    /// where powerd legitimately wants it set — an external display on AC — would sleep
    /// somebody else's lid-closed machine mid-operation. An unconditional clear here would be
    /// the watchdog causing exactly the class of harm it exists to prevent.
    func recover(reason: String) {
        guard isWatching else { return }
        let onAC = PowerSourceReader.read().onAC
        let desktop = RootDomain.desktopMode
        log("recovering (\(reason)); desktopMode=\(desktop) onAC=\(onAC)")

        if desktop && onAC {
            log("standing down: powerd legitimately owns the clamshell state in this configuration")
        } else if lock.open() {
            let result = lock.set(false)
            log("cleared clamshell bit, kr=0x\(String(UInt32(bitPattern: result), radix: 16))")
            let after = RootDomain.clamshellCausesSleep
            log("AppleClamshellCausesSleep after clear: \(after.map(String.init(describing:)) ?? "absent")")
        } else {
            log("FAILED to open IOPMrootDomain user client; cannot clear")
        }

        writeRecoveredRecord(reason: reason)
        notifyUser()
        armedBootSession = nil
        appPID = nil
        clearMarker()
    }

    /// The app reads this at its next launch and tells the user exactly what happened and
    /// when. The file is the authoritative channel; the banner below is a courtesy.
    private func writeRecoveredRecord(reason: String) {
        SupportDirectory.ensure()
        let payload: [String: Any] = ["at": Date().timeIntervalSince1970.rounded(),
                                      "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: recoveredPath), options: .atomic)
        chmod(recoveredPath, 0o600)
    }

    private func notifyUser() {
        // Best effort only, and never load-bearing. A LaunchAgent with no bundle cannot use
        // UNUserNotificationCenter, and the honest alternative is a one-shot AppleScript
        // banner. If it fails, the record on disk still reaches the user at the next launch.
        let script = "display notification "
            + "\"Lidwing quit unexpectedly. Lid-close sleep has been restored.\" "
            + "with title \"Lidwing\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    // MARK: client handling

    func accept(_ descriptor: Int32) {
        if clientDescriptor >= 0 {
            // Only one app at a time. A second connection means a second instance, which the
            // app's own single-instance lock should have prevented; refuse rather than get
            // confused about who owns the bit.
            log("refusing a second client")
            close(descriptor)
            return
        }
        clientDescriptor = descriptor
        lastHeartbeat = Date()
        pending.removeAll()

        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.clientDescriptor >= 0 { close(self.clientDescriptor) }
            self.clientDescriptor = -1
        }
        source.resume()
        clientSource = source
        log("client connected")
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(clientDescriptor, &buffer, buffer.count)
        if count <= 0 {
            // EOF. This is the primary signal, and it is the reason the app is the client.
            log("client EOF")
            dropClient()
            if isWatching { recover(reason: "app_died") }
            return
        }
        pending.append(contentsOf: buffer[0..<count])
        // Bound the buffer: a peer that never sends a newline must not grow our memory.
        if pending.count > 64 * 1024 { pending.removeAll() }

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let message = ControlWire.decode(line) else {
            log("ignoring an unrecognised message")
            return
        }
        switch message {
        case .armed(let boot, let pid):
            armedBootSession = boot
            appPID = pid
            lastHeartbeat = Date()
            writeMarker(bootSession: boot, pid: pid)
            log("watching pid \(pid), boot \(boot)")
        case .heartbeat:
            lastHeartbeat = Date()
        case .disarmed:
            log("clean disarm")
            armedBootSession = nil
            appPID = nil
            clearMarker()
        }
    }

    private func dropClient() {
        clientSource?.cancel()
        clientSource = nil
    }

    // MARK: the slow check

    func tick() {
        guard isWatching else { return }
        if clientDescriptor < 0 {
            recover(reason: "no_client")
            return
        }
        if Date().timeIntervalSince(lastHeartbeat) > heartbeatDeadline {
            log("heartbeat deadline exceeded")
            dropClient()
            recover(reason: "heartbeat_lost")
        }
    }

    /// RunAtLoad path: a marker from *this* boot with no app connecting means the app died and
    /// took us with it, or the machine restarted us. A marker from a previous boot is stale
    /// and harmless — the kernel initialises the mask to zero at boot — so it is deleted, not
    /// acted on.
    func reconcileAtStartup() {
        guard let marker = Watchdog.readMarker() else { return }
        let currentBoot = RootDomain.bootSessionUUID
        guard marker.boot == currentBoot else {
            log("stale marker from a previous boot; the mask self-cleared, deleting")
            clearMarker()
            return
        }
        log("marker from this boot found (pid \(marker.pid)); waiting \(Int(orphanGrace))s for the app")
        armedBootSession = marker.boot
        appPID = marker.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + orphanGrace) { [weak self] in
            guard let self, self.isWatching, self.clientDescriptor < 0 else { return }
            self.recover(reason: "orphan_at_startup")
        }
    }
}

// MARK: - Logging
//
// stderr only, which launchd routes to the agent's log file. Nothing here is at `.info` or
// `.debug`: everything this process says is something a user might need to read back.

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] lidwingd: \(message)\n".utf8))
}

// MARK: - Main

SupportDirectory.ensure()

let watchdog = Watchdog()
watchdog.reconcileAtStartup()

guard let listener = UnixSocket.listen(path: socketPath) else {
    log("FATAL: cannot listen on \(socketPath)")
    exit(1)
}
log("listening on \(socketPath)")

let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
acceptSource.setEventHandler {
    let descriptor = accept(listener, nil, nil)
    guard descriptor >= 0 else { return }
    watchdog.accept(descriptor)
}
acceptSource.resume()

// One repeating timer, five seconds, with generous leeway. An app that promises to save your
// battery must not appear in Activity Monitor's Energy tab.
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
ticker.setEventHandler { watchdog.tick() }
ticker.resume()

// launchd stops an agent with SIGTERM. Recover first: if we are still watching at that point,
// the app is not going to get another chance to clean up after itself.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("signal \(sig)")
        watchdog.recover(reason: "watchdog_terminating")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
