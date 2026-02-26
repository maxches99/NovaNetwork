import Foundation

public enum NetworkError: Error {
    case invalidResponse
    case httpStatus(code: Int, body: Data)
    case decoding(underlying: any Error)
    case transport(underlying: any Error)
    case cancelled
}

public extension NetworkError {
    var statusCode: Int? {
        if case .httpStatus(let code, _) = self {
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
}
