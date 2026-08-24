import Foundation

/// A failure raised while turning an endpoint declaration into an ``APIRequest``.
public enum EndpointDefinitionError: Error, Equatable, Sendable {
    /// A path parameter serialized to no value at all — typically an optional that was `nil`.
    ///
    /// Path parameters cannot be omitted the way query parameters can: leaving one out would
    /// change which resource the URL addresses.
    case missingPathParameter(name: String)
    /// The path template contains a placeholder that no parameter filled in.
    case unresolvedPathPlaceholder(name: String, template: String)
    /// The base URL and expanded path did not combine into a valid URL.
    case invalidURL(baseURL: String, path: String)
}

extension EndpointDefinitionError: LocalizedError {
    /// A human-readable description of the construction failure.
    public var errorDescription: String? {
        switch self {
        case let .missingPathParameter(name):
            "Path parameter '\(name)' has no value. Path parameters cannot be omitted."
        case let .unresolvedPathPlaceholder(name, template):
            "Path template '\(template)' contains placeholder '{\(name)}', which no parameter filled in."
        case let .invalidURL(baseURL, path):
            "Base URL '\(baseURL)' and path '\(path)' do not combine into a valid URL."
        }
    }
}

/// Assembles an ``APIRequest`` from an endpoint's method, base URL, path template, and parameters.
///
/// This is the single place where declarative endpoints turn into requests. Hand-written
/// endpoints, `@Endpoint`-annotated types, and types generated from an OpenAPI document all funnel
/// through it, so percent-encoding, optional omission, array styles, and header precedence behave
/// identically no matter how the endpoint was written.
///
/// ```swift
/// var builder = EndpointRequestBuilder(method: .get, baseURL: baseURL, path: "/users/{id}/posts")
/// try builder.setPath("id", userID)
/// builder.addQuery("limit", limit)
/// return try builder.build()
/// ```
public struct EndpointRequestBuilder: Sendable {
    /// Characters left unescaped when a value is substituted into the path.
    ///
    /// Deliberately narrow: the RFC 3986 unreserved set. A path parameter is one opaque segment,
    /// so a value containing `/`, `?`, or `#` must not be able to restructure the URL.
    private static let unreservedPathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// The HTTP method of the request under construction.
    public let method: URLMethod
    /// The base URL the path is resolved against.
    public let baseURL: URL
    /// The path template, which may contain `{name}` placeholders.
    public let pathTemplate: String

    private var pathValues: [String: String] = [:]
    private var queryItems: [URLQueryItem] = []
    private var headers: [String: String] = [:]
    private var body: Data?

    /// Creates a builder for one request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - baseURL: The URL the path is appended to. A trailing slash is harmless.
    ///   - path: A path template such as `/users/{id}`. A leading slash is optional.
    public init(method: URLMethod, baseURL: URL, path: String) {
        self.method = method
        self.baseURL = baseURL
        pathTemplate = path
    }

    /// Binds a value to a `{name}` placeholder in the path template.
    ///
    /// - Throws: ``EndpointDefinitionError/missingPathParameter(name:)`` when the value serializes
    ///   to nothing, which is what a `nil` optional does.
    public mutating func setPath(_ name: String, _ value: some EndpointParameterConvertible) throws {
        let strings = value.endpointParameterStrings
        guard let first = strings.first else {
            throw EndpointDefinitionError.missingPathParameter(name: name)
        }
        // A multi-valued path parameter is OpenAPI's `simple` style: comma-joined in one segment.
        pathValues[name] = strings.count == 1 ? first : strings.joined(separator: ",")
    }

    /// Appends query items for a value, omitting it entirely when it serializes to nothing.
    public mutating func addQuery(
        _ name: String,
        _ value: some EndpointParameterConvertible,
        style: EndpointQueryStyle = .repeated
    ) {
        queryItems.append(contentsOf: style.queryItems(name: name, values: value.endpointParameterStrings))
    }

    /// Sets a header, omitting it entirely when the value serializes to nothing.
    ///
    /// Multi-valued headers are joined with `", "`, per RFC 9110's rule for combining field lines.
    public mutating func setHeader(_ name: String, _ value: some EndpointParameterConvertible) {
        let strings = value.endpointParameterStrings
        guard !strings.isEmpty else { return }
        headers[name] = strings.joined(separator: ", ")
    }

    /// JSON-encodes a body value and defaults the content type to `application/json`.
    ///
    /// - Throws: Whatever `encoder` throws, unchanged.
    public mutating func setJSONBody(_ value: some Encodable & Sendable, encoder: JSONEncoder = JSONEncoder()) throws {
        body = try encoder.encode(value)
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
    }

    /// Sets a raw body and, optionally, its content type.
    public mutating func setBody(_ data: Data, contentType: String? = nil) {
        body = data
        if let contentType, headers["Content-Type"] == nil {
            headers["Content-Type"] = contentType
        }
    }

    /// Builds the request.
    ///
    /// Headers set on the builder take precedence over `additionalHeaders`, so a parameter-supplied
    /// value always wins over an endpoint-wide default.
    ///
    /// - Parameters:
    ///   - timeout: Request timeout in seconds.
    ///   - additionalHeaders: Endpoint-wide default headers.
    /// - Throws: ``EndpointDefinitionError`` when a placeholder is unfilled or the URL is invalid.
    public func build(timeout: TimeInterval = 60, additionalHeaders: [String: String] = [:]) throws -> APIRequest {
        let path = try expandedPath()
        guard let url = URL(string: Self.join(baseURL: baseURL, path: path)) else {
            throw EndpointDefinitionError.invalidURL(baseURL: baseURL.absoluteString, path: path)
        }

        var mergedHeaders = additionalHeaders
        for (name, value) in headers {
            mergedHeaders[name] = value
        }

        return APIRequest(
            method: method,
            url: url,
            queryItems: queryItems,
            headers: mergedHeaders,
            body: body,
            timeout: timeout
        )
    }

    /// Substitutes every `{name}` placeholder with its percent-encoded value.
    ///
    /// An unterminated `{` is treated as literal text: templates come from a macro or generator
    /// that has already validated them, and a runtime guess would be worse than passing it through.
    private func expandedPath() throws -> String {
        guard pathTemplate.contains("{") else { return pathTemplate }

        var result = ""
        var remainder = Substring(pathTemplate)

        while let open = remainder.firstIndex(of: "{") {
            guard let close = remainder[remainder.index(after: open)...].firstIndex(of: "}") else {
                break
            }
            let name = String(remainder[remainder.index(after: open)..<close])
            guard let value = pathValues[name] else {
                throw EndpointDefinitionError.unresolvedPathPlaceholder(name: name, template: pathTemplate)
            }
            result += remainder[..<open]
            result += Self.encodePathValue(value)
            remainder = remainder[remainder.index(after: close)...]
        }

        return result + remainder
    }

    /// Percent-encodes a path value so it can only ever be one segment.
    private static func encodePathValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedPathCharacters) ?? value
    }

    /// Joins a base URL and an expanded path with exactly one separator.
    private static func join(baseURL: URL, path: String) -> String {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }

        guard !path.isEmpty else { return base.isEmpty ? baseURL.absoluteString : base }

        return path.hasPrefix("/") ? base + path : base + "/" + path
    }
}
