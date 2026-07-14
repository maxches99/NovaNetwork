import Foundation

/// A typed description of one network operation.
///
/// Endpoints keep request construction and response decoding together while the
/// the umbrella client continues to own transport, coalescing, caching, and retry behavior.
public protocol Endpoint<Response>: Sendable {
    /// The value produced after a successful request and decode operation.
    associatedtype Response: Sendable

    /// Builds the request executed by the client.
    ///
    /// - Returns: A complete request value.
    /// - Throws: An endpoint-specific request construction error.
    func makeRequest() throws -> APIRequest

    /// Decodes response bytes into the endpoint's response type.
    ///
    /// - Parameters:
    ///   - data: The response body returned by the normal client pipeline.
    ///   - decoder: The decoder selected by the caller or client.
    /// - Returns: The typed endpoint response.
    /// - Throws: A decoding error, which the umbrella client maps to
    ///   ``NetworkError/decoding(underlying:)``.
    func decode(_ data: Data, using decoder: JSONDecoder) throws -> Response
}

public extension Endpoint where Response: Decodable {
    /// Decodes a `Decodable` endpoint response using the supplied JSON decoder.
    func decode(_ data: Data, using decoder: JSONDecoder) throws -> Response {
        try decoder.decode(Response.self, from: data)
    }
}

/// A type-erased endpoint backed by request and decode closures.
public struct AnyEndpoint<Response: Sendable>: Endpoint {
    private let requestProvider: @Sendable () throws -> APIRequest
    private let responseDecoder: @Sendable (Data, JSONDecoder) throws -> Response

    /// Creates a closure-backed endpoint.
    ///
    /// - Parameters:
    ///   - request: Closure that constructs the request for each execution.
    ///   - decode: Closure that converts response bytes into `Response`.
    public init(
        request: @escaping @Sendable () throws -> APIRequest,
        decode: @escaping @Sendable (Data, JSONDecoder) throws -> Response
    ) {
        requestProvider = request
        responseDecoder = decode
    }

    /// Builds the endpoint request.
    public func makeRequest() throws -> APIRequest {
        try requestProvider()
    }

    /// Invokes the endpoint's custom response decoder.
    public func decode(_ data: Data, using decoder: JSONDecoder) throws -> Response {
        try responseDecoder(data, decoder)
    }
}

public extension AnyEndpoint where Response: Decodable {
    /// Creates a JSON-decoded endpoint for a fixed request.
    ///
    /// - Parameters:
    ///   - request: Request executed by the client.
    ///   - response: The response type inferred or supplied by the caller.
    init(request: APIRequest, response: Response.Type = Response.self) {
        self.init(
            request: { request },
            decode: { data, decoder in
                try decoder.decode(response, from: data)
            }
        )
    }
}
