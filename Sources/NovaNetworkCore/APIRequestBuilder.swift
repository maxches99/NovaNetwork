import Foundation

/// A value-semantic fluent builder for ``APIRequest``.
public struct APIRequestBuilder: Sendable {
    private let method: URLMethod
    private let url: URL
    private var queryItems: [URLQueryItem] = []
    private var headers: [String: String] = [:]
    private var body: Data?
    private var timeout: TimeInterval = 60

    /// Creates a builder with a method and base URL.
    public init(method: URLMethod, url: URL) {
        self.method = method
        self.url = url
    }

    /// Returns a copy with one appended query item.
    public func queryItem(name: String, value: String?) -> APIRequestBuilder {
        var copy = self
        copy.queryItems.append(URLQueryItem(name: name, value: value))
        return copy
    }

    /// Returns a copy replacing all query items.
    public func queryItems(_ items: [URLQueryItem]) -> APIRequestBuilder {
        var copy = self
        copy.queryItems = items
        return copy
    }

    /// Returns a copy containing the supplied header value.
    public func header(_ name: String, _ value: String) -> APIRequestBuilder {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    /// Returns a copy merging multiple header values.
    public func headers(_ headers: [String: String]) -> APIRequestBuilder {
        var copy = self
        for (name, value) in headers {
            copy.headers[name] = value
        }
        return copy
    }

    /// Returns a copy with the supplied raw body.
    public func body(_ data: Data?) -> APIRequestBuilder {
        var copy = self
        copy.body = data
        return copy
    }

    /// Returns a copy with a JSON-encoded body and default JSON content type.
    public func jsonBody<Body: Encodable & Sendable>(
        _ payload: Body,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> APIRequestBuilder {
        var copy = self
        copy.body = try encoder.encode(payload)
        if copy.headers["Content-Type"] == nil {
            copy.headers["Content-Type"] = "application/json"
        }
        return copy
    }

    /// Returns a copy with a request timeout in seconds.
    public func timeout(_ interval: TimeInterval) -> APIRequestBuilder {
        var copy = self
        copy.timeout = interval
        return copy
    }

    /// Builds the immutable request value.
    public func build() -> APIRequest {
        APIRequest(
            method: method,
            url: url,
            queryItems: queryItems,
            headers: headers,
            body: body,
            timeout: timeout
        )
    }
}
