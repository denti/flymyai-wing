import Foundation

/// A JSON model that remembers the order its keys were written in.
///
/// `JSONSerialization` does not. Round-tripping someone's `~/.claude/settings.json` through it
/// returns a file with the same *meaning* and a completely different *shape* — every key
/// reordered, every bit of their formatting gone. That is not "we added a hook", that is "we
/// rewrote your configuration file", and it is the difference between a diff a user can read
/// and one they cannot.
///
/// So: a small parser that keeps order, and a serialiser that indents the way the original did.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)          // kept verbatim: 1.0 and 1 are different bytes and both valid
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let left), .bool(let right)): return left == right
        case (.number(let left), .number(let right)): return left == right
        case (.string(let left), .string(let right)): return left == right
        case (.array(let left), .array(let right)): return left == right
        case (.object(let left), .object(let right)):
            // Order is part of the value here: a file whose keys came back in a different
            // order is a file we rewrote, not a file we read.
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    // MARK: object access

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.key == key }?.value
        }
        set {
            guard case .object(var pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    pairs[index].value = newValue
                } else {
                    pairs.remove(at: index)
                }
            } else if let newValue {
                // New keys go at the end, where a reader looks for what changed.
                pairs.append((key: key, value: newValue))
            }
            self = .object(pairs)
        }
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    public var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }
}

public enum JSONParseError: Error, Equatable {
    case unexpectedCharacter(offset: Int)
    case unexpectedEnd
    case trailingContent(offset: Int)
    case invalidNumber(offset: Int)
    case invalidEscape(offset: Int)
}

/// A strict JSON parser. It rejects what it does not understand rather than guessing, because
/// the file it is reading belongs to somebody else and a guess is a corrupted config.
public struct OrderedJSON {

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw JSONParseError.trailingContent(offset: parser.offset) }
        return value
    }

    /// Serialises with the indentation the source used, so an unchanged file round-trips to
    /// something a `diff` shows as unchanged.
    public static func serialise(_ value: JSONValue, indent: String = "  ") -> String {
        var output = ""
        write(value, into: &output, indent: indent, depth: 0)
        output.append("\n")
        return output
    }

    /// Detects the indentation of the first indented line. Two spaces if there is none to see.
    public static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if !leading.isEmpty && leading.count < line.count {
                return String(leading)
            }
        }
        return "  "
    }

    private static func write(_ value: JSONValue, into output: inout String,
                              indent: String, depth: Int) {
        let pad = String(repeating: indent, count: depth)
        let inner = String(repeating: indent, count: depth + 1)
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let literal):
            output += literal
        case .string(let text):
            output += escape(text)
        case .array(let values):
            if values.isEmpty { output += "[]"; return }
            output += "[\n"
            for (index, element) in values.enumerated() {
                output += inner
                write(element, into: &output, indent: indent, depth: depth + 1)
                output += index == values.count - 1 ? "\n" : ",\n"
            }
            output += pad + "]"
        case .object(let pairs):
            if pairs.isEmpty { output += "{}"; return }
            output += "{\n"
            for (index, pair) in pairs.enumerated() {
                output += inner + escape(pair.key) + ": "
                write(pair.value, into: &output, indent: indent, depth: depth + 1)
                output += index == pairs.count - 1 ? "\n" : ",\n"
            }
            output += pad + "}"
        }
    }

    static func escape(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    // MARK: the parser

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var offset = 0

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var isAtEnd: Bool { offset >= scalars.count }
        var current: Unicode.Scalar? { isAtEnd ? nil : scalars[offset] }

        mutating func skipWhitespace() {
            while let scalar = current,
                  scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                offset += 1
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard let scalar = current else { throw JSONParseError.unexpectedEnd }
            switch scalar {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            for expected in word.unicodeScalars {
                guard current == expected else {
                    throw JSONParseError.unexpectedCharacter(offset: offset)
                }
                offset += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            offset += 1                                  // {
            var pairs: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if current == "}" { offset += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                guard current == ":" else { throw JSONParseError.unexpectedCharacter(offset: offset) }
                offset += 1
                skipWhitespace()
                let value = try parseValue()
                pairs.append((key: key, value: value))
                skipWhitespace()
                switch current {
                case ",": offset += 1
                case "}": offset += 1; return .object(pairs)
                case nil: throw JSONParseError.unexpectedEnd
                default: throw JSONParseError.unexpectedCharacter(offset: offset)
                }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            offset += 1                                  // [
            var values: [JSONValue] = []
            skipWhitespace()
            if current == "]" { offset += 1; return .array(values) }
            while true {
                skipWhitespace()
                values.append(try parseValue())
                skipWhitespace()
                switch current {
                case ",": offset += 1
                case "]": offset += 1; return .array(values)
                case nil: throw JSONParseError.unexpectedEnd
                default: throw JSONParseError.unexpectedCharacter(offset: offset)
                }
            }
        }

        mutating func parseString() throws -> String {
            guard current == "\"" else { throw JSONParseError.unexpectedCharacter(offset: offset) }
            offset += 1
            var result = String.UnicodeScalarView()
            while true {
                guard let scalar = current else { throw JSONParseError.unexpectedEnd }
                offset += 1
                if scalar == "\"" { return String(result) }
                guard scalar == "\\" else {
                    result.append(scalar)
                    continue
                }
                result.append(try parseEscape())
            }
        }

        /// The two-character escapes plus `\u`. Split out of `parseString` so that neither
        /// function needs a reader to hold ten branches in their head at once.
        mutating func parseEscape() throws -> Unicode.Scalar {
            guard let escaped = current else { throw JSONParseError.unexpectedEnd }
            offset += 1
            switch escaped {
            case "\"": return "\""
            case "\\": return "\\"
            case "/": return "/"
            case "b": return Unicode.Scalar(8)
            case "f": return Unicode.Scalar(12)
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "u": return try parseUnicodeEscape()
            default: throw JSONParseError.invalidEscape(offset: offset - 1)
            }
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            func hexQuad() throws -> UInt32 {
                var value: UInt32 = 0
                for _ in 0..<4 {
                    guard let scalar = current,
                          let digit = scalar.hexDigitValue else {
                        throw JSONParseError.invalidEscape(offset: offset)
                    }
                    value = value * 16 + UInt32(digit)
                    offset += 1
                }
                return value
            }
            let first = try hexQuad()
            // A surrogate pair is two escapes, and dropping the second one corrupts every
            // emoji in somebody's config file.
            if (0xD800...0xDBFF).contains(first) {
                guard current == "\\" else { throw JSONParseError.invalidEscape(offset: offset) }
                offset += 1
                guard current == "u" else { throw JSONParseError.invalidEscape(offset: offset) }
                offset += 1
                let second = try hexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw JSONParseError.invalidEscape(offset: offset)
                }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else {
                    throw JSONParseError.invalidEscape(offset: offset)
                }
                return scalar
            }
            guard let scalar = Unicode.Scalar(first) else {
                throw JSONParseError.invalidEscape(offset: offset)
            }
            return scalar
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = offset
            if current == "-" { offset += 1 }
            while let scalar = current,
                  ("0"..."9").contains(scalar) || scalar == "." || scalar == "e"
                    || scalar == "E" || scalar == "+" || scalar == "-" {
                offset += 1
            }
            guard offset > start else { throw JSONParseError.unexpectedCharacter(offset: offset) }
            let literal = String(String.UnicodeScalarView(scalars[start..<offset]))
            guard Double(literal) != nil else { throw JSONParseError.invalidNumber(offset: start) }
            // Kept as written: rewriting 1.0 as 1 changes bytes in somebody else's file for no
            // reason.
            return .number(literal)
        }
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61) + 10
        case "A"..."F": return Int(value - 0x41) + 10
        default: return nil
        }
    }
}
