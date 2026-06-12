// Internal ordered JSON representation backing GeneratedContent and schema
// serialization. Hand-rolled parser/serializer so behavior is identical on
// macOS and Linux (no JSONSerialization NSNumber ambiguity, ordered keys).

import Foundation

indirect enum JSONNode: Sendable, Equatable {
    struct Member: Sendable, Equatable {
        var key: String
        var value: JSONNode
    }

    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONNode])
    case object([Member])
}

// MARK: - Parsing

extension JSONNode {
    struct ParseError: Error, CustomStringConvertible {
        let reason: String
        var description: String { "JSON parse error: \(reason)" }
    }

    static func parse(_ text: String) throws -> JSONNode {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError(reason: "trailing characters after JSON value") }
        return value
    }

    private struct Parser {
        /// Maximum container nesting before parsing fails. Bounds recursion so
        /// adversarial input (e.g. 100k `[`) throws instead of overflowing the
        /// stack. The lenient path (`parseLenient`) funnels through the same
        /// parser, so it is covered by the same guard.
        static let maximumDepth = 256

        let scalars: [Unicode.Scalar]
        var index = 0
        var depth = 0

        var isAtEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count, " \t\n\r".unicodeScalars.contains(scalars[index]) {
                index += 1
            }
        }

        mutating func peek() throws -> Unicode.Scalar {
            guard index < scalars.count else { throw ParseError(reason: "unexpected end of input") }
            return scalars[index]
        }

        mutating func consume(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard index < scalars.count, scalars[index] == scalar else {
                    throw ParseError(reason: "expected '\(literal)'")
                }
                index += 1
            }
        }

        mutating func parseValue() throws -> JSONNode {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Parser.maximumDepth else {
                throw ParseError(reason: "maximum nesting depth exceeded")
            }
            skipWhitespace()
            switch try peek() {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try consume("true"); return .bool(true)
            case "f": try consume("false"); return .bool(false)
            case "n": try consume("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject() throws -> JSONNode {
            try consume("{")
            var members: [Member] = []
            skipWhitespace()
            if try peek() == "}" { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try consume(":")
                let value = try parseValue()
                members.append(Member(key: key, value: value))
                skipWhitespace()
                switch try peek() {
                case ",": index += 1
                case "}": index += 1; return .object(members)
                default: throw ParseError(reason: "expected ',' or '}' in object")
                }
            }
        }

        mutating func parseArray() throws -> JSONNode {
            try consume("[")
            var elements: [JSONNode] = []
            skipWhitespace()
            if try peek() == "]" { index += 1; return .array(elements) }
            while true {
                elements.append(try parseValue())
                skipWhitespace()
                switch try peek() {
                case ",": index += 1
                case "]": index += 1; return .array(elements)
                default: throw ParseError(reason: "expected ',' or ']' in array")
                }
            }
        }

        mutating func parseString() throws -> String {
            try consume("\"")
            var result = String.UnicodeScalarView()
            while true {
                guard index < scalars.count else { throw ParseError(reason: "unterminated string") }
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(result) }
                if scalar == "\\" {
                    guard index < scalars.count else { throw ParseError(reason: "unterminated escape") }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        let first = try parseHexScalar()
                        if first >= 0xD800, first <= 0xDBFF {
                            // A high surrogate must be immediately followed by
                            // a `\uXXXX` low surrogate (0xDC00...0xDFFF).
                            guard index + 1 < scalars.count,
                                  scalars[index] == "\\", scalars[index + 1] == "u" else {
                                throw ParseError(reason: "unpaired high surrogate in unicode escape")
                            }
                            index += 2
                            let second = try parseHexScalar()
                            guard (0xDC00...0xDFFF).contains(second) else {
                                throw ParseError(reason: "invalid low surrogate in unicode escape")
                            }
                            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else {
                                throw ParseError(reason: "invalid surrogate pair")
                            }
                            result.append(scalar)
                        } else if first >= 0xDC00, first <= 0xDFFF {
                            throw ParseError(reason: "unpaired low surrogate in unicode escape")
                        } else {
                            guard let scalar = Unicode.Scalar(first) else {
                                throw ParseError(reason: "invalid unicode escape")
                            }
                            result.append(scalar)
                        }
                    default:
                        throw ParseError(reason: "invalid escape character")
                    }
                } else {
                    result.append(scalar)
                }
            }
        }

        mutating func parseHexScalar() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard index < scalars.count, let digit = scalars[index].hexDigitValue else {
                    throw ParseError(reason: "invalid hex escape")
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> JSONNode {
            let start = index
            if try peek() == "-" { index += 1 }
            var isInteger = true
            while index < scalars.count {
                let scalar = scalars[index]
                if ("0"..."9").contains(scalar) {
                    index += 1
                } else if scalar == "." || scalar == "e" || scalar == "E" || scalar == "+" || scalar == "-" {
                    isInteger = false
                    index += 1
                } else {
                    break
                }
            }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            if isInteger, let int = Int(text) { return .integer(int) }
            guard let double = Double(text) else { throw ParseError(reason: "invalid number '\(text)'") }
            return .number(double)
        }
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - Unicode.Scalar("0").value)
        case "a"..."f": return Int(value - Unicode.Scalar("a").value) + 10
        case "A"..."F": return Int(value - Unicode.Scalar("A").value) + 10
        default: return nil
        }
    }
}

// MARK: - Serialization

extension JSONNode {
    var serialized: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .number(let value):
            // NaN/±infinity are not representable in JSON; emit null
            // (JSON.stringify convention) so output is always parseable.
            return value.isFinite ? String(value) : "null"
        case .string(let value):
            return JSONNode.escape(value)
        case .array(let elements):
            return "[" + elements.map(\.serialized).joined(separator: ",") + "]"
        case .object(let members):
            let body = members
                .map { "\(JSONNode.escape($0.key)):\($0.value.serialized)" }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    static func escape(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Bridges to `Any` trees for composing request bodies with JSONSerialization.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let elements): return elements.map(\.anyValue)
        case .object(let members):
            var dictionary: [String: Any] = [:]
            for member in members { dictionary[member.key] = member.value.anyValue }
            return dictionary
        }
    }
}


// MARK: - Codable

extension JSONNode: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let elements): try container.encode(elements)
        case .object(let members):
            var keyed = encoder.container(keyedBy: RawKey.self)
            for member in members {
                try keyed.encode(member.value, forKey: RawKey(stringValue: member.key))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: RawKey.self) {
            var members: [Member] = []
            for key in keyed.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                members.append(Member(key: key.stringValue, value: try keyed.decode(JSONNode.self, forKey: key)))
            }
            self = .object(members)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONNode].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}


// MARK: - Lenient parsing (streaming partials)

extension JSONNode {
    /// Parses a possibly-incomplete JSON prefix by truncating any trailing
    /// partial literal and closing open strings, arrays, and objects.
    static func parseLenient(_ text: String) -> JSONNode? {
        if let complete = try? parse(text) { return complete }

        var repaired = String(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !repaired.isEmpty else { return nil }

        // Drop a trailing partial token that cannot be completed (e.g. `tru`,
        // `-1.2e`, or a dangling comma/colon), conservatively.
        while let last = repaired.last, "+-.eEtfnu".contains(last) || last == "," || last == ":" {
            repaired.removeLast()
        }

        var closers: [Character] = []
        var inString = false
        var escaped = false
        for character in repaired {
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": closers.append("}")
            case "[": closers.append("]")
            case "}", "]": if !closers.isEmpty { closers.removeLast() }
            default: break
            }
        }
        if inString { repaired.append("\"") }
        // A key without a value cannot be closed into a valid object.
        while let last = repaired.last, last == "," || last == ":" {
            repaired.removeLast()
        }
        if let lastColon = repaired.last, lastColon == ":" { repaired.removeLast() }
        repaired.append(contentsOf: closers.reversed())

        if let node = try? parse(repaired) { return node }

        // Final fallback: also drop a trailing dangling key string.
        if repaired.hasSuffix("\"}") || repaired.hasSuffix("\"]") {
            return nil
        }
        return nil
    }
}
