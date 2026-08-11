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

// Every decision this process makes lives in `WatchdogPolicy`, in the portable module, where
// it is unit-tested. What is left here is sockets, IOKit and files.

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

    /// What the watchdog currently knows, in the shape the policy takes.
    func observation() -> WatchdogPolicy.Observation {
        WatchdogPolicy.Observation(isWatching: isWatching,
                                   hasClient: clientDescriptor >= 0,
                                   lastHeartbeat: lastHeartbeat,
                                   now: Date(),
                                   desktopMode: RootDomain.desktopMode,
                                   onAC: PowerSourceReader.read().onAC)
    }

    /// Carries out whatever the policy decided. The decision itself is not made here.
    func apply(_ action: WatchdogPolicy.Action) {
        switch action {
        case .idle:
            return

        case .deleteStaleMarker:
            log("stale marker from a previous boot; the mask self-cleared, deleting")
            clearMarker()
            armedBootSession = nil
            appPID = nil

        case .standDown(let trigger):
            // Invariant I7: powerd legitimately owns the clamshell state in this
            // configuration, and clearing it would sleep somebody else's lid-closed machine.
            log("standing down (\(trigger.rawValue)): powerd owns the clamshell state here")
            writeRecoveredRecord(reason: "stood_down_" + trigger.rawValue)
            armedBootSession = nil
            appPID = nil
            clearMarker()

        case .recover(let trigger):
            log("recovering (\(trigger.rawValue))")
            if lock.open() {
                let result = lock.set(false)
                log("cleared clamshell bit, kr=0x\(String(UInt32(bitPattern: result), radix: 16))")
                let after = RootDomain.clamshellCausesSleep
                log("AppleClamshellCausesSleep after clear: "
                    + (after.map(String.init(describing:)) ?? "absent"))
            } else {
                log("FAILED to open IOPMrootDomain user client; cannot clear")
            }
            writeRecoveredRecord(reason: trigger.rawValue)
            notifyUser()
            armedBootSession = nil
            appPID = nil
            clearMarker()
        }
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
            apply(WatchdogPolicy.onEOF(observation()))
            retireIfThereIsNothingLeftToGuard()
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

    /// Exits once the app is gone and the machine is stock again.
    ///
    /// A watchdog with no client is not guarding anything, and a process that outlives the app
    /// it belongs to is exactly what a user sees as "this thing left something running". After
    /// the launch crash on a real Mac, `lidwingd` was still there afterwards with nothing to do.
    ///
    /// It only leaves when the machine is provably back to stock. If ground truth is still
    /// non-stock the job is unfinished - so it stays, keeps trying, and launchd keeps it alive
    /// if it dies in the attempt. The plist's `SuccessfulExit: false` is the other half of this:
    /// a clean exit here means "done", and launchd honours it.
    private func retireIfThereIsNothingLeftToGuard() {
        guard clientDescriptor < 0 else { return }
        // Ground truth, read fresh. `AppleClamshellCausesSleep == false` means somebody still
        // has this Mac held awake on lid close; `nil` means the key is absent, which is the
        // ordinary state of a machine where it has never been set.
        guard RootDomain.clamshellCausesSleep != false else {
            log("staying: the machine is not stock and there is no client to fix it")
            return
        }
        log("retiring: no client, and the machine is stock")
        exit(0)
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
        let action = WatchdogPolicy.tick(observation())
        if case .recover(.heartbeatLost) = action { dropClient() }
        apply(action)
    }

    /// RunAtLoad path: a marker from *this* boot with no app connecting means the app died and
    /// took us with it, or the machine restarted us. A marker from a previous boot is stale
    /// and harmless — the kernel initialises the mask to zero at boot — so it is deleted, not
    /// acted on.
    func reconcileAtStartup() {
        let marker = Watchdog.readMarker()
        let action = WatchdogPolicy.atStartup(markerBootSession: marker?.boot,
                                              currentBootSession: RootDomain.bootSessionUUID)
        guard let marker else { return }
        if case .deleteStaleMarker = action {
            armedBootSession = marker.boot
            apply(action)
            return
        }
        let grace = Int(WatchdogPolicy.orphanGrace)
        log("marker from this boot (pid \(marker.pid)); waiting \(grace)s for the app")
        armedBootSession = marker.boot
        appPID = marker.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + WatchdogPolicy.orphanGrace) { [weak self] in
            guard let self, self.isWatching, self.clientDescriptor < 0 else { return }
            self.apply(WatchdogPolicy.onEOF(self.observation()))
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
// Exactly one watchdog, and the first one wins.
//
// This matters now that the app spawns `lidwingd` as a plain child rather than registering a
// launchd agent - launchd guaranteed a single copy and nothing else does. `UnixSocket.listen`
// unlinks the socket path before binding, so a second instance would quietly steal the socket
// from the first and leave an orphan watching nothing. The app can call for a watchdog more than
// once in a session, so this is reachable rather than theoretical.
//
// A failure to create the lock file is deliberately not fatal: no dead-man at all is worse than
// a small risk of two.
let lockPath = SupportDirectory.file("lidwingd.lock").path
let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
    log("another watchdog already holds the lock; leaving it to run")
    exit(0)
}

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
        // If we are still watching at this point, the app is not going to get another chance
        // to clean up after itself.
        watchdog.apply(WatchdogPolicy.onEOF(watchdog.observation()))
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
