import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An immutable, transport-neutral HTTP request description.
public struct APIRequest: Sendable {
    /// HTTP method.
    public let method: URLMethod
    /// Base request URL without ``queryItems`` applied.
    public let url: URL
    /// Query items appended when creating a `URLRequest`.
    public let queryItems: [URLQueryItem]
    /// HTTP request headers.
    public let headers: [String: String]
    /// Optional request body.
    public let body: Data?
    /// Request timeout in seconds.
    public let timeout: TimeInterval

    /// Creates an HTTP request description.
    public init(
        method: URLMethod,
        url: URL,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) {
        self.method = method
        self.url = url
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Creates a request by JSON-encoding a body value.
    ///
    /// The initializer adds `Content-Type: application/json` unless supplied by the caller.
    public init<Body: Encodable & Sendable>(
        method: URLMethod,
        url: URL,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        jsonBody: Body,
        encoder: JSONEncoder = JSONEncoder(),
        timeout: TimeInterval = 60
    ) throws {
        let body = try encoder.encode(jsonBody)
        var resolvedHeaders = headers
        if resolvedHeaders["Content-Type"] == nil {
            resolvedHeaders["Content-Type"] = "application/json"
        }

        self.init(
            method: method,
            url: url,
            queryItems: queryItems,
            headers: resolvedHeaders,
            body: body,
            timeout: timeout
        )
    }

    /// Creates a value-semantic request builder.
    public static func builder(method: URLMethod, url: URL) -> APIRequestBuilder {
        APIRequestBuilder(method: method, url: url)
    }

    /// Returns a copy whose headers include or replace the supplied values.
    public func withMergedHeaders(_ additionalHeaders: [String: String]) -> APIRequest {
        guard !additionalHeaders.isEmpty else { return self }
        var merged = headers
        for (name, value) in additionalHeaders {
            merged[name] = value
        }
        return APIRequest(
            method: method,
            url: url,
            queryItems: queryItems,
            headers: merged,
            body: body,
            timeout: timeout
        )
    }

    /// Converts the description into a Foundation `URLRequest`.
    public func urlRequest() -> URLRequest {
        let resolvedURL: URL

        if queryItems.isEmpty {
            resolvedURL = url
        } else {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            resolvedURL = components?.url ?? url
        }

        var request = URLRequest(url: resolvedURL, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.httpBody = body

        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        return request
    }
}
