import Foundation

public struct APIRequest: Sendable {
    public let method: URLMethod
    public let url: URL
    public let queryItems: [URLQueryItem]
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

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

    public static func builder(method: URLMethod, url: URL) -> APIRequestBuilder {
        APIRequestBuilder(method: method, url: url)
    }

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
