import Foundation

public struct APIRequestBuilder: Sendable {
    private let method: URLMethod
    private let url: URL
    private var queryItems: [URLQueryItem] = []
    private var headers: [String: String] = [:]
    private var body: Data?
    private var timeout: TimeInterval = 60

    public init(method: URLMethod, url: URL) {
        self.method = method
        self.url = url
    }

    public func queryItem(name: String, value: String?) -> APIRequestBuilder {
        var copy = self
        copy.queryItems.append(URLQueryItem(name: name, value: value))
        return copy
    }

    public func queryItems(_ items: [URLQueryItem]) -> APIRequestBuilder {
        var copy = self
        copy.queryItems = items
        return copy
    }

    public func header(_ name: String, _ value: String) -> APIRequestBuilder {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    public func headers(_ headers: [String: String]) -> APIRequestBuilder {
        var copy = self
        for (name, value) in headers {
            copy.headers[name] = value
        }
        return copy
    }

    public func body(_ data: Data?) -> APIRequestBuilder {
        var copy = self
        copy.body = data
        return copy
    }

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

    public func timeout(_ interval: TimeInterval) -> APIRequestBuilder {
        var copy = self
        copy.timeout = interval
        return copy
    }

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
