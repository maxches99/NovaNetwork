import Foundation

/// A located failure while reading a specification document.
public struct SpecParseError: Error, Equatable, LocalizedError {
    /// What went wrong.
    public let message: String
    /// One-based line number.
    public let line: Int
    /// One-based column number.
    public let column: Int

    /// Creates a located parse error.
    public init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// The error formatted as `line:column: message`.
    public var errorDescription: String? { "\(line):\(column): \(message)" }
}

/// Reads JSON and a documented subset of YAML into ``SpecValue``.
///
/// The subset covers what OpenAPI documents actually use: block mappings and sequences, flow
/// mappings and sequences (which is also all of JSON), plain and quoted scalars, `|` and `>` block
/// scalars, comments, and a leading `---`. Anchors, aliases, tags, merge keys, and multi-document
/// streams are rejected with a located error rather than guessed at — a generator that silently
/// misreads a spec is worse than one that stops and says where it stopped.
public enum SpecParser {
    /// Parses a document.
    ///
    /// - Parameter text: The document contents, JSON or YAML.
    /// - Returns: The parsed value; an empty document parses as ``SpecValue/null``.
    /// - Throws: ``SpecParseError`` with the location of the first construct it could not read.
    public static func parse(_ text: String) throws -> SpecValue {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }
}

// MARK: - Parser

private struct Parser {
    private var lines: [String]
    private var index = 0

    init(text: String) {
        lines = text.components(separatedBy: .newlines)
    }

    // MARK: Line access

    private var currentLine: String? { index < lines.count ? lines[index] : nil }

    private func lineNumber(_ offset: Int = 0) -> Int { index + offset + 1 }

    /// The indentation of a line, rejecting tabs, which YAML forbids for indentation.
    private func indentation(of line: String, number: Int) throws -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                throw SpecParseError(
                    message: "Tabs are not allowed for indentation. Use spaces.",
                    line: number,
                    column: count + 1
                )
            } else {
                break
            }
        }
        return count
    }

    /// Whether a line carries no content: blank, or a comment only.
    private func isIgnorable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// Advances to the next line that carries content, returning it with its indentation.
    private mutating func nextContentLine() throws -> (indent: Int, content: String, number: Int)? {
        while let line = currentLine {
            if isIgnorable(line) {
                index += 1
                continue
            }
            let number = lineNumber()
            let indent = try indentation(of: line, number: number)
            let content = try stripComment(String(line.dropFirst(indent)), line: number, column: indent + 1)
            if content.isEmpty {
                index += 1
                continue
            }
            return (indent, content, number)
        }
        return nil
    }

    /// Whether a quote character at this position opens a quoted scalar.
    ///
    /// YAML only treats a quote as a delimiter at the start of a scalar, so the apostrophe in
    /// `NovaNetwork's generator` is ordinary text rather than an unterminated string.
    static func startsQuotedScalar(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous == " " || previous == ":" || previous == "," || previous == "["
            || previous == "{" || previous == "-"
    }

    /// Removes a trailing `#` comment that is not inside quotes.
    private func stripComment(_ content: String, line: Int, column: Int) throws -> String {
        var result = ""
        var quote: Character?
        var previous: Character?

        for character in content {
            if let active = quote {
                result.append(character)
                if character == active, previous != "\\" || active == "'" {
                    quote = nil
                }
            } else if character == "\"" || character == "'", Self.startsQuotedScalar(after: previous) {
                quote = character
                result.append(character)
            } else if character == "#", previous == nil || previous == " " {
                break
            } else {
                result.append(character)
            }
            previous = character
        }

        if quote != nil {
            throw SpecParseError(message: "Unterminated quoted string.", line: line, column: column)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Document

    mutating func parseDocument() throws -> SpecValue {
        guard var first = try nextContentLine() else { return .null }

        if first.content == "---" {
            index += 1
            guard let next = try nextContentLine() else { return .null }
            first = next
        }

        let value = try parseBlock(minIndent: first.indent)

        if let trailing = try nextContentLine() {
            guard trailing.content == "..." else {
                throw SpecParseError(
                    message: "Unexpected content after the document. Multi-document streams are not supported.",
                    line: trailing.number,
                    column: trailing.indent + 1
                )
            }
        }
        return value
    }

    // MARK: Block structure

    private mutating func parseBlock(minIndent: Int) throws -> SpecValue {
        guard let line = try nextContentLine(), line.indent >= minIndent else { return .null }

        if line.content.hasPrefix("{") || line.content.hasPrefix("[") {
            return try parseFlow(from: index, column: line.indent)
        }
        if line.content == "-" || line.content.hasPrefix("- ") {
            return try parseSequence(indent: line.indent)
        }
        if keySplit(line.content) != nil {
            return try parseMapping(indent: line.indent)
        }

        index += 1
        return try scalar(from: line.content, line: line.number, column: line.indent + 1)
    }

    private mutating func parseMapping(indent: Int) throws -> SpecValue {
        var object = SpecObject()

        while let line = try nextContentLine(), line.indent >= indent {
            guard !isDocumentMarker(line.content) else { break }
            guard line.indent == indent else {
                throw SpecParseError(
                    message: "Unexpected indentation; expected \(indent) spaces.",
                    line: line.number,
                    column: line.indent + 1
                )
            }
            guard let (key, rest) = keySplit(line.content) else {
                throw SpecParseError(
                    message: "Expected 'key: value'.",
                    line: line.number,
                    column: line.indent + 1
                )
            }

            let name = try scalarText(key, line: line.number, column: line.indent + 1)
            let valueLine = index
            let valueColumn = line.indent + line.content.count - rest.count
            index += 1
            object[name] = try parseValue(
                rest: rest,
                parentIndent: indent,
                valueLine: valueLine,
                column: valueColumn
            )
        }

        return .object(object)
    }

    private mutating func parseSequence(indent: Int) throws -> SpecValue {
        var items: [SpecValue] = []

        while let line = try nextContentLine(), line.indent >= indent {
            guard !isDocumentMarker(line.content) else { break }
            guard line.indent == indent, line.content == "-" || line.content.hasPrefix("- ") else { break }

            let afterDash = String(line.content.dropFirst()).drop(while: { $0 == " " })
            let contentColumn = indent + line.content.count - afterDash.count

            if afterDash.isEmpty {
                index += 1
                items.append(try parseBlock(minIndent: indent + 1))
            } else {
                // Rewrite the entry as a plain line so a mapping written as `- name: x` parses the
                // same way as the indented form, with its continuation lines already aligned.
                lines[index] = String(repeating: " ", count: contentColumn) + afterDash
                items.append(try parseBlock(minIndent: contentColumn))
            }
        }

        return .array(items)
    }

    /// Reads the value that follows `key:`.
    ///
    /// - Parameters:
    ///   - rest: The text after the colon, which may be empty for a nested block.
    ///   - parentIndent: The mapping's indentation.
    ///   - valueLine: Zero-based index of the line the key was written on. Flow collections start
    ///     there rather than on the parser's current line, which has already moved past the key.
    ///   - column: Zero-based column where the value text begins.
    private mutating func parseValue(rest: String, parentIndent: Int, valueLine: Int, column: Int) throws -> SpecValue {
        let line = valueLine + 1
        if rest.isEmpty {
            guard let next = try nextContentLine(), next.indent > parentIndent else { return .null }
            return try parseBlock(minIndent: next.indent)
        }
        if rest.hasPrefix("|") || rest.hasPrefix(">") {
            return try parseBlockScalar(header: rest, parentIndent: parentIndent, line: line, column: column + 1)
        }
        if rest.hasPrefix("{") || rest.hasPrefix("[") {
            return try parseFlow(from: valueLine, column: column)
        }
        return try scalar(from: rest, line: line, column: column + 1)
    }

    // MARK: Block scalars

    private mutating func parseBlockScalar(header: String, parentIndent: Int, line: Int, column: Int) throws -> SpecValue {
        let folded = header.hasPrefix(">")
        let chomping = header.dropFirst().trimmingCharacters(in: .whitespaces)
        guard chomping.isEmpty || chomping == "-" || chomping == "+" else {
            throw SpecParseError(
                message: "Unsupported block scalar header '\(header)'. Only '|', '>', '|-', '|+', '>-', and '>+' are supported.",
                line: line,
                column: column
            )
        }

        var collected: [String] = []
        var blockIndent: Int?

        while let raw = currentLine {
            if isIgnorable(raw) {
                let number = lineNumber()
                if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    collected.append("")
                    index += 1
                    continue
                }
                if try indentation(of: raw, number: number) > parentIndent {
                    collected.append("")
                    index += 1
                    continue
                }
                break
            }
            let number = lineNumber()
            let indent = try indentation(of: raw, number: number)
            guard indent > parentIndent else { break }
            if blockIndent == nil { blockIndent = indent }
            collected.append(String(raw.dropFirst(min(blockIndent ?? indent, indent))))
            index += 1
        }

        while collected.last?.isEmpty == true {
            collected.removeLast()
        }

        var text = folded ? collected.joined(separator: " ") : collected.joined(separator: "\n")
        if chomping == "+" {
            text += "\n"
        }
        return .string(text)
    }

    // MARK: Flow collections

    private mutating func parseFlow(from lineIndex: Int, column: Int) throws -> SpecValue {
        var scanner = FlowScanner(lines: lines, lineIndex: lineIndex, column: column)
        let value = try scanner.parseValue()
        try scanner.expectEnd()
        index = scanner.closingLine + 1
        return value
    }

    /// Whether a line is a `---` or `...` document marker.
    private func isDocumentMarker(_ content: String) -> Bool {
        content == "---" || content == "..."
    }

    // MARK: Scalars

    /// Splits `key: value`, returning `nil` when the line is not a mapping entry.
    private func keySplit(_ content: String) -> (key: String, rest: String)? {
        var quote: Character?
        var depth = 0
        var previous: Character?
        var offset = content.startIndex

        while offset < content.endIndex {
            let character = content[offset]
            if let active = quote {
                if character == active, previous != "\\" || active == "'" { quote = nil }
            } else {
                switch character {
                case "\"", "'":
                    if Self.startsQuotedScalar(after: previous) { quote = character }
                case "{", "[": depth += 1
                case "}", "]": depth -= 1
                case ":" where depth == 0:
                    let next = content.index(after: offset)
                    if next == content.endIndex || content[next] == " " {
                        let key = String(content[content.startIndex..<offset]).trimmingCharacters(in: .whitespaces)
                        let rest = String(content[next...]).trimmingCharacters(in: .whitespaces)
                        return key.isEmpty ? nil : (key, rest)
                    }
                default: break
                }
            }
            previous = character
            offset = content.index(after: offset)
        }
        return nil
    }

    /// Interprets a scalar, rejecting the YAML features the subset does not cover.
    private func scalar(from text: String, line: Int, column: Int) throws -> SpecValue {
        if let first = text.first, first == "&" || first == "*" || first == "!" {
            throw SpecParseError(
                message: "Anchors, aliases, and tags are not supported. Inline the value instead.",
                line: line,
                column: column
            )
        }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            return .string(try scalarText(text, line: line, column: column))
        }
        switch text {
        case "null", "~", "Null", "NULL": return .null
        case "true", "True", "TRUE", "yes", "on": return .bool(true)
        case "false", "False", "FALSE", "no", "off": return .bool(false)
        default: break
        }
        if let number = Double(text), text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil {
            return .number(number)
        }
        return .string(text)
    }

    /// Unquotes a scalar, applying escapes for double-quoted text.
    private func scalarText(_ text: String, line: Int, column: Int) throws -> String {
        guard let first = text.first, first == "\"" || first == "'" else { return text }
        guard text.count >= 2, text.last == first else {
            throw SpecParseError(message: "Unterminated quoted string.", line: line, column: column)
        }
        let inner = String(text.dropFirst().dropLast())
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return try FlowScanner.unescape(inner, line: line, column: column)
    }
}
