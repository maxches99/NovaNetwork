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
