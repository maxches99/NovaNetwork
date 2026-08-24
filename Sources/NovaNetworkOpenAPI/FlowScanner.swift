import Foundation

/// Reads flow collections — `{...}` and `[...]` — which YAML allows inline and which JSON uses for
/// the whole document.
///
/// Because a JSON document is one flow mapping, this is also the JSON reader: parsing both formats
/// through the same scanner keeps key order intact for both, which a `JSONSerialization`-based
/// reader could not promise.
struct FlowScanner {
    private let characters: [[Character]]
    /// The line the scanner is currently on, zero-based.
    private(set) var lineIndex: Int
    /// The line on which the outermost collection closed, zero-based.
    private(set) var closingLine: Int
    private var column: Int

    init(lines: [String], lineIndex: Int, column: Int) {
        characters = lines.map(Array.init)
        self.lineIndex = lineIndex
        closingLine = lineIndex
        self.column = column
    }

    // MARK: Cursor

    private var current: Character? {
        guard lineIndex < characters.count, column < characters[lineIndex].count else { return nil }
        return characters[lineIndex][column]
    }

    /// The character after the cursor on the same line, used to spot the `": "` key indicator.
    private var next: Character? {
        guard lineIndex < characters.count, column + 1 < characters[lineIndex].count else { return nil }
        return characters[lineIndex][column + 1]
    }

    private var atEnd: Bool {
        lineIndex >= characters.count
    }

    private mutating func advance() {
        guard lineIndex < characters.count else { return }
        column += 1
        if column >= characters[lineIndex].count {
            lineIndex += 1
            column = 0
        }
    }

    private mutating func skipInsignificant() {
        while lineIndex < characters.count {
            guard let character = current else {
                lineIndex += 1
                column = 0
                continue
            }
            if character == " " || character == "\t" {
                advance()
            } else if character == "#" {
                lineIndex += 1
                column = 0
            } else {
                return
            }
        }
    }

    private func error(_ message: String) -> SpecParseError {
        SpecParseError(message: message, line: min(lineIndex, characters.count - 1) + 1, column: column + 1)
    }

    // MARK: Parsing

    mutating func parseValue() throws -> SpecValue {
        skipInsignificant()
        guard let character = current else {
            throw error("Unterminated flow collection; the document ends before it is closed.")
        }

        switch character {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"", "'": return .string(try parseQuoted())
        default: return try parsePlain()
        }
    }

    /// Confirms nothing but whitespace or a comment follows the collection on its closing line.
    mutating func expectEnd() throws {
        while lineIndex == closingLine, let character = current {
            if character == " " || character == "\t" {
                advance()
                continue
            }
            if character == "#" { return }
            throw error("Unexpected '\(character)' after a flow collection.")
        }
    }

    private mutating func parseObject() throws -> SpecValue {
        advance()
        var object = SpecObject()

        while true {
            skipInsignificant()
            guard let character = current else {
                throw error("Unterminated flow mapping; expected '}'.")
            }
            if character == "}" {
                closingLine = lineIndex
                advance()
                return .object(object)
            }

            let key: String
            if character == "\"" || character == "'" {
                key = try parseQuoted()
            } else {
                key = try plainText(terminators: [":", ",", "}"])
            }

            skipInsignificant()
            guard current == ":" else {
                throw error("Expected ':' after the key '\(key)'.")
            }
            advance()

            object[key] = try parseValue()

            skipInsignificant()
            if current == "," {
                advance()
            } else if current == nil {
                throw error("Unterminated flow mapping; expected '}'.")
            } else if current != "}" {
                throw error("Expected ',' or '}' in a flow mapping.")
            }
        }
    }

    private mutating func parseArray() throws -> SpecValue {
        advance()
        var items: [SpecValue] = []

        while true {
            skipInsignificant()
            guard let character = current else {
                throw error("Unterminated flow sequence; expected ']'.")
            }
            if character == "]" {
                closingLine = lineIndex
                advance()
                return .array(items)
            }

            items.append(try parseValue())

            skipInsignificant()
            if current == "," {
                advance()
            } else if current == nil {
                throw error("Unterminated flow sequence; expected ']'.")
            } else if current != "]" {
                throw error("Expected ',' or ']' in a flow sequence.")
            }
        }
    }

    private mutating func parseQuoted() throws -> String {
        guard let quote = current else { throw error("Expected a quoted string.") }
        let startLine = lineIndex + 1
        let startColumn = column + 1
        advance()

        var raw = ""
        while let character = current {
            if character == "\\", quote == "\"" {
                raw.append(character)
                advance()
                guard let escaped = current else { break }
                raw.append(escaped)
                advance()
                continue
            }
            if character == quote {
                advance()
                if quote == "'", current == "'" {
                    raw.append("'")
                    advance()
                    continue
                }
                return quote == "'" ? raw : try Self.unescape(raw, line: startLine, column: startColumn)
            }
            raw.append(character)
            advance()
        }

        throw SpecParseError(message: "Unterminated quoted string.", line: startLine, column: startColumn)
    }

    private mutating func parsePlain() throws -> SpecValue {
        let text = try plainText(terminators: [",", "}", "]"])
        switch text {
        case "null", "~", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if let number = Double(text), text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil {
            return .number(number)
        }
        guard !text.isEmpty else { throw error("Expected a value.") }
        return .string(text)
    }

    /// Reads an unquoted token up to one of `terminators` or the end of the line.
    private mutating func plainText(terminators: Set<Character>) throws -> String {
        var text = ""
        let startLine = lineIndex

        while let character = current, !terminators.contains(character) {
            if character == "#", text.last == " " { break }
            // `: ` is YAML's key indicator, so it can never appear inside a plain scalar.
            if character == ":", next == nil || next == " " { break }
            text.append(character)
            advance()
            if lineIndex != startLine { break }
        }

        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Escapes

    /// Applies JSON/YAML double-quoted escape sequences.
    static func unescape(_ text: String, line: Int, column: Int) throws -> String {
        guard text.contains("\\") else { return text }

        var result = ""
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                throw SpecParseError(message: "Trailing backslash in a quoted string.", line: line, column: column)
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "0": result.append("\u{00}")
            case "\"", "'", "\\", "/": result.append(escaped)
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    guard let digit = iterator.next() else { break }
                    hex.append(digit)
                }
                guard hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw SpecParseError(
                        message: "Invalid \\u escape '\\u\(hex)' in a quoted string.",
                        line: line,
                        column: column
                    )
                }
                result.append(Character(scalar))
            default:
                throw SpecParseError(
                    message: "Unsupported escape '\\\(escaped)' in a quoted string.",
                    line: line,
                    column: column
                )
            }
        }

        return result
    }
}
