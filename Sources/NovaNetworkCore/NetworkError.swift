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
