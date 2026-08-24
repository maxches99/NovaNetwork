import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stable, payload-free categories used by policies and telemetry.
public enum NetworkFailureReason: Sendable, Equatable {
    /// The transport returned a non-HTTP or otherwise invalid response.
    case invalidResponse
    /// The server returned a non-success HTTP status.
    case httpStatus(code: Int)
    /// Response decoding failed.
    case decoding
    /// The underlying transport failed.
    case transport
    /// Work was cancelled.
    case cancelled
    /// The underlying transport timed out.
    case timedOut
    /// The request deadline budget was exhausted.
    case timeoutBudgetExhausted
    /// A server or client rate limit rejected the request.
    case rateLimited
    /// A request coalescer capacity limit was exceeded.
    case coalescerLimitExceeded
    /// A required cached response was unavailable.
    case cacheMiss
    /// The circuit breaker rejected the request.
    case circuitBreakerOpen
    /// A queue capacity limit was exceeded.
    case queueCapacityExceeded
    /// Offline queue storage was required but unavailable.
    case offlineQueueUnavailable
    /// Authentication refresh failed before replay.
    case authenticationRefreshFailed
}

/// Typed errors emitted by the core networking contracts.
public enum NetworkError: Error {
    /// The transport returned a non-HTTP or malformed response.
    case invalidResponse
    /// The server returned a non-success HTTP status with response metadata.
    case httpStatus(code: Int, headers: [String: String], body: Data)
    /// Typed response decoding failed.
    case decoding(underlying: any Error)
    /// The underlying transport failed.
    case transport(underlying: any Error)
    /// The operation was cancelled.
    case cancelled
    /// The request deadline budget was exhausted.
    case timeoutBudgetExceeded
    /// The circuit breaker rejected the request.
    case circuitBreakerOpen
    /// A coalescer capacity limit rejected the request.
    case coalescerLimitExceeded
    /// A client rate limit rejected the request.
    case clientRateLimited(retryAfterSeconds: TimeInterval?)
    /// A queue capacity limit rejected the request.
    case queueCapacityExceeded(limit: Int?)
    /// Offline queue storage was required but unavailable.
    case offlineQueueUnavailable
    /// Authentication refresh failed before request replay.
    case authenticationRefreshFailed(underlying: any Error)
}

public extension NetworkError {
    /// Creates an HTTP status error without response headers.
    static func httpStatus(code: Int, body: Data) -> NetworkError {
        .httpStatus(code: code, headers: [:], body: body)
    }
}

public extension NetworkError {
    /// HTTP status code when this is an HTTP status error.
    var statusCode: Int? {
        if case .httpStatus(let code, _, _) = self {
            return code
        }
        return nil
    }

    /// Wrapped decoding, transport, or authentication refresh error.
    var underlyingError: (any Error)? {
        switch self {
        case .decoding(let error), .transport(let error), .authenticationRefreshFailed(let error):
            return error
        default:
            return nil
        }
    }

    /// Stable category suitable for retry, circuit breaker, and telemetry decisions.
    var failureReason: NetworkFailureReason {
        switch self {
        case .invalidResponse:
            return .invalidResponse
        case .httpStatus(let code, _, _):
            if code == 429 { return .rateLimited }
            return .httpStatus(code: code)
        case .decoding:
            return .decoding
        case .transport(let underlying as URLError):
            if underlying.code == .timedOut {
                return .timedOut
            }
            return .transport
        case .transport:
            return .transport
        case .cancelled:
            return .cancelled
        case .timeoutBudgetExceeded:
            return .timeoutBudgetExhausted
        case .circuitBreakerOpen:
            return .circuitBreakerOpen
        case .coalescerLimitExceeded:
            return .coalescerLimitExceeded
        case .clientRateLimited:
            return .rateLimited
        case .queueCapacityExceeded:
            return .queueCapacityExceeded
        case .offlineQueueUnavailable:
            return .offlineQueueUnavailable
        case .authenticationRefreshFailed:
            return .authenticationRefreshFailed
        }
    }
}

extension NetworkError: Equatable {
    /// Structural equality.
    ///
    /// Cases wrapping an `any Error` (`.decoding`, `.transport`, `.authenticationRefreshFailed`)
    /// compare their wrapped errors by dynamic type and description, since `any Error` has no
    /// general equality contract. This is a best-effort comparison intended for tests and
    /// deduplication, not a guarantee that two "equal" wrapped errors are the same value in
    /// every sense.
    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse):
            return true
        case let (.httpStatus(lCode, lHeaders, lBody), .httpStatus(rCode, rHeaders, rBody)):
            return lCode == rCode && lHeaders == rHeaders && lBody == rBody
        case let (.decoding(lUnderlying), .decoding(rUnderlying)):
            return describesTheSameError(lUnderlying, rUnderlying)
        case let (.transport(lUnderlying), .transport(rUnderlying)):
            return describesTheSameError(lUnderlying, rUnderlying)
        case (.cancelled, .cancelled):
            return true
        case (.timeoutBudgetExceeded, .timeoutBudgetExceeded):
            return true
        case (.circuitBreakerOpen, .circuitBreakerOpen):
            return true
        case (.coalescerLimitExceeded, .coalescerLimitExceeded):
            return true
        case let (.clientRateLimited(lRetryAfter), .clientRateLimited(rRetryAfter)):
            return lRetryAfter == rRetryAfter
        case let (.queueCapacityExceeded(lLimit), .queueCapacityExceeded(rLimit)):
            return lLimit == rLimit
        case (.offlineQueueUnavailable, .offlineQueueUnavailable):
            return true
        case let (.authenticationRefreshFailed(lUnderlying), .authenticationRefreshFailed(rUnderlying)):
            return describesTheSameError(lUnderlying, rUnderlying)
        default:
            return false
        }
    }

    private static func describesTheSameError(_ lhs: any Error, _ rhs: any Error) -> Bool {
        type(of: lhs) == type(of: rhs) && String(describing: lhs) == String(describing: rhs)
    }
}

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid or non-HTTP response."
        case .httpStatus(let code, _, _):
            return "The server returned HTTP status \(code)."
        case .decoding(let underlying):
            return "Failed to decode the response: \(underlying.localizedDescription)"
        case .transport(let underlying):
            return "The network request failed: \(underlying.localizedDescription)"
        case .cancelled:
            return "The request was cancelled."
        case .timeoutBudgetExceeded:
            return "The request exceeded its deadline budget."
        case .circuitBreakerOpen:
            return "The circuit breaker is currently open for this request."
        case .coalescerLimitExceeded:
            return "A request coalescer capacity limit was exceeded."
        case .clientRateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "The request was rate limited; retry after \(retryAfterSeconds) seconds."
            }
            return "The request was rate limited."
        case .queueCapacityExceeded(let limit):
            if let limit {
                return "The queue capacity limit of \(limit) was exceeded."
            }
            return "The queue capacity limit was exceeded."
        case .offlineQueueUnavailable:
            return "Offline queue storage was required but unavailable."
        case .authenticationRefreshFailed(let underlying):
            return "Authentication refresh failed: \(underlying.localizedDescription)"
        }
    }
}
