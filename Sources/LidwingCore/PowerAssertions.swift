import Foundation

/// Who else is holding this Mac awake, what kind of hold it is, and whether it is worth telling
/// the user about.
///
/// The shape of this file comes from a real developer machine rather than from imagination. On
/// one ordinary Mac, at one ordinary moment, `pmset -g assertions` showed **three different
/// assertion types held by three different owners with three different lifetimes**:
///
/// * `Claude` (the Electron desktop app), `NoIdleSleepAssertion`, held for 3h25m — persistent;
/// * `caffeinate`, `PreventUserIdleSystemSleep`, 38 seconds old with a 300-second timeout and
///   `Action=TimeoutActionRelease` — transient, and **self-respawning**, because Claude Code
///   starts `caffeinate -i -t 300` per command;
/// * `configd`, `DenySystemSleep`, named `InternetSharingPreferencePlugin`, 1h30m — Internet
///   Sharing, and a strictly stronger hold than either of the idle ones.
///
/// Plus noise that means nothing to us: `powerd`'s own bookkeeping, `WindowServer`'s
/// `UserIsActive` from a trackpad tickle, `mds_stores` doing background work.
///
/// Three consequences drive everything below. The **type** matters, because an idle-sleep hold
/// and a system-sleep hold are different problems. The **owner** must be named the way a person
/// would recognise it - "Claude", "Internet Sharing" - not as a pid. And a detector that reacts
/// to `caffeinate` would **flap** every few minutes forever, which is worse than not detecting
/// it at all: a menu bar that changes on its own every 300 seconds teaches the user to ignore it.
public enum PowerAssertions {

    /// What a hold actually prevents. The names are Apple's; the grouping is ours.
    public enum Kind: String, Equatable, Sendable {
        /// Stops the *idle* timer only. The machine still sleeps when the lid closes, so this
        /// does not do Lidwing's job - but it does mean somebody else is managing sleep.
        case idleSleep
        /// Stops the system sleeping at all, including on lid close. This is the strong one, and
        /// the only kind that genuinely overlaps with what Lidwing does.
        case systemSleep
        /// Keeps the display awake. Irrelevant to a closed lid.
        case display
        /// The user is touching the machine. Not a hold anybody chose.
        case userActive
        /// Something we have no opinion about.
        case other
    }

    public struct Assertion: Equatable, Sendable {
        public let pid: Int32
        /// The process name as the kernel reports it: `caffeinate`, `Claude`, `configd`.
        public let process: String
        public let kind: Kind
        /// The assertion's own name, which is often more human than the process: an Internet
        /// Sharing hold is owned by `configd` and named `InternetSharingPreferencePlugin`.
        public let name: String
        /// Seconds until this hold releases itself, when it says so. `caffeinate -t 300` does.
        public let releasesInSeconds: Int?

        public init(pid: Int32, process: String, kind: Kind, name: String,
                    releasesInSeconds: Int? = nil) {
            self.pid = pid
            self.process = process
            self.kind = kind
            self.name = name
            self.releasesInSeconds = releasesInSeconds
        }
    }

    /// Processes whose assertions are macOS talking to itself. Naming any of these to a user
    /// would be noise dressed as information.
    public static let systemOwned: Set<String> = ["powerd", "WindowServer", "mds_stores",
                                                  "mds", "kernel_task", "loginwindow"]

    public static func kind(ofAssertionNamed raw: String) -> Kind {
        switch raw {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion":
            return .idleSleep
        case "PreventSystemSleep", "DenySystemSleep":
            return .systemSleep
        case "PreventUserIdleDisplaySleep", "InternalPreventDisplaySleep",
             "PreventDisplayIdleSleep":
            return .display
        case "UserIsActive", "InternalPreventSleep":
            return .userActive
        default:
            return .other
        }
    }

    /// Parses the `Listed by owning process:` section of `pmset -g assertions`.
    ///
    /// Pure and text-in, so the exact output of a real machine can be a fixture. At runtime
    /// Lidwing reads the same facts through `IOPMCopyAssertionsByProcess` rather than shelling
    /// out; this exists so the *classification* is tested against reality rather than against a
    /// mock somebody wrote to match their own assumptions.
    public static func parse(_ output: String) -> [Assertion] {
        var found: [Assertion] = []
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Everything before the header is the system-wide summary, which says how many holds
        // exist but never who owns them.
        if let header = lines.firstIndex(where: { $0.hasPrefix("Listed by owning process") }) {
            lines = Array(lines[(header + 1)...])
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid ") else { continue }
            guard let openParen = trimmed.firstIndex(of: "("),
                  let closeParen = trimmed[openParen...].firstIndex(of: ")") else { continue }

            let pidText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<openParen]
            guard let pid = Int32(pidText.trimmingCharacters(in: .whitespaces)) else { continue }
            let process = String(trimmed[trimmed.index(after: openParen)..<closeParen])

            // `<time> <AssertionType> named: "<name>"`. The type is the token before `named:`.
            guard let namedRange = trimmed.range(of: " named: ") else { continue }
            let beforeNamed = trimmed[..<namedRange.lowerBound]
            guard let rawKind = beforeNamed.split(separator: " ").last else { continue }
            let quoted = trimmed[namedRange.upperBound...]
            let name = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))

            // A timeout, if the owner declared one, lives on a continuation line beneath.
            var releasesIn: Int?
            var cursor = index + 1
            while cursor < lines.count {
                let detail = lines[cursor].trimmingCharacters(in: .whitespaces)
                if detail.hasPrefix("pid ") || detail.isEmpty { break }
                if let seconds = secondsUntilTimeout(in: detail) { releasesIn = seconds }
                cursor += 1
            }

            found.append(Assertion(pid: pid, process: process,
                                   kind: kind(ofAssertionNamed: String(rawKind)),
                                   name: name, releasesInSeconds: releasesIn))
        }
        return found
    }

    /// `Timeout will fire in 262 secs Action=TimeoutActionRelease`
    ///
    /// Only a timeout that **releases** counts. `TimeoutActionTurnOff` and the others do not
    /// hand the machine back, so treating them as temporary would be wrong in the direction that
    /// matters.
    static func secondsUntilTimeout(in detail: String) -> Int? {
        guard detail.contains("Timeout will fire in"),
              detail.contains("TimeoutActionRelease") else { return nil }
        let digits = detail.split(separator: " ").compactMap { Int($0) }
        return digits.first
    }
}

/// Which of those holds the user is actually told about, and what they are called.
public enum ConflictPolicy {

    /// A hold worth naming in the menu.
    public struct Conflict: Equatable, Sendable {
        public let displayName: String
        public let kind: PowerAssertions.Kind
        public let pid: Int32
        /// True when the holder declared a release time. Reported, but never used to hide it.
        public let isTransient: Bool

        public init(displayName: String, kind: PowerAssertions.Kind, pid: Int32,
                    isTransient: Bool) {
            self.displayName = displayName
            self.kind = kind
            self.pid = pid
            self.isTransient = isTransient
        }
    }

    /// Anything at or under this is somebody else's short-lived hold rather than a state of the
    /// machine. `caffeinate -i -t 300` is the case that forced the number: Claude Code spawns
    /// one **per command**, so a detector without this flaps every few minutes, forever - and a
    /// menu bar that changes on its own teaches the user to stop reading it.
    public static let transientThresholdSeconds = 600

    /// Turns a human-recognisable name out of a process and an assertion name.
    ///
    /// The assertion name is often the human one: an Internet Sharing hold belongs to `configd`,
    /// which tells the user nothing, and is named `InternetSharingPreferencePlugin`, which tells
    /// them exactly what to switch off.
    public static func displayName(process: String, assertionName: String) -> String {
        if assertionName.contains("InternetSharing") { return "Internet Sharing" }
        if process == "caffeinate" { return "caffeinate" }
        if assertionName.hasPrefix("com.apple.") { return process }
        // An Electron app names its assertion "Electron", which describes the toolkit rather
        // than the app the user installed.
        if assertionName == "Electron" { return process }
        return process
    }

    /// The holds worth showing, strongest first.
    ///
    /// Filtering, in order of what it protects the user from:
    ///
    /// * **System processes are dropped.** `powerd` and `WindowServer` assert constantly and a
    ///   user can do nothing about either.
    /// * **Display and user-active holds are dropped.** A closed lid has no display to keep
    ///   awake, and a trackpad tickle is not a conflict.
    /// * **Short-lived holds that release themselves are kept but marked transient**, so the UI
    ///   can name them without treating them as a standing state of the machine.
    public static func conflicts(from assertions: [PowerAssertions.Assertion]) -> [Conflict] {
        assertions
            .filter { !PowerAssertions.systemOwned.contains($0.process) }
            .filter { $0.kind == .idleSleep || $0.kind == .systemSleep }
            .map { assertion in
                Conflict(displayName: displayName(process: assertion.process,
                                                  assertionName: assertion.name),
                         kind: assertion.kind,
                         pid: assertion.pid,
                         isTransient: (assertion.releasesInSeconds ?? .max)
                             <= transientThresholdSeconds)
            }
            // A system-sleep hold outranks an idle one: it is the only kind that does what
            // Lidwing does. Among equals, a standing hold outranks a self-releasing one.
            .sorted { left, right in
                if (left.kind == .systemSleep) != (right.kind == .systemSleep) {
                    return left.kind == .systemSleep
                }
                if left.isTransient != right.isTransient { return !left.isTransient }
                return left.pid < right.pid
            }
    }

    /// The one the menu names, or nil when nothing is worth saying.
    ///
    /// A purely transient holder is deliberately **not** promoted to the headline. If the only
    /// thing holding this Mac is a `caffeinate` that releases in four minutes and will be
    /// replaced by another one a moment later, saying so in the menu bar produces a flicker the
    /// user cannot act on. It stays in the list, and in diagnostics, where it explains things
    /// without shouting.
    public static func headline(from conflicts: [Conflict]) -> Conflict? {
        conflicts.first { !$0.isTransient }
    }
}
