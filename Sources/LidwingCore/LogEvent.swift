import Foundation

/// The complete catalogue of things Lidwing writes to the system log.
///
/// It is a closed set, in the portable module, for two reasons. It can be tested — the field
/// names a support bundle is grepped for are asserted rather than remembered — and it makes the
/// privacy decision reviewable in one place instead of scattered across call sites.
///
/// **Level rule, non-negotiable: everything here is `.notice` or worse.** `log show` prints
/// only default-level messages unless `--info` or `--debug` is passed, and info and debug live
/// in a memory ring buffer that rolls. A line logged at `.info` is a line that will not be in
/// the bundle a user sends you, so if something matters it is `.notice`, and if it does not
/// matter it is not logged at all.
public struct LogEvent: Equatable, Sendable {

    public enum Level: String, Equatable, Sendable {
        case notice
        case error
        case fault
    }

    public let name: String
    public let level: Level
    /// Field names whose values are safe to record in the clear.
    ///
    /// OSLog redacts dynamic string interpolation by default, which is a feature: the OS
    /// enforces the privacy story rather than a scrubber we wrote. Marking a field public is a
    /// deliberate act, and the allowlist below is short on purpose — enums, integers, versions
    /// and error codes. Nothing path-like, nothing user-derived, nothing from another tool.
    public let publicFields: [String]

    public init(name: String, level: Level, publicFields: [String]) {
        self.name = name
        self.level = level
        self.publicFields = publicFields
    }
}

public enum LogCatalogue {
    public static let subsystem = LidwingID.bundleID

    public enum Category: String, CaseIterable, Sendable {
        case lifecycle
        case power
        case ledger
        case watchdog
        case thermal
        case integrations
        case uninstall
    }

    // MARK: lifecycle

    public static let launch = LogEvent(
        name: "launch", level: .notice,
        publicFields: ["version", "build", "os", "arch", "state"])
    /// macOS changed since the last arm that verified the mechanism. Recorded even if the user
    /// never arms again, because this is the line that explains a support report six weeks later.
    public static let osChanged = LogEvent(
        name: "os_changed", level: .notice,
        publicFields: ["from", "to"])
    /// An arm verified against ground truth on the new build. The selector still works here.
    public static let osRecheckPassed = LogEvent(
        name: "os_recheck_passed", level: .notice,
        publicFields: ["from", "to"])
    /// Every state transition, so a support log answers "did it arm, refuse, or die" without
    /// anybody guessing. The automatic arm at launch used to log nothing at all: `armRequested`
    /// was emitted only from the menu handler, so the path that now runs on every launch left no
    /// trace unless it happened to be refused.
    public static let stateChanged = LogEvent(
        name: "state_changed", level: .notice,
        publicFields: ["from", "to"])
    /// Which route installed the watchdog, or why none did. Without this there is no way to tell
    /// a Mac with no LaunchAgent from a Mac where installing one failed, and the difference is
    /// the whole reason an arm gets refused.
    public static let watchdogInstall = LogEvent(
        name: "watchdog_install", level: .notice,
        publicFields: ["route", "ok", "reason"])
    public static let reconciled = LogEvent(
        name: "reconciled", level: .notice,
        publicFields: ["decision", "cause"])
    public static let terminating = LogEvent(
        name: "terminating", level: .notice,
        publicFields: ["state", "reason"])

    // MARK: power — the events that answer "did Lidwing break my Mac's sleep?"

    public static let armRequested = LogEvent(
        name: "arm.requested", level: .notice,
        publicFields: ["mode", "onAC", "battery", "thermal", "displays"])
    public static let armRefused = LogEvent(
        name: "arm.refused", level: .notice,
        publicFields: ["reason"])
    public static let armApplied = LogEvent(
        name: "arm.applied", level: .notice,
        publicFields: ["mechanism", "ioreturn"])
    public static let armVerified = LogEvent(
        name: "arm.verified", level: .notice,
        publicFields: ["elapsedMs", "causesSleep"])
    /// The write returned success and the machine did not change. Both mechanisms in this
    /// product can do that, which is why this is an error and not a debug line.
    public static let armNoEffect = LogEvent(
        name: "arm.no-effect", level: .error,
        publicFields: ["elapsedMs", "causesSleep"])
    public static let reasserted = LogEvent(
        name: "reassert", level: .notice,
        publicFields: ["trigger", "count"])
    public static let disarmed = LogEvent(
        name: "disarm", level: .notice,
        publicFields: ["reason", "durationS", "minBattery", "maxThermal", "reasserts"])
    public static let releaseNoEffect = LogEvent(
        name: "disarm.no-effect", level: .error,
        publicFields: ["causesSleep"])
    /// Invariant I5. There is no benign case, so there is no level below error for it.
    public static let sleptWhileArmed = LogEvent(
        name: "slept-while-armed", level: .fault,
        publicFields: ["lid", "onAC", "displays", "thermal"])
    public static let groundTruthLost = LogEvent(
        name: "ground-truth-lost", level: .error,
        publicFields: ["causesSleep", "ageS"])

    // MARK: guards

    public static let thermalState = LogEvent(
        name: "thermal", level: .notice,
        publicFields: ["state", "action"])
    public static let batteryGuard = LogEvent(
        name: "battery", level: .notice,
        publicFields: ["percent", "warning", "action"])

    // MARK: watchdog and ledger

    public static let watchdogConnected = LogEvent(
        name: "watchdog.connected", level: .notice,
        publicFields: ["pid"])
    public static let watchdogLost = LogEvent(
        name: "watchdog.lost", level: .error,
        publicFields: ["action"])
    public static let watchdogRecovered = LogEvent(
        name: "watchdog.recovered", level: .error,
        publicFields: ["trigger", "atUnix"])
    public static let ledgerWritten = LogEvent(
        name: "ledger.written", level: .notice,
        publicFields: ["boot", "weSetBit"])
    public static let ledgerWriteFailed = LogEvent(
        name: "ledger.write-failed", level: .error,
        publicFields: ["errno"])

    // MARK: third-party files

    /// The advisory notify socket could not be created, so hook notifications will never
    /// arrive. Not fatal - nothing about protection depends on it - but never silent.
    public static let notifyServerUnavailable = LogEvent(
        name: "notify_server_unavailable", level: .error,
        publicFields: [])
    public static let integrationInstalled = LogEvent(
        name: "integration.installed", level: .notice,
        publicFields: ["agent", "chained"])
    public static let integrationRemoved = LogEvent(
        name: "integration.removed", level: .notice,
        publicFields: ["agent"])
    public static let integrationRefused = LogEvent(
        name: "integration.refused", level: .error,
        publicFields: ["agent", "reason"])

    public static let uninstallComplete = LogEvent(
        name: "uninstall.complete", level: .notice,
        publicFields: ["succeeded", "residue"])

    public static let all: [LogEvent] = [
        launch, osChanged, osRecheckPassed, reconciled, terminating, stateChanged,
        watchdogInstall,
        armRequested, armRefused, armApplied, armVerified, armNoEffect,
        reasserted, disarmed, releaseNoEffect, sleptWhileArmed, groundTruthLost,
        thermalState, batteryGuard,
        watchdogConnected, watchdogLost, watchdogRecovered,
        ledgerWritten, ledgerWriteFailed,
        notifyServerUnavailable, integrationInstalled, integrationRemoved, integrationRefused,
        uninstallComplete
    ]

    /// The command printed in the diagnostics panel and in the docs.
    ///
    /// `BEGINSWITH` rather than `==` so it catches the watchdog's subsystem too. Deliberately
    /// no `--info --debug`: if a line is missing from a support bundle, the fix is to raise its
    /// level in the source, not to widen the query and hope.
    public static let showCommand =
        "log show --predicate 'subsystem BEGINSWITH \"ai.flymy.lidwing\"' --last 2h"
}
