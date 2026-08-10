import Foundation

/// What Lidwing's own state directory and files are allowed to be, as arithmetic rather than as
/// a comment.
///
/// The directory holds the ledger, the audit log, and both control sockets. The audit log
/// records when this Mac was kept awake and which agent binaries were running, which is exactly
/// the kind of thing this product promises not to leak - and a promise about privacy that only
/// holds on a freshly created directory is not a promise.
///
/// It was created with mode 0700 and then never looked at again. A directory that already
/// exists keeps whatever mode it has: restored from a backup that lost the mode, migrated by
/// Setup Assistant, created by an earlier build, or simply made by hand. `createDirectory` does
/// not correct an existing one, and it does not complain either.
///
/// Pure, so the rule is tested on Linux rather than asserted about a machine nobody runs the
/// tests on.
public enum StatePermissions {
    /// Owner-only, for the directory that holds everything.
    public static let directoryMode = 0o700
    /// Owner-only, for the ledger, the audit log and the sockets.
    public static let fileMode = 0o600

    /// Whether a mode grants anything at all to group or other.
    ///
    /// Deliberately not "is it exactly 0700". Modes carry bits this rule has no opinion about -
    /// the sticky bit, setgid on a directory inherited from a parent - and a check that demands
    /// an exact value would keep trying to "repair" a directory that is already private.
    public static func isTooOpen(_ mode: Int) -> Bool {
        (mode & 0o077) != 0
    }

    /// The same mode with every group and other bit cleared, and nothing else changed.
    public static func tightened(_ mode: Int) -> Int {
        mode & ~0o077
    }
}
