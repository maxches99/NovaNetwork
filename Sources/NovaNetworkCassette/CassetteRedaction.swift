import Foundation

/// Removes credentials before an exchange is recorded.
///
/// Redaction runs as the interaction is captured, not as the file is written. A redactor that ran at
/// save time would leave the secret sitting in a value the caller could serialize somewhere else;
/// running it at capture means the token exists only in the live request.
public struct CassetteRedaction: Sendable {
    /// Header names whose values are replaced, compared case-insensitively.
    public var headerNames: Set<String>
    /// Query item names whose values are replaced.
    public var queryItemNames: Set<String>
    /// The text written in place of a redacted value.
    public var placeholder: String
    /// An optional transform applied to every recorded body.
    public var bodyRedactor: (@Sendable (Data) -> Data)?

    /// Creates a redaction policy.
    public init(
        headerNames: Set<String>,
        queryItemNames: Set<String> = [],
        placeholder: String = "<redacted>",
        bodyRedactor: (@Sendable (Data) -> Data)? = nil
    ) {
        self.headerNames = headerNames
        self.queryItemNames = queryItemNames
        self.placeholder = placeholder
        self.bodyRedactor = bodyRedactor
    }

    /// Redacts the headers that commonly carry credentials.
    ///
    /// `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `X-API-Key`, and
    /// `X-Auth-Token`. Add more with ``redacting(headers:)`` — the default is a floor, not a
    /// guarantee that your API keeps its secrets where everyone else does.
    public static let `default` = CassetteRedaction(
        headerNames: [
            "Authorization",
            "Proxy-Authorization",
            "Cookie",
            "Set-Cookie",
            "X-API-Key",
            "X-Auth-Token",
        ]
    )

    /// Records everything verbatim. Only for traffic with no credentials at all.
    public static let none = CassetteRedaction(headerNames: [])

    /// Returns a copy that also redacts the named headers.
    public func redacting(headers names: String...) -> CassetteRedaction {
        var copy = self
        copy.headerNames.formUnion(names)
        return copy
    }

    /// Returns a copy that also redacts the named query items.
    public func redacting(queryItems names: String...) -> CassetteRedaction {
        var copy = self
        copy.queryItemNames.formUnion(names)
        return copy
    }

    /// Returns a copy that rewrites recorded bodies, for payloads that carry secrets of their own.
    public func redactingBodies(_ transform: @escaping @Sendable (Data) -> Data) -> CassetteRedaction {
        var copy = self
        copy.bodyRedactor = transform
        return copy
    }

    // MARK: - Application

    /// Whether a header name is redacted by this policy.
    func redactsHeader(named name: String) -> Bool {
        headerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func redacted(headers: [String: String]) -> [String: String] {
        guard !headerNames.isEmpty else { return headers }
        return headers.reduce(into: [:]) { result, entry in
            result[entry.key] = redactsHeader(named: entry.key) ? placeholder : entry.value
        }
    }

    func redacted(url: String) -> String {
        guard !queryItemNames.isEmpty,
              var components = URLComponents(string: url),
              let items = components.queryItems
        else {
            return url
        }

        components.queryItems = items.map { item in
            queryItemNames.contains(item.name) ? URLQueryItem(name: item.name, value: placeholder) : item
        }
        return components.url?.absoluteString ?? url
    }

    func redacted(body: Data?) -> Data? {
        guard let body else { return nil }
        return bodyRedactor?(body) ?? body
    }
}
