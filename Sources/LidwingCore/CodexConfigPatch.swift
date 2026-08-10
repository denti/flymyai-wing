import Foundation

/// Installs and removes the `notify` entry in `~/.codex/config.toml`.
///
/// Codex's `notify` is a **single scalar**, and on real machines it is already occupied — by
/// Codex Computer Use, among others. Blind-writing it silently breaks a feature the user
/// already had. So when it is taken, we chain: our helper runs first, sends its message, and
/// then `execv`s the command it displaced with the same argument. The original array is stored
/// verbatim so uninstall restores it byte for byte.
///
/// This is a **line editor**, not a TOML parser, and that is deliberate. A parse-and-reserialise
/// round trip would rewrite comments, quoting style and table order in a file the user wrote by
/// hand. Only the one line we own is touched; every other byte of the file survives exactly.
public enum CodexConfigPatch {

    public static let key = "notify"

    public struct Patch: Equatable {
        public let text: String
        public let changed: Bool
        public let diff: String
        /// What was in `notify` before us, verbatim, for exact restoration later.
        public let displaced: [String]?
    }

    public enum PatchError: Error, Equatable {
        /// The existing value is not an array of strings, so we cannot chain to it safely.
        case unsupportedValue(String)
    }

    /// - Parameter helperPath: absolute path of `lidwing-notify` inside the app bundle.
    public static func install(into source: String, helperPath: String) throws -> Patch {
        let lines = source.components(separatedBy: "\n")
        let existing = findTopLevelKey(in: lines)

        var displaced: [String]?
        if let existing {
            let value = existing.value.trimmingCharacters(in: .whitespaces)
            if value.contains(LidwingID.integrationMarker) {
                // Already ours. Re-installing must not chain to ourselves, which would grow a
                // longer argument list on every run.
                displaced = extractChain(from: value)
            } else {
                guard let parsed = parseStringArray(value) else {
                    throw PatchError.unsupportedValue(value)
                }
                displaced = parsed
            }
        }

        let replacement = "\(key) = \(render(helperPath: helperPath, chaining: displaced))"

        var output = lines
        if let existing {
            output[existing.index] = replacement
        } else {
            // Top level only. Appending after a `[table]` header would put the key inside that
            // table, where Codex would never look for it.
            let insertion = firstTableHeaderIndex(in: lines) ?? lines.count
            output.insert(replacement, at: insertion)
        }

        let text = output.joined(separator: "\n")
        return Patch(text: text, changed: text != source,
                     diff: ClaudeSettingsPatch.lineDiff(before: source, after: text),
                     displaced: displaced)
    }

    /// Restores what we displaced, or removes the line entirely if it was ours alone.
    public static func uninstall(from source: String, restoring displaced: [String]?) -> Patch {
        let lines = source.components(separatedBy: "\n")
        guard let existing = findTopLevelKey(in: lines),
              existing.value.contains(LidwingID.integrationMarker) else {
            return Patch(text: source, changed: false, diff: "", displaced: nil)
        }

        var output = lines
        if let displaced, !displaced.isEmpty {
            output[existing.index] = "\(key) = \(renderArray(displaced))"
        } else {
            output.remove(at: existing.index)
        }
        let text = output.joined(separator: "\n")
        return Patch(text: text, changed: text != source,
                     diff: ClaudeSettingsPatch.lineDiff(before: source, after: text),
                     displaced: nil)
    }

    // MARK: rendering

    static func render(helperPath: String, chaining displaced: [String]?) -> String {
        var argv = [helperPath, "--codex"]
        if let displaced, !displaced.isEmpty {
            argv.append("--chain")
            argv.append(contentsOf: displaced)
        }
        return renderArray(argv)
    }

    static func renderArray(_ values: [String]) -> String {
        "[" + values.map { "\"" + escape($0) + "\"" }.joined(separator: ", ") + "]"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: reading

    /// Finds `notify = …` in the top-level section only — that is, before the first `[table]`
    /// header. A `notify` inside `[tui]` belongs to `[tui]` and is none of our business.
    static func findTopLevelKey(in lines: [String]) -> (index: Int, value: String)? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }         // a table starts: we are past it
            guard !trimmed.hasPrefix("#") else { continue }
            guard trimmed.hasPrefix(key) else { continue }
            let afterKey = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            return (index, String(afterKey.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func firstTableHeaderIndex(in lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
    }

    /// Parses a single-line TOML array of basic strings. Anything else is refused rather than
    /// guessed at: a mangled `notify` breaks a feature the user paid for.
    static func parseStringArray(_ text: String) -> [String]? {
        var value = text
        // Strip a trailing comment that is outside the quotes.
        if let commentIndex = indexOfUnquotedHash(value) {
            value = String(value[value.startIndex..<commentIndex])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = value.dropFirst().dropLast()

        var results: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for character in inner {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inString:
                escaped = true
            case "\"":
                if inString { results.append(current); current = "" }
                inString.toggle()
            case "," where !inString, " " where !inString, "\t" where !inString:
                continue
            default:
                if inString {
                    current.append(character)
                } else {
                    return nil          // a bare value: not a string array
                }
            }
        }
        return inString ? nil : results
    }

    private static func indexOfUnquotedHash(_ text: String) -> String.Index? {
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if character == "#" && !inString {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Pulls the displaced command back out of a value we previously wrote.
    static func extractChain(from value: String) -> [String]? {
        guard let argv = parseStringArray(value),
              let chainIndex = argv.firstIndex(of: "--chain") else { return nil }
        let tail = Array(argv[(chainIndex + 1)...])
        return tail.isEmpty ? nil : tail
    }
}
