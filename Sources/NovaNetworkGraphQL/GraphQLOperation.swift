import Foundation

/// Whether an operation reads or writes.
public enum GraphQLOperationKind: String, Sendable, Equatable {
    /// A read. Identical concurrent queries share one request, and may be sent as `GET`.
    case query
    /// A write. Never merged with another request, always `POST`.
    case mutation
}

/// Stands in for an operation's variables when it has none.
public struct GraphQLNoVariables: Encodable, Sendable, Equatable {
    /// Creates the empty variables value.
    public init() {}
}

/// One GraphQL operation: its document, its variables, and the shape of its data.
///
/// ```swift
/// struct CountryQuery: GraphQLOperation {
///     static let document = """
///     query Country($code: ID!) { country(code: $code) { name capital } }
///     """
///     static let operationName: String? = "Country"
///
///     struct Variables: Encodable, Sendable { let code: String }
///     struct Data: Decodable, Sendable {
///         struct Country: Decodable, Sendable { let name: String; let capital: String? }
///         let country: Country?
///     }
///
///     let variables: Variables
/// }
/// ```
public protocol GraphQLOperation: Sendable {
    /// The variables sent with the document. Use ``GraphQLNoVariables`` for none.
    associatedtype Variables: Encodable & Sendable = GraphQLNoVariables
    /// The type `data` decodes into.
    associatedtype Data: Decodable & Sendable

    /// The operation's GraphQL document.
    static var document: String { get }
    /// The name of the operation to run, when the document holds more than one.
    static var operationName: String? { get }
    /// Whether the operation reads or writes. Defaults to ``GraphQLOperationKind/query``.
    static var kind: GraphQLOperationKind { get }

    /// This instance's variables.
    var variables: Variables { get }
}

public extension GraphQLOperation {
    /// No operation name.
    static var operationName: String? { nil }
    /// A query.
    static var kind: GraphQLOperationKind { .query }
}

public extension GraphQLOperation where Variables == GraphQLNoVariables {
    /// No variables.
    var variables: GraphQLNoVariables { GraphQLNoVariables() }
}
