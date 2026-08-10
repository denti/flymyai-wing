import Foundation
import os
import LidwingCore

/// Emits the `LogCatalogue` events into the unified log.
///
/// Every value is formatted here rather than interpolated at the call site, because
/// interpolating a `String` into an `OSLogMessage` is what accidentally publishes a path. The
/// values that reach the log are built from a `[String: String]` of allowlisted fields, and the
/// whole record goes in as one already-assembled string marked `.public`.
///
/// That is a deliberate trade: it gives up per-field redaction in exchange for a single place
/// where the decision "is this safe to record" is made, and the allowlist that makes it is
/// unit-tested in the portable module.
public struct Log {

    private let loggers: [LogCatalogue.Category: Logger]

    public static let shared = Log()

    public init(subsystem: String = LogCatalogue.subsystem) {
        var built: [LogCatalogue.Category: Logger] = [:]
        for category in LogCatalogue.Category.allCases {
            built[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        loggers = built
    }

    /// - Parameter fields: only keys listed in `event.publicFields` are recorded. Anything else
    ///   is dropped silently — a caller that passes an unexpected key gets nothing in the log
    ///   rather than an unreviewed value in a user's support bundle.
    public func emit(_ event: LogEvent, _ category: LogCatalogue.Category,
                     _ fields: [String: String] = [:]) {
        guard let logger = loggers[category] else { return }
        let rendered = Log.render(event, fields)
        switch event.level {
        case .notice: logger.notice("\(rendered, privacy: .public)")
        case .error: logger.error("\(rendered, privacy: .public)")
        case .fault: logger.fault("\(rendered, privacy: .public)")
        }
    }

    /// Pure, so the exact bytes that reach the log can be asserted in a test.
    public static func render(_ event: LogEvent, _ fields: [String: String]) -> String {
        var parts = [event.name]
        // Ordered by the catalogue, not by the caller's dictionary, so two runs of the same
        // event produce lines a human can compare down a column.
        for key in event.publicFields {
            guard let value = fields[key] else { continue }
            parts.append("\(key)=\(sanitise(value))")
        }
        return parts.joined(separator: " ")
    }

    /// Values are single tokens. A space or a newline in one would break the column layout the
    /// line above exists to produce, and a control character would let another tool's output
    /// draw on a terminal reading the log.
    static func sanitise(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            guard output.count < 64 else { break }
            if scalar.value < 0x20 || scalar == " " || scalar.value == 0x7F {
                output.append("_")
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output.isEmpty ? "-" : output
    }
}
