import Foundation

/// Request and attempt metadata for attaching to a caught ``NetworkError`` — for logging, crash
/// reporting, or support tooling — without ``NetworkError`` itself carrying request-shaped
/// associated values on every case (which would break exhaustive `switch` statements matching
/// its existing cases).
public struct NetworkErrorContext: Sendable, Equatable {
    /// The request's URL.
    public let url: URL
    /// The request's HTTP method.
    public let method: URLMethod
    /// The attempt number this error occurred on, starting at 1.
    public let attempt: Int
    /// The auth scope the request was made under, if any.
    public let authScope: String?

    /// Creates request error context.
    public init(url: URL, method: URLMethod, attempt: Int = 1, authScope: String? = nil) {
        self.url = url
        self.method = method
        self.attempt = attempt
        self.authScope = authScope
    }

    /// Creates request error context from a request.
    public init(request: APIRequest, attempt: Int = 1, authScope: String? = nil) {
        self.init(url: request.url, method: request.method, attempt: attempt, authScope: authScope)
    }
}

/// Pairs a ``NetworkError`` with the ``NetworkErrorContext`` that produced it.
public struct ContextualNetworkError: Error, Sendable, Equatable {
    /// The underlying network error.
    public let error: NetworkError
    /// The request and attempt context in effect when `error` occurred.
    public let context: NetworkErrorContext

    /// Creates a contextual network error.
    public init(error: NetworkError, context: NetworkErrorContext) {
        self.error = error
        self.context = context
    }
}

extension ContextualNetworkError: LocalizedError {
    public var errorDescription: String? {
        let base = error.errorDescription ?? String(describing: error)
        var suffix = "\(context.method.rawValue) \(context.url.absoluteString)"
        if context.attempt > 1 {
            suffix += ", attempt \(context.attempt)"
        }
        return "\(base) (\(suffix))"
    }
}

public extension NetworkError {
    /// Wraps this error together with request context, for logging or crash reporting.
    func with(context: NetworkErrorContext) -> ContextualNetworkError {
        ContextualNetworkError(error: self, context: context)
    }

    /// Wraps this error together with context captured from `request`.
    func with(request: APIRequest, attempt: Int = 1, authScope: String? = nil) -> ContextualNetworkError {
        with(context: NetworkErrorContext(request: request, attempt: attempt, authScope: authScope))
    }
}
