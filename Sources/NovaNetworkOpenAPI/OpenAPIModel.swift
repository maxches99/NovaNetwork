import Foundation

/// A reference to a Swift type in generated source.
public indirect enum SwiftTypeReference: Sendable, Equatable {
    case named(String)
    case array(SwiftTypeReference)
    case dictionary(SwiftTypeReference)
    case optional(SwiftTypeReference)
    /// A boxed reference, used where a struct would otherwise contain itself.
    case indirect(SwiftTypeReference)

    /// The type as it is written in generated code.
    public var rendered: String {
        switch self {
        case let .named(name): name
        case let .array(element): "[\(element.rendered)]"
        case let .dictionary(value): "[String: \(value.rendered)]"
        case let .optional(wrapped): "\(wrapped.rendered)?"
        case let .indirect(wrapped): "Indirect<\(wrapped.rendered)>"
        }
    }

    /// The same type made optional, without stacking a second layer of optionality.
    public var madeOptional: SwiftTypeReference {
        if case .optional = self { return self }
        return .optional(self)
    }

    /// Whether the type mentions `Date` anywhere, so the generated decoder can be configured.
    public var mentionsDate: Bool {
        switch self {
        case let .named(name): name == "Date"
        case let .array(element): element.mentionsDate
        case let .dictionary(value): value.mentionsDate
        case let .optional(wrapped): wrapped.mentionsDate
        case let .indirect(wrapped): wrapped.mentionsDate
        }
    }

    /// The underlying named type, looking through arrays, dictionaries, and optionals.
    public var baseName: String? {
        switch self {
        case let .named(name): name
        case let .array(element): element.baseName
        case let .dictionary(value): value.baseName
        case let .optional(wrapped): wrapped.baseName
        case let .indirect(wrapped): wrapped.baseName
        }
    }
}

/// One property of a generated model type.
public struct GeneratedProperty: Sendable, Equatable {
    /// The Swift property name.
    public let swiftName: String
    /// The name used on the wire, which drives `CodingKeys` when it differs.
    public let wireName: String
    /// The property's type.
    public let type: SwiftTypeReference
    /// Documentation copied from the schema.
    public let documentation: String?
}

/// A model type the generator emits.
public enum GeneratedType: Sendable, Equatable {
    /// A `Codable` struct.
    case object(name: String, properties: [GeneratedProperty], documentation: String?)
    /// A raw-value enum for a string schema with an `enum` list.
    case stringEnum(name: String, cases: [GeneratedEnumCase], documentation: String?)
    /// A type alias for a schema that is only a renamed primitive or container.
    case alias(name: String, target: SwiftTypeReference, documentation: String?)
    /// The fallback JSON value type, emitted only when some schema needs it.
    case anyJSON(name: String)
    /// The box that breaks a recursive type, emitted only when some schema needs it.
    case indirectBox(name: String)

    /// The type's name.
    public var name: String {
        switch self {
        case let .object(name, _, _), let .stringEnum(name, _, _), let .alias(name, _, _),
             let .anyJSON(name), let .indirectBox(name): name
        }
    }
}

/// One case of a generated string enum.
public struct GeneratedEnumCase: Sendable, Equatable {
    /// The Swift case name.
    public let swiftName: String
    /// The raw value sent over the wire.
    public let wireValue: String
}

/// Where a parameter is carried.
public enum ParameterLocation: String, Sendable, Equatable {
    case path
    case query
    case header
}

/// One operation parameter.
public struct OpenAPIParameter: Sendable, Equatable {
    /// The name used on the wire.
    public let wireName: String
    /// The Swift property name.
    public let swiftName: String
    /// Where the parameter is carried.
    public let location: ParameterLocation
    /// The parameter's Swift type, already made optional when the parameter is not required.
    public let type: SwiftTypeReference
    /// How arrays are written into the query string.
    public let queryStyle: String
    /// Documentation copied from the spec.
    public let documentation: String?
}

/// The request body of an operation.
public struct OpenAPIRequestBody: Sendable, Equatable {
    /// The Swift property name holding the body value.
    public let swiftName: String
    /// The body's Swift type.
    public let type: SwiftTypeReference
    /// The content type sent with the body.
    public let contentType: String
}

/// One generated operation.
public struct OpenAPIOperation: Sendable, Equatable {
    /// The generated Swift type name.
    public let typeName: String
    /// The HTTP method, lowercased, as written in the spec.
    public let method: String
    /// The path template, including `{placeholders}`.
    public let path: String
    /// The response type, or `nil` when the operation returns no content.
    public let responseType: SwiftTypeReference?
    /// Parameters in path, query, then header order.
    public let parameters: [OpenAPIParameter]
    /// The request body, when the operation has one.
    public let requestBody: OpenAPIRequestBody?
    /// Documentation assembled from summary and description.
    public let documentation: String?
    /// Whether the spec marks the operation deprecated.
    public let isDeprecated: Bool
}

/// Everything the emitter needs, read out of one specification document.
public struct OpenAPIDocument: Sendable, Equatable {
    /// `info.title`, used to name the generated namespace.
    public let title: String
    /// `info.version`, recorded in the file header.
    public let version: String
    /// The first server URL, when the document declares one.
    public let serverURL: String?
    /// Model types in the order their schemas appear.
    public let types: [GeneratedType]
    /// Operations in document order.
    public let operations: [OpenAPIOperation]
}

/// Something the generator could not represent faithfully, reported rather than applied silently.
public struct GenerationWarning: Sendable, Equatable {
    /// Where in the document the problem is, in JSON-pointer style.
    public let location: String
    /// What the generator did instead.
    public let message: String

    /// Creates a warning.
    public init(location: String, message: String) {
        self.location = location
        self.message = message
    }

    /// The warning formatted for a build log.
    public var formatted: String { "warning: \(location): \(message)" }
}

/// A failure that stops generation.
public struct GenerationError: Error, Equatable, LocalizedError {
    /// What went wrong.
    public let message: String
    /// Where in the document it went wrong.
    public let location: String

    /// Creates a generation error.
    public init(message: String, location: String) {
        self.message = message
        self.location = location
    }

    /// The error formatted for a build log.
    public var errorDescription: String? { "\(location): \(message)" }
}
