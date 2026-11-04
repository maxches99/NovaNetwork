import Foundation

/// Any JSON value, for the parts of a GraphQL response whose shape the spec leaves open.
public enum GraphQLJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GraphQLJSON])
    case object([String: GraphQLJSON])

    /// Decodes any JSON value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([GraphQLJSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: GraphQLJSON].self))
        }
    }

    /// Encodes the value as JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The string, when this is one.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// One entry of a GraphQL response's `errors` list.
public struct GraphQLError: Decodable, Sendable, Equatable, Error, CustomStringConvertible {
    /// One step of the path to the field that failed.
    public enum PathComponent: Decodable, Sendable, Equatable, CustomStringConvertible {
        /// A field name.
        case field(String)
        /// A list index.
        case index(Int)

        /// Decodes a string or an integer.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) {
                self = .index(index)
            } else {
                self = .field(try container.decode(String.self))
            }
        }

        /// The component as it reads in a path.
        public var description: String {
            switch self {
            case .field(let name): name
            case .index(let index): String(index)
            }
        }
    }

    /// A position in the document.
    public struct Location: Decodable, Sendable, Equatable {
        /// The line, from 1.
        public let line: Int
        /// The column, from 1.
        public let column: Int
    }

    /// What went wrong, for a developer.
    public let message: String
    /// Where in `data` the failed field is, when the error belongs to a field.
    public let path: [PathComponent]?
    /// Where in the document the problem is.
    public let locations: [Location]?
    /// Server-specific detail, usually including a `code`.
    public let extensions: [String: GraphQLJSON]?

    /// Creates an error.
    public init(
        message: String,
        path: [PathComponent]? = nil,
        locations: [Location]? = nil,
        extensions: [String: GraphQLJSON]? = nil
    ) {
        self.message = message
        self.path = path
        self.locations = locations
        self.extensions = extensions
    }

    /// `extensions.code`, when the server sent one.
    public var code: String? {
        extensions?["code"]?.stringValue
    }

    /// The message, with the path when there is one.
    public var description: String {
        guard let path, !path.isEmpty else { return message }
        return "\(path.map(\.description).joined(separator: ".")): \(message)"
    }
}

/// What a GraphQL server answered: data, errors, or — often — both.
///
/// GraphQL resolves fields independently, so one failed field leaves the rest of `data` intact. A
/// client that throws on the first error throws away the rest of the screen.
public struct GraphQLResponse<Data: Decodable & Sendable>: Decodable, Sendable {
    /// The data, or `nil` when the server returned none (`data: null`, or no `data` key).
    public let data: Data?
    /// Every error the server reported; empty when the operation succeeded fully.
    public let errors: [GraphQLError]
    /// The response's top-level `extensions`.
    public let extensions: [String: GraphQLJSON]?

    private enum CodingKeys: String, CodingKey {
        case data, errors, extensions
    }

    /// Decodes a response body.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        errors = try container.decodeIfPresent([GraphQLError].self, forKey: .errors) ?? []
        extensions = try container.decodeIfPresent([String: GraphQLJSON].self, forKey: .extensions)
    }

    /// Whether the server reported any error.
    public var hasErrors: Bool { !errors.isEmpty }
}

/// Thrown by ``GraphQLClient/data(for:authScope:)`` when the server reported errors.
public struct GraphQLResponseError<Data: Decodable & Sendable>: Error, Sendable, LocalizedError {
    /// What the server reported.
    public let errors: [GraphQLError]
    /// Whatever data came back beside the errors, for a screen that can show part of itself.
    public let partialData: Data?

    /// The errors, one per line.
    public var errorDescription: String? {
        errors.map(\.description).joined(separator: "\n")
    }
}

/// What the GraphQL client noticed about the protocol, beyond the HTTP request itself.
public enum GraphQLEvent: Sendable, Equatable {
    /// The server did not know the persisted query's hash, so the document was sent with it.
    case persistedQueryRegistered(operationName: String?)
    /// The server does not support persisted queries; this client stopped sending hashes.
    case persistedQueriesUnsupported
    /// A response carried errors.
    case partialResponse(operationName: String?, errorCount: Int, hasData: Bool)
}
