import Foundation

/// Which system sound each chime uses, with fallbacks, and an honest answer about what is
/// missing.
///
/// The player used to name one file per chime and return silently if it was absent - no log, no
/// warning, and the sound checkbox still sitting in Settings. That is the antipattern by name:
/// the options are still there and the sounds no longer play. It is the top negative review of
/// the closest comparable app, and the reason the rule is "ship a Play button and a self-check
/// that detects and reports its own failure".
///
/// It matters more here than for most apps. Sound is not decoration in this product: with the
/// lid shut it is the *only* channel. A chime that silently stopped working takes the lid-close
/// confirmation with it, and the user finds out by opening a laptop that has been asleep for
/// three hours.
///
/// This is a pure lookup so the fallback order is testable without an audio device - CI has no
/// sound hardware, and asserting against a real one would prove nothing anyway.
public enum ChimeCatalogue {

    /// Preferred file first. Every candidate is a stock macOS sound; nothing is bundled, because
    /// a custom whoosh marks an app as cross-platform instantly.
    public static let candidates: [Chime: [String]] = [
        // Rising, brief, unmistakably "sealed". Bottle and Glass are the nearest stock cousins.
        .sealed: ["Submarine", "Bottle", "Glass"],
        // Falling and soft: the machine is about to sleep normally, which is not an alarm.
        .standingDown: ["Bottle", "Pop", "Tink"],
        // The one sound that must never be pretty.
        .failure: ["Basso", "Sosumi", "Funk"],
        // A person is being asked for something, not warned.
        .agentWaiting: ["Ping", "Tink", "Pop"]
    ]

    public static let directory = "/System/Library/Sounds"

    public static func path(for file: String) -> String {
        "\(directory)/\(file).aiff"
    }

    /// Picks a file per chime, given a predicate that says whether a sound exists on this Mac.
    ///
    /// The predicate is injected rather than read from disk so this can be tested against a
    /// machine that is missing exactly one sound - the case that matters and the one nobody has.
    public static func resolve(exists: (String) -> Bool) -> [Chime: String] {
        var chosen: [Chime: String] = [:]
        for (chime, options) in candidates {
            if let found = options.first(where: { exists(path(for: $0)) }) {
                chosen[chime] = found
            }
        }
        return chosen
    }

    /// The chimes for which nothing at all could be found, sorted so the report is stable.
    ///
    /// Never used to disable the sound feature quietly: it is used to *say so*.
    public static func missing(from chosen: [Chime: String]) -> [Chime] {
        candidates.keys.filter { chosen[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
    }

    /// The line shown under the sound checkbox and in the diagnostics report. `nil` when
    /// everything resolved, because a self-check that reports success on every launch is noise
    /// that trains people to ignore it.
    public static func selfCheckWarning(missing: [Chime]) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.rawValue).joined(separator: ", ")
        return Strings.text("settings.sound.missing",
                            "This Mac is missing the sounds Lidwing uses (%1$@). "
                            + "Lid-close confirmation will be silent.", names)
    }
}
