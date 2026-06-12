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
        let scalars: [Unicode.Scalar]
        var index = 0

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
                            try consume("\\u")
                            let second = try parseHexScalar()
                            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else {
                                throw ParseError(reason: "invalid surrogate pair")
                            }
                            result.append(scalar)
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
            return String(value)
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
