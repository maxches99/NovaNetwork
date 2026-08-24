import Foundation

/// Turns names from a specification document into Swift identifiers.
///
/// The rules are deterministic and documented rather than clever: the same spec must always produce
/// the same names, because generated files are checked in and reviewed like any other source.
public enum SwiftNaming {
    /// Swift keywords that cannot be used as bare identifiers.
    static let reservedWords: Set<String> = [
        "associatedtype", "borrowing", "case", "catch", "class", "consuming", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil",
        "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "where", "while",
    ]

    /// Splits a raw name into words on separators and camel-case boundaries.
    static func words(in raw: String) -> [String] {
        var words: [String] = []
        var current = ""

        for character in raw {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty { words.append(current) }
        return words
    }

    /// An upper-camel-case type name, for example `PetStatus` from `pet_status`.
    public static func typeName(_ raw: String) -> String {
        let joined = words(in: raw)
            .map { $0.allSatisfy(\.isUppercase) ? $0.lowercased() : $0 }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()

        guard let first = joined.first else { return "Value" }
        return first.isNumber ? "_" + joined : joined
    }

    /// A lower-camel-case property name, escaped when it collides with a keyword.
    public static func propertyName(_ raw: String) -> String {
        let type = typeName(raw)
        let lowered = type.prefix(1).lowercased() + type.dropFirst()
        return reservedWords.contains(lowered) ? "`\(lowered)`" : lowered
    }

    /// A lower-camel-case enum case name, escaped when it collides with a keyword.
    public static func enumCaseName(_ raw: String) -> String {
        propertyName(raw)
    }

    /// The type name for an operation, from its `operationId` when it has one.
    ///
    /// Without an `operationId`, the name is derived from the method and path: literal segments are
    /// capitalized and a `{parameter}` becomes `By` followed by its name, so `GET /users/{id}/posts`
    /// becomes `GetUsersByIdPosts`.
    public static func operationTypeName(method: String, path: String, operationID: String?) -> String {
        if let operationID, !operationID.isEmpty {
            return typeName(operationID)
        }

        let segments = path.split(separator: "/").map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}") else {
                return typeName(String(segment))
            }
            return "By" + typeName(String(segment.dropFirst().dropLast()))
        }

        return segments.isEmpty ? typeName(method) + "Root" : typeName(method) + segments.joined()
    }

    /// The namespace type name for a document title, for example `PetstoreAPI`.
    public static func namespaceName(title: String) -> String {
        let base = typeName(title)
        let name = base.isEmpty ? "Generated" : base
        guard name.lowercased().hasSuffix("api") else { return name + "API" }
        return name.dropLast(3) + "API"
    }

    /// Appends `2`, `3`, … until the name is unused, so two operations never collide silently.
    public static func disambiguated(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        var suffix = 2
        while taken.contains("\(name)\(suffix)") {
            suffix += 1
        }
        let unique = "\(name)\(suffix)"
        taken.insert(unique)
        return unique
    }
}
