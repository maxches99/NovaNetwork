import Foundation

/// A complete HTTP response returned by a ``NetworkTransport``.
public struct NetworkResponse: Sendable {
    /// HTTP status code.
    public let statusCode: Int
    /// HTTP response headers.
    public let headers: [String: String]
    /// Complete response body.
    public let body: Data

    /// Creates a complete network response.
    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Returns a response header value using a case-insensitive name lookup.
    public func headerValue(for name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }
}
