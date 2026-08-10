import Foundation

/// What this build has actually been proven on, and what it says when it finds something else.
///
/// The constraint, in the owner's words: *"но макбуков много разных помни это"* — there are many
/// different MacBooks. One green run on one Apple Silicon laptop is not evidence for the fleet.
/// Intel and Apple Silicon, M1 through M4, Air and Pro, fanless and fanned, notch and no notch,
/// T2 Macs, and every macOS from the deployment floor upwards behave differently: the powerd
/// stomp, the thermal behaviour and the menu bar all vary.
///
/// So the list below is **evidence, not intent**. A machine is in it because a run happened and
/// its output is in this repository. Nothing is added because it "should work" — the whole
/// reason this type exists is that "should work" is what a compatibility table usually means.
///
/// The default answer is therefore `untested`, and untested is said out loud rather than
/// implied by silence. That is deliberately the common case today: exactly one Mac has ever run
/// the mechanism, for twelve seconds.
public enum HardwareSupport {

    /// How much is actually known about a given machine.
    public enum Level: Equatable, Sendable {
        /// A full acceptance run went green here: the mechanism, the guards, the packaging, the
        /// uninstall. This is what the README is allowed to list.
        case accepted(evidence: String)
        /// The mechanism itself has been seen working here, but not the full acceptance run.
        /// Better than nothing and worse than accepted, and it says which.
        case mechanismSeen(evidence: String)
        /// Nobody has ever run Lidwing on this combination. Not a prediction of failure - a
        /// statement that there is no evidence either way.
        case untested
    }

    /// One machine, one macOS, one architecture, and the run that proves it.
    public struct Record: Equatable, Sendable {
        /// `hw.model`, e.g. `Mac14,2`. Matched exactly: `Mac14,2` says nothing about `Mac14,3`.
        public let model: String
        /// The macOS major version this was run on.
        public let macOSMajor: Int
        public let arch: String
        public let level: Level

        public init(model: String, macOSMajor: Int, arch: String, level: Level) {
            self.model = model
            self.macOSMajor = macOSMajor
            self.arch = arch
            self.level = level
        }
    }

    /// Everything this project can honestly claim, and nothing else.
    ///
    /// Adding a row here is a claim about the world, and the only admissible reason is a run
    /// whose output is in this repository. `Scripts/check-documented-numbers.sh` has a sibling
    /// rule in spirit: if this list ever disagrees with what the README says, the README is
    /// wrong.
    public static let records: [Record] = [
        // The M0 short form, 2026-08-10, on the owner's machine: 36 ticks, 12 with the lid shut,
        // no gaps, and a positive control in `pmset -g log` on the same machine showing that it
        // does clamshell-sleep normally and did not while armed. Twelve seconds of evidence -
        // enough to say the mechanism works here, nowhere near an acceptance run.
        Record(model: "Mac14,2", macOSMajor: 15, arch: "arm64",
               level: .mechanismSeen(evidence: "M0 short form, 2026-08-10, with a positive control"))
    ]

    /// What is known about the machine this is running on.
    public static func level(model: String, macOSMajor: Int, arch: String) -> Level {
        // Exact match on all three. A model that differs by one digit is a different machine
        // with a different thermal envelope, and a macOS major is where power management
        // changes. Being generous here would turn evidence into a guess with a citation.
        for record in records
        where record.model == model && record.macOSMajor == macOSMajor && record.arch == arch {
            return record.level
        }
        return .untested
    }

    /// The line the user sees, or nil when there is nothing worth saying.
    ///
    /// `accepted` says nothing: a product that congratulates itself on every launch for working
    /// is noise, and the user came here for a lid, not for a compatibility report.
    public static func notice(for level: Level) -> String? {
        switch level {
        case .accepted:
            return nil
        case .mechanismSeen:
            return Strings.text("hardware.partial",
                                "Tested briefly on this kind of Mac, not for a full run.")
        case .untested:
            return Strings.text("hardware.untested",
                                "Lidwing has not been tested on this Mac. "
                                + "It will tell you if it cannot do its job.")
        }
    }

    /// The one-line summary for the diagnostics report, which always says something - a support
    /// bundle is read by someone who cannot see the machine, and "untested" is half the answer
    /// to most questions they will have.
    public static func diagnosticsLine(model: String, macOSMajor: Int, arch: String) -> String {
        switch level(model: model, macOSMajor: macOSMajor, arch: arch) {
        case .accepted(let evidence):
            return "accepted (\(evidence))"
        case .mechanismSeen(let evidence):
            return "mechanism seen (\(evidence))"
        case .untested:
            return "untested - no run on \(model) / macOS \(macOSMajor) / \(arch)"
        }
    }
}
