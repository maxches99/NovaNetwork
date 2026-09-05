import Foundation

/// Supported HTTP request methods.
public enum URLMethod: String, Codable, Hashable, Sendable {
    /// GET request.
    case get = "GET"
    /// POST request.
    case post = "POST"
    /// PUT request.
    case put = "PUT"
    /// PATCH request.
    case patch = "PATCH"
    /// DELETE request.
    case delete = "DELETE"
    /// HEAD request.
    case head = "HEAD"
    /// OPTIONS request.
    case options = "OPTIONS"
}

public extension URLMethod {
    /// Whether the method is *safe* — read-only, in RFC 9110 §9.2.1's sense.
    ///
    /// Safe does not mean nothing happens on the server; it means the client is not *asking* for a
    /// change, so repeating the request is not a second edit.
    var isSafe: Bool {
        switch self {
        case .get, .head, .options:
            return true
        case .post, .put, .patch, .delete:
            return false
        }
    }

    /// Whether a response to this method may be reused from a cache without an explicit opt-in.
    ///
    /// RFC 9111 §3 makes this `GET` and `HEAD`. `POST` responses are cacheable only when the server
    /// says so explicitly, and `PUT`, `PATCH`, and `DELETE` never are — reusing one would hand a
    /// caller a stale answer to a request that was meant to change something.
    var isCacheableByDefault: Bool {
        switch self {
        case .get, .head:
            return true
        case .options, .post, .put, .patch, .delete:
            return false
        }
    }
}

/// The HTTP method of a request.
///
/// A spelling of ``URLMethod`` under the name most people search for. The two are the same type, so
/// they are interchangeable everywhere.
public typealias HTTPMethod = URLMethod
