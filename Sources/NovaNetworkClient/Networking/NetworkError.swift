import Foundation

public enum NetworkFailureReason: Sendable, Equatable {
    case invalidResponse
    case httpStatus(code: Int)
    case decoding
    case transport
    case cancelled
    case timedOut
    case timeoutBudgetExhausted
    case rateLimited
    case coalescerLimitExceeded
    case cacheMiss
    case circuitBreakerOpen
}

public enum NetworkError: Error {
    case invalidResponse
    case httpStatus(code: Int, headers: [String: String], body: Data)
    case decoding(underlying: any Error)
    case transport(underlying: any Error)
    case cancelled
    case timeoutBudgetExceeded
    case circuitBreakerOpen
    case coalescerLimitExceeded
    case clientRateLimited(retryAfterSeconds: TimeInterval?)
}

public extension NetworkError {
    static func httpStatus(code: Int, body: Data) -> NetworkError {
        .httpStatus(code: code, headers: [:], body: body)
    }
}

public extension NetworkError {
    var statusCode: Int? {
        if case .httpStatus(let code, _, _) = self {
            return code
        }
        return nil
    }

    var underlyingError: (any Error)? {
        switch self {
        case .decoding(let error), .transport(let error):
            return error
        default:
            return nil
        }
    }

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
        }
    }
}
