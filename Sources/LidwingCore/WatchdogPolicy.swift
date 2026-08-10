import Foundation

/// The dead man's decision logic, separated from its sockets so it can be tested.
///
/// This is the most safety-critical code in the product and it used to live inside a
/// Darwin-only executable where no test could reach it. Everything here is a pure function of
/// what the watchdog has observed; the process around it does sockets and IOKit and nothing
/// else.
public struct WatchdogPolicy: Equatable, Sendable {

    /// Seconds of silence from a connected app before it is assumed wedged. The heartbeat is
    /// the *secondary* detector — EOF is the primary one and arrives in milliseconds — so this
    /// is deliberately generous. A five-second deadline would kill an overnight run the first
    /// time a CPU-saturated build stalls a run loop.
    public static let heartbeatDeadline: TimeInterval = 15
    /// At `RunAtLoad`, how long to wait for the app to connect before a marker from this boot
    /// counts as evidence that it died.
    public static let orphanGrace: TimeInterval = 10

    public enum Trigger: String, Equatable, Sendable {
        case appDied = "app_died"
        case heartbeatLost = "heartbeat_lost"
        case noClient = "no_client"
        case orphanAtStartup = "orphan_at_startup"
        case watchdogTerminating = "watchdog_terminating"
    }

    public enum Action: Equatable, Sendable {
        /// Nothing to do.
        case idle
        /// Clear the bit and tell the user.
        case recover(Trigger)
        /// The machine is in a configuration where powerd legitimately owns the clamshell
        /// state. Record it and stand down — clearing here would sleep somebody else's
        /// lid-closed Mac in the middle of their work (invariant I7).
        case standDown(Trigger)
        /// A marker from a previous boot. The kernel already cleared the mask at boot, so the
        /// file is stale rather than dangerous: delete it and say nothing.
        case deleteStaleMarker
    }

    /// What the watchdog knows.
    public struct Observation: Equatable, Sendable {
        public var isWatching: Bool
        public var hasClient: Bool
        public var lastHeartbeat: Date
        public var now: Date
        public var desktopMode: Bool
        public var onAC: Bool

        public init(isWatching: Bool, hasClient: Bool, lastHeartbeat: Date, now: Date,
                    desktopMode: Bool, onAC: Bool) {
            self.isWatching = isWatching
            self.hasClient = hasClient
            self.lastHeartbeat = lastHeartbeat
            self.now = now
            self.desktopMode = desktopMode
            self.onAC = onAC
        }
    }

    /// The periodic check.
    public static func tick(_ observation: Observation) -> Action {
        guard observation.isWatching else { return .idle }
        if !observation.hasClient {
            return gate(.noClient, observation)
        }
        if observation.now.timeIntervalSince(observation.lastHeartbeat) > heartbeatDeadline {
            return gate(.heartbeatLost, observation)
        }
        return .idle
    }

    /// The connection dropped. This is the primary signal: the app is the client, so its death
    /// by any means — including `SIGKILL`, which runs no handler anywhere — closes the socket.
    public static func onEOF(_ observation: Observation) -> Action {
        guard observation.isWatching else { return .idle }
        return gate(.appDied, observation)
    }

    /// `RunAtLoad`, with a marker file on disk.
    ///
    /// A marker from a previous boot is harmless: `clamshellSleepDisableMask` is a kernel
    /// variable initialised to zero in `IOPMrootDomain::start()`, so a restart has already
    /// undone whatever it recorded. Acting on it would mean writing to the machine for no
    /// reason at every boot.
    public static func atStartup(markerBootSession: String?,
                                 currentBootSession: String) -> Action {
        guard let marker = markerBootSession else { return .idle }
        guard marker == currentBootSession else { return .deleteStaleMarker }
        // The caller waits `orphanGrace` and then calls `tick` with `hasClient: false`.
        return .idle
    }

    /// Invariant I7, applied identically here and in the app. Bit `0x02` is shared with powerd
    /// and carries no reference count.
    private static func gate(_ trigger: Trigger, _ observation: Observation) -> Action {
        if observation.desktopMode && observation.onAC {
            return .standDown(trigger)
        }
        return .recover(trigger)
    }
}
