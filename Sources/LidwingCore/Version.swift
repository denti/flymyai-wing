import Foundation

/// Build identity.
///
/// The build number is zero-padded to ten digits on purpose. A code-signing requirement
/// compares `info[LWTrustBuild]` as a **string**, so an unpadded "1.10" sorts below "1.9" and a
/// downgrade pin silently inverts. Ten digits makes lexicographic order equal numeric order for
/// every value up to 9_999_999_999 — more commits than this project will ever have.
public struct BuildNumber: Equatable, Comparable, CustomStringConvertible, Sendable {
    public static let digits = 10
    public static let maximum: UInt64 = 9_999_999_999

    public let value: UInt64

    /// Fails for values that cannot be represented in ten digits, rather than silently
    /// truncating and producing a pin that compares wrong.
    public init?(_ value: UInt64) {
        guard value <= BuildNumber.maximum else { return nil }
        self.value = value
    }

    /// Parses a padded or unpadded decimal string.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = UInt64(trimmed), parsed <= BuildNumber.maximum
        else { return nil }
        self.value = parsed
    }

    public var padded: String {
        let raw = String(value)
        guard raw.count < BuildNumber.digits else { return raw }
        return String(repeating: "0", count: BuildNumber.digits - raw.count) + raw
    }

    public var description: String { padded }

    public static func < (lhs: BuildNumber, rhs: BuildNumber) -> Bool { lhs.value < rhs.value }
}

/// A semantic version, compared numerically component by component.
public struct SemanticVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "1", "1.2", "1.2.3" and a leading "v". Anything else is nil — we never guess.
    public init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = Int(part) else { return nil }
            numbers.append(parsed)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
