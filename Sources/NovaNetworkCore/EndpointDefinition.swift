import Foundation

/// An ``Endpoint`` whose request is assembled from a base URL and declared parameters rather than
/// written by hand.
///
/// This is the contract both declarative front ends target. The `@Endpoint` macro generates a
/// conformance for a hand-written type; the OpenAPI generator emits conformances for every
/// operation in a spec. Because they share this protocol and ``EndpointRequestBuilder``, the two
/// produce requests that behave identically — and a conformance written entirely by hand is a
/// first-class citizen alongside them.
///
/// The only requirements without defaults are ``baseURL`` and `Endpoint`'s `makeRequest()`:
///
/// ```swift
/// struct GetUser: EndpointDefinition {
///     typealias Response = User
///     let baseURL = URL(string: "https://api.example.com")!
///     let id: Int
///
///     func makeRequest() throws -> APIRequest {
///         var builder = EndpointRequestBuilder(method: .get, baseURL: baseURL, path: "/users/{id}")
///         try builder.setPath("id", id)
///         return try builder.build(timeout: timeout, additionalHeaders: additionalHeaders)
///     }
/// }
/// ```
///
/// A shared protocol is the usual way to supply ``baseURL`` once for a whole API:
///
/// ```swift
/// protocol ExampleAPI: EndpointDefinition {}
/// extension ExampleAPI {
///     var baseURL: URL { URL(string: "https://api.example.com")! }
/// }
/// ```
public protocol EndpointDefinition: Endpoint {
    /// The URL the endpoint's path is resolved against.
    var baseURL: URL { get }
    /// Request timeout in seconds. Defaults to 60, matching ``APIRequest``.
    var timeout: TimeInterval { get }
    /// Headers applied to every request from this endpoint, before parameter-supplied headers.
    ///
    /// Defaults to none. A parameter-supplied header of the same name takes precedence.
    var additionalHeaders: [String: String] { get }
    /// The encoder used for JSON request bodies. Defaults to a plain `JSONEncoder`.
    ///
    /// Declare this as a computed property rather than a stored one: `JSONEncoder` is not
    /// `Sendable`, and `Endpoint` requires `Sendable` conformance.
    var jsonEncoder: JSONEncoder { get }
}

public extension EndpointDefinition {
    /// Sixty seconds, matching ``APIRequest``'s default.
    var timeout: TimeInterval { 60 }
    /// No endpoint-wide headers.
    var additionalHeaders: [String: String] { [:] }
    /// A plain `JSONEncoder`.
    var jsonEncoder: JSONEncoder { JSONEncoder() }

    /// Creates a request builder already pointed at this endpoint's ``baseURL``.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - path: A path template such as `/users/{id}`.
    func requestBuilder(_ method: URLMethod, _ path: String) -> EndpointRequestBuilder {
        EndpointRequestBuilder(method: method, baseURL: baseURL, path: path)
    }
}

/// The response of an operation that returns no content, such as a `204 No Content` delete.
///
/// Decoding a ``NoContent`` response never runs `JSONDecoder`, so an empty body is not an error.
public struct NoContent: Sendable, Hashable, Codable {
    /// Creates the empty response value.
    public init() {}
}

public extension Endpoint where Response == NoContent {
    /// Ignores the response body and returns ``NoContent``.
    func decode(_ data: Data, using decoder: JSONDecoder) throws -> NoContent {
        NoContent()
    }
}
