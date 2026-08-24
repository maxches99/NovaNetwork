import Foundation
import NovaNetworkClient

/// Thrown by ``RoutingTransport`` when a request matches no registered route.
public struct RoutingTransportError: Error, Sendable, CustomStringConvertible {
    /// The unmatched request.
    public let request: APIRequest

    public var description: String {
        "RoutingTransport: no route matched \(request.method.rawValue) \(request.url.absoluteString)"
    }
}

/// A mock transport that dispatches each request to the first registered route whose
/// ``RequestMatcher`` matches it, for testing code against realistic multi-endpoint scenarios
/// without a real server.
///
/// Routes are tried in registration order. A request matching no route throws
/// ``RoutingTransportError``, naming the unmatched method and URL, rather than hanging or
/// returning a misleading default response.
public actor RoutingTransport: NetworkTransport {
    /// Produces a response (or throws) for a matched request.
    public typealias ResponseProvider = @Sendable (APIRequest) async throws -> NetworkResponse

    private struct Route {
        let matcher: RequestMatcher
        let provide: ResponseProvider
        var remainingUses: Int?
        var callCount = 0
    }

    private var routes: [Route] = []
    private var unmatched: [APIRequest] = []

    /// Creates an empty router; register routes with ``register(_:times:respond:)``.
    public init() {}

    /// Registers a route that computes its response with `respond`.
    ///
    /// - Parameter times: Maximum number of requests this route accepts before later routes are
    ///   tried instead, or `nil` for unlimited.
    public func register(
        _ matcher: RequestMatcher,
        times: Int? = nil,
        respond: @escaping ResponseProvider
    ) {
        routes.append(Route(matcher: matcher, provide: respond, remainingUses: times))
    }

    /// Registers a route that always returns the same fixed response.
    public func register(
        _ matcher: RequestMatcher,
        times: Int? = nil,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        register(matcher, times: times) { _ in
            NetworkResponse(statusCode: statusCode, headers: headers, body: body)
        }
    }

    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        for index in routes.indices {
            guard routes[index].matcher.matches(request) else { continue }
            if let remaining = routes[index].remainingUses {
                guard remaining > 0 else { continue }
                routes[index].remainingUses = remaining - 1
            }
            routes[index].callCount += 1
            return try await routes[index].provide(request)
        }
        unmatched.append(request)
        throw RoutingTransportError(request: request)
    }

    /// Requests that matched no registered route, in the order they arrived.
    public func unmatchedRequests() -> [APIRequest] {
        unmatched
    }

    /// Total number of requests successfully dispatched to any route.
    public func totalCallCount() -> Int {
        routes.reduce(0) { $0 + $1.callCount }
    }
}
