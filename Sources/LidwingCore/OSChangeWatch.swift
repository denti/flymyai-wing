import Foundation

/// Notices that macOS changed under us, and makes the next verified arm say so.
///
/// This whole product rests on one undocumented `IOPMrootDomain` selector. Apple can change it
/// in any update, and the failure mode is the bad one: Lidwing keeps its confident wing in the
/// menu bar while the Mac quietly sleeps on the next lid close. The antipattern list names it
/// directly - break after a macOS update and stay broken silently - and points at Rectangle
/// losing its accessibility permission and Ice going invisible on Tahoe.
///
/// What this deliberately does **not** do is re-probe at launch. There is no read-only way to
/// prove the mechanism still works: `clamshellCausesSleep` and `sleepDisabled` are both `Bool?`
/// where nil legitimately means "key absent", so absence proves nothing. The only real proof is
/// setting the bit and reading it back - which is arming, and arming without the user asking
/// would break the invariant this product is built on. Nothing here ever arms anything.
///
/// So the honest version: remember the OS on which an arm last verified, notice when it differs,
/// and let the arm the user was going to perform anyway carry the answer. If it verifies, say so
/// once. If it does not, the existing failure path is already loud - and now the diagnostics can
/// say the machine last worked on a different build of macOS, which is the sentence that turns
/// "Lidwing is broken" into a bug report somebody can act on.
public enum OSChangeWatch {

    public enum Outcome: Equatable {
        /// No arm has ever verified, so there is nothing to compare against. A first run must
        /// stay quiet: telling a new user that macOS changed, before Lidwing has ever worked
        /// for them, is noise about a machine state they cannot act on.
        case noBaseline
        case unchanged
        /// An arm verified on `from`, and this is `to`. The next verified arm reports it.
        case changed(from: String, to: String)
    }

    public static func compare(lastVerifiedOS: String?, current: String) -> Outcome {
        guard let last = lastVerifiedOS, !last.isEmpty else { return .noBaseline }
        // Exact string comparison on purpose. The build number is the part that matters - a
        // security update that ships a new kernel keeps the marketing version and changes the
        // build - and parsing version numbers to decide what counts as "different enough" would
        // be inventing a rule Apple never agreed to.
        return last == current ? .unchanged : .changed(from: last, to: current)
    }
}
