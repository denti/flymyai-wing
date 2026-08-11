import Foundation
import AppKit
import ServiceManagement
import LidwingCore
import LidwingSystem

/// Gets `lidwingd` running, without ever asking for a password.
///
/// Any process can call selector 12, so the dead-man needs no privilege at all. That is the
/// whole reason this is a user LaunchAgent and not a daemon, and it is why installing it
/// produces no dialog.
///
/// Two paths, tried in order:
///
/// 1. **`SMAppService.agent`** on macOS 13+. The modern, visible-in-System-Settings route.
///    It requires a properly signed bundle and returns `kSMErrorInvalidSignature` otherwise,
///    which is exactly the situation an ad-hoc development build is in.
/// 2. **`launchctl bootstrap gui/$UID`** with a plist in `~/Library/LaunchAgents`. The
///    documented pre-13 route, and the fallback whenever the first one cannot work.
///
/// The fallback is not a workaround for a signing problem we should be fixing — it is the only
/// mechanism that exists on macOS 12, which is this product's floor.
enum WatchdogInstaller {

    static var agentPlistName: String { "\(LidwingID.watchdogLabel).plist" }

    /// The watchdog binary. Inside a built `.app` it sits in `Contents/Resources`; during
    /// development it sits beside the executable.
    static func watchdogExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("lidwingd"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lidwingd")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// App Translocation check.
    ///
    /// A quarantined app launched from `~/Downloads` runs from a randomised, read-only
    /// `/private/var/folders/.../AppTranslocation/<UUID>/d/` path. Any launchd plist recording
    /// that path breaks the moment the app quits, and the user is left with a watchdog that
    /// points at a mount that no longer exists.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// Whether the app is somewhere a launchd agent can point at for the life of a session.
    ///
    /// Two places are genuinely broken: a **translocated** bundle, which runs from a randomised
    /// read-only mount that evaporates when the app quits, and `~/Downloads`, which is where a
    /// still-quarantined app lives right before it becomes translocated on the next launch. A
    /// plist recording either path is a watchdog pointing at nothing.
    ///
    /// Deliberately **not** a requirement to live in `/Applications`. Apple recommends it, and
    /// for a *daemon* that has to run before login it is a hard requirement — but this is a
    /// user agent, and `~/Applications` is a perfectly ordinary place for someone to keep an
    /// app. Refusing to work there would be us enforcing a rule that does not apply to us.
    static var isInAStablePlace: Bool {
        !isTranslocated && !Bundle.main.bundleURL.path.contains("/Downloads/")
    }

    @discardableResult
    static func ensureRunning() -> Bool {
        ensureRunningReportingRoute().ok
    }

    /// What happened when Lidwing tried to bring the watchdog up.
    struct InstallOutcome {
        let ok: Bool
        /// `SMAppService`, `launchctl`, or `none`.
        let route: String
        /// Empty when it worked by the preferred route and there is nothing to explain.
        let reason: String
    }

    /// Starts `lidwingd` as a plain child process.
    ///
    /// This is the route that actually works, and it is a simplification rather than a
    /// workaround. `SMAppService.agent` registration fails on an ad-hoc signed build with no
    /// Team ID - on a real Mac, `launchctl print gui/501/ai.flymy.lidwing.watchdog` answered
    /// "Could not find service in domain", no agent was ever registered, and every arm was
    /// refused with "could not start its safety watchdog". A product that cannot work at all
    /// until an Apple Developer Program enrolment completes is not a product.
    ///
    /// A child process needs no registration, no code-signing identity and no Login Items
    /// approval. It works on an ad-hoc build and on every macOS from the deployment floor up.
    /// The dead-man design is unchanged and unaffected: the app is the *client* on the control
    /// socket, so any death - crash, `kill -9`, force quit - closes the socket and the watchdog
    /// sees EOF in milliseconds. That is what covers the real risk.
    ///
    /// What launchd was for was boot-time recovery, and that guards a state which cannot exist:
    /// `clamshellSleepDisableMask` is initialised to 0 in `IOPMrootDomain::start()`, so a reboot
    /// always clears the bit. `DESIGN.md` §2 calls that asymmetry "the whole argument" for this
    /// tier. A restorer that runs at boot is guarding against something a boot already fixed.
    static func spawnAsChild() -> InstallOutcome {
        guard let executable = watchdogExecutableURL() else {
            return InstallOutcome(ok: false, route: "none",
                                  reason: "lidwingd is not in the bundle")
        }
        let task = Process()
        task.executableURL = executable
        // No pipes: the control socket is the channel, and a pipe nobody drains would fill and
        // block the watchdog at exactly the wrong moment.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            return InstallOutcome(ok: true, route: "child", reason: "")
        } catch {
            return InstallOutcome(ok: false, route: "none",
                                  reason: "could not start lidwingd: \(error.localizedDescription)")
        }
    }

    /// The same thing, but it says which route was taken and why the others were not.
    ///
    /// A user's Mac had no LaunchAgent, no `lidwingd`, and every arm refused - and there was no
    /// way to tell whether installation had been attempted and failed, or never attempted at
    /// all. The two have completely different fixes, and the log said nothing about either.
    static func ensureRunningReportingRoute() -> InstallOutcome {
        guard !isTranslocated else {
            return InstallOutcome(ok: false, route: "none",
                                  reason: "running from a translocated read-only mount")
        }
        guard isInAStablePlace else {
            return InstallOutcome(ok: false, route: "none",
                                  reason: "the app is somewhere a launchd agent cannot point at")
        }
        if registerWithServiceManagement() {
            return InstallOutcome(ok: true, route: "SMAppService", reason: "")
        }
        if bootstrapWithLaunchctl() {
            // Expected on an ad-hoc signed build: SMAppService returns kSMErrorInvalidSignature
            // without a Developer ID, and this is the documented pre-13 route.
            return InstallOutcome(ok: true, route: "launchctl",
                                  reason: "SMAppService declined; used the documented fallback")
        }
        return InstallOutcome(ok: false, route: "none",
                              reason: "both SMAppService and launchctl bootstrap failed")
    }

    private static func registerWithServiceManagement() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        // Only meaningful for a real bundle: the plist has to be inside
        // Contents/Library/LaunchAgents for SMAppService to find it.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let service = SMAppService.agent(plistName: agentPlistName)
        if service.status == .enabled { return true }
        do {
            try service.register()
            return service.status == .enabled || service.status == .requiresApproval
        } catch {
            // kSMErrorInvalidSignature on an ad-hoc build lands here, and it is expected
            // during development. Fall through to launchctl rather than failing to protect.
            return false
        }
    }

    private static func bootstrapWithLaunchctl() -> Bool {
        guard let executable = watchdogExecutableURL() else { return false }
        let agentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agentsDirectory,
                                                 withIntermediateDirectories: true)
        let plistURL = agentsDirectory.appendingPathComponent(agentPlistName)

        let plist: [String: Any] = [
            "Label": LidwingID.watchdogLabel,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardErrorPath": SupportDirectory.file("lidwingd.log").path
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .xml, options: 0) else {
            return false
        }
        // Rewrite unconditionally: the path changes when the app moves, and a plist pointing
        // at a binary that is no longer there is a watchdog that silently does not exist.
        try? data.write(to: plistURL, options: .atomic)

        let uid = getuid()
        // `bootout` first so an updated plist is actually picked up. launchd does not reload a
        // changed plist on its own, and the failure is silent.
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(LidwingID.watchdogLabel)"])
        let bootstrapped = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if !bootstrapped {
            // Very old path, still present, and harmless if the modern one already worked.
            run("/bin/launchctl", ["load", "-w", plistURL.path])
        }
        return true
    }

    /// Remove every trace. Called by the uninstaller and by a failed install, so it must be
    /// safe to run when nothing is installed.
    static func remove() {
        if #available(macOS 13.0, *), Bundle.main.bundleURL.pathExtension == "app" {
            try? SMAppService.agent(plistName: agentPlistName).unregister()
        }
        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(LidwingID.watchdogLabel)"])
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentPlistName)")
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
