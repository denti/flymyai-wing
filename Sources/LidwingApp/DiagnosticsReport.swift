import Foundation
import LidwingCore
import LidwingSystem

/// Read-only, copy-to-clipboard, no permissions required.
///
/// This is where Lidwing proves it is not lying: the literal before-and-after of the one bit it
/// touches, who else is holding the machine awake, and the last few sessions with their real
/// numbers. Every line here can be checked independently with a command the user can run.
///
/// Nothing user-identifying goes in. No home directory paths, no hostname, no serial numbers.
enum DiagnosticsReport {

    static func build(system: LiveSystem,
                      machine: StateMachine,
                      audit: FileAuditSink,
                      watchdogConnected: Bool,
                      soundWarning: String? = nil) -> String {
        var lines: [String] = []

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        lines.append("Lidwing \(version) (build \(build))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)  "
                     + "\(architecture())  \(hardwareModel())")
        lines.append("Method: Tier 1 (clamshell mask + idle assertion, no privileges)")
        // Always present, including when the answer is "untested". A support bundle is read by
        // somebody who cannot see the machine, and which Mac this has actually been proven on
        // is half the answer to most of what they will want to ask.
        let evidence = HardwareSupport.diagnosticsLine(model: hardwareModel(),
                                                       macOSMajor: macOSMajor(),
                                                       arch: architecture())
        lines.append("Evidence: \(evidence)")
        lines.append("")

        lines.append("Ground truth")
        lines.append("  AppleClamshellState        \(describe(system.lidStateRaw))")
        lines.append("  AppleClamshellCausesSleep  \(describe(system.clamshellCausesSleep))")
        lines.append("  SleepDisabled              \(describe(system.sleepDisabled))"
                     + "   (Lidwing never writes this)")
        lines.append("  DesktopMode                \(system.desktopMode ? "Yes" : "No")")
        lines.append("  Online displays            \(system.onlineDisplayCount)")
        lines.append("")

        lines.append("Lidwing")
        lines.append("  State                      \(machine.state.rawValue)")
        lines.append("  We set the clamshell bit   \(machine.weSetTheBit ? "yes" : "no")")
        lines.append("  Our idle assertion live    \(system.ourAssertionLive ? "yes" : "no")")
        lines.append("  Watchdog                   \(watchdogConnected ? "connected" : "not connected")")
        // The sound self-check. Present in every report, including when it is fine: a support
        // bundle is read by someone who cannot see the machine, and "sound: ok" is the line that
        // rules a whole theory out in one second.
        lines.append("  Sound                      \(soundWarning ?? "ok")")
        if let session = machine.session {
            lines.append("  Armed at                   \(iso(session.armedAt))")
            lines.append("  Re-asserts                 \(session.reasserts)")
            lines.append("  Sleeps observed            \(session.sleepFailureCount)")
        }
        lines.append("")

        let power = PowerSourceReader.read()
        let sample = PowerSample(onAC: power.onAC, current: power.current, max: power.max,
                                 warning: power.warning)
        lines.append("Power")
        lines.append("  Source                     \(power.onAC ? "AC" : "battery")")
        lines.append("  Charge                     "
                     + (sample.percentage.map { "\($0)%" } ?? "unknown"))
        if let watts = system.instantaneousWatts {
            lines.append("  Draw                       \(String(format: "%.1f", watts)) W")
        }
        lines.append("  Warning level              \(power.warning)")
        lines.append("  Thermal                    \(system.thermalState)")
        lines.append("")

        let holders = system.foreignAssertionHolders
        lines.append("Other processes holding this Mac awake")
        if holders.isEmpty {
            lines.append("  none")
        } else {
            for holder in holders {
                lines.append("  \(holder.name) (pid \(holder.pid))")
            }
        }
        lines.append("")

        lines.append("Recent sessions")
        let records = audit.recentRecords(limit: 3)
        if records.isEmpty {
            lines.append("  none yet")
        } else {
            for record in records {
                let duration = MenuPresenter.compactDuration(
                    Int(record.disarmedAt.timeIntervalSince(record.armedAt)))
                lines.append("  \(iso(record.armedAt))  \(duration)  reason=\(record.reason.rawValue)  "
                             + "minBatt=\(record.minBatteryPercent.map { "\($0)%" } ?? "?")  "
                             + "maxTherm=\(record.maxThermal)  reasserts=\(record.reasserts)  "
                             + "failures=\(record.failures.count)")
            }
        }
        lines.append("")
        lines.append("Check any of this yourself:")
        lines.append("  ioreg -r -c IOPMrootDomain -d 1 | grep -E 'Clamshell|SleepDisabled'")
        lines.append("  pmset -g assertions | grep -i lidwing")

        return lines.joined(separator: "\n")
    }

    private static func describe(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Yes"
        case .some(false): return "No"
        case .none: return "(absent)"
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// The macOS major version. `operatingSystemVersion` rather than the display string, which
    /// is localised and has been reformatted between releases.
    static func macOSMajor() -> Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static func hardwareModel() -> String {
        RootDomain.sysctlModel() ?? "unknown"
    }
}
