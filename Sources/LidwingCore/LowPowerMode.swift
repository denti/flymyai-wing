import Foundation

/// Low Power Mode: when it should be on, and the rules for being a guest in a setting we do not
/// own.
///
/// This is the one feature in Lidwing that needs administrator rights, and it is the only reason
/// a privileged helper exists at all. Decision 0010: the option ships **off**, turning it on is
/// exactly when the helper is installed and a password is asked for, and a user who never
/// enables it never sees a prompt. Everything in this file is the portable half - the decisions
/// - so that the part which runs as root has as little judgement in it as possible.
///
/// The guest rules come from `DECISIONS.md` and they are not politeness. `lowpowermode` is a
/// setting the user may already have deliberately configured; on the owner's own Mac it is
/// already `1` on both power sources. An app that "restores the default" there would silently
/// undo his setup, and an app that writes a value already in place leaves a trace in
/// `pmset -g custom` for no reason at all.
public enum LowPowerPolicy {

    /// Everything the decision depends on. All four are read from the machine, never cached.
    public struct Conditions: Equatable, Sendable {
        /// The user turned the option on, and the helper is installed.
        public let userEnabled: Bool
        /// Lidwing is currently protecting the machine.
        public let armed: Bool
        /// The lid is shut. Low Power Mode is about the closed-lid run, not about Lidwing being
        /// switched on while the user is still typing.
        public let lidClosed: Bool
        public let onAC: Bool

        public init(userEnabled: Bool, armed: Bool, lidClosed: Bool, onAC: Bool) {
            self.userEnabled = userEnabled
            self.armed = armed
            self.lidClosed = lidClosed
            self.onAC = onAC
        }
    }

    /// Whether Low Power Mode should be engaged right now.
    ///
    /// On AC it is never engaged. There is nothing to save from a socket, so the slowdown would
    /// be pure loss - the user's agent takes longer to finish and gains them nothing.
    public static func shouldEngage(_ conditions: Conditions) -> Bool {
        conditions.userEnabled
            && conditions.armed
            && conditions.lidClosed
            && !conditions.onAC
    }
}

/// What `lowpowermode` was before Lidwing touched it, per power source.
///
/// macOS stores the setting separately for battery and for AC. Collapsing the two into one
/// value destroys a choice the user made, so both are carried, and either may be `nil` when the
/// key could not be read - which is a reason to leave that source alone rather than to guess.
public struct LowPowerSnapshot: Equatable, Codable, Sendable {
    public let battery: Bool?
    public let ac: Bool?
    /// What Lidwing wrote, so a restore can tell "unchanged since we set it" from "somebody else
    /// changed it after us". Nil where we wrote nothing.
    public let wroteBattery: Bool?
    public let wroteAC: Bool?

    public init(battery: Bool?, ac: Bool?, wroteBattery: Bool? = nil, wroteAC: Bool? = nil) {
        self.battery = battery
        self.ac = ac
        self.wroteBattery = wroteBattery
        self.wroteAC = wroteAC
    }
}

/// The guest rules, as arithmetic.
public enum LowPowerGuest {

    /// One instruction for the privileged helper. Deliberately a value with no paths and no
    /// strings in it: the helper's whole API is "set these two booleans", so there is nothing
    /// in the interface that could be pointed at a file. Antipattern 45 - a helper that accepts
    /// path arguments turns a world-executable binary into a privilege-escalation surface.
    public struct Write: Equatable, Sendable {
        public enum Source: String, Equatable, Codable, Sendable {
            case battery
            case ac
        }
        public let source: Source
        public let value: Bool

        public init(source: Source, value: Bool) {
            self.source = source
            self.value = value
        }
    }

    /// The writes needed to engage or release, given what the machine currently reports.
    ///
    /// Returns an empty array when the machine already agrees - never write a value that is
    /// already in place. That is not an optimisation: every write to `lowpowermode` is a
    /// privileged operation and shows up in the user's own `pmset -g custom`.
    ///
    /// Only the battery source is ever written. Low Power Mode on AC is not something this
    /// product has any business changing: the user is plugged in, there is nothing to save, and
    /// the AC value is carried in the snapshot purely so an uninstall can prove it was untouched.
    public static func writesToEngage(_ engage: Bool, current: LowPowerSnapshot) -> [Write] {
        guard let battery = current.battery else { return [] }
        if battery == engage { return [] }
        return [Write(source: .battery, value: engage)]
    }

    /// What restoring should write, given the snapshot taken before we touched anything and what
    /// the machine says now.
    ///
    /// Three cases, and the third is the one that matters:
    ///
    /// * we wrote nothing → nothing to restore;
    /// * the value is still what we set → put the original back;
    /// * the value is something else → **leave it alone**. The user or another tool changed it
    ///   after us, and their choice is newer than ours. Writing our remembered value over it
    ///   would be the app deciding it knows better, which is exactly the behaviour that makes
    ///   people distrust software with a password prompt.
    public static func writesToRestore(snapshot: LowPowerSnapshot,
                                       current: LowPowerSnapshot) -> [Write] {
        guard snapshot.wroteBattery != nil else { return [] }
        // The same predicate that is reported to the user, rather than a second copy of the
        // reasoning. When these were separate a mutation that broke the "somebody else changed
        // it" check could not be detected: for a two-valued setting, "it is no longer what we
        // set" and "it is already back to the original" are the same state, so the next guard
        // covered it by accident. Deciding with the predicate we report also means the thing
        // Lidwing tells the user is exactly the thing Lidwing did.
        guard !restoreWasOverruled(snapshot: snapshot, current: current) else { return [] }
        guard let now = current.battery else { return [] }
        guard let original = snapshot.battery, original != now else { return [] }
        return [Write(source: .battery, value: original)]
    }

    /// Whether a restore was skipped because somebody else changed the value after us. Recorded
    /// and shown, never silent: the user is entitled to know that Lidwing left a setting alone
    /// on purpose.
    public static func restoreWasOverruled(snapshot: LowPowerSnapshot,
                                           current: LowPowerSnapshot) -> Bool {
        guard let wrote = snapshot.wroteBattery, let now = current.battery else { return false }
        return now != wrote
    }
}
