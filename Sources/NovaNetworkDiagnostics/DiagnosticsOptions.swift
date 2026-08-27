import Foundation

/// How much of a body a recorder keeps.
public enum BodyCapturePolicy: Sendable, Equatable {
    /// Keep nothing, not even the size.
    case none
    /// Keep the byte count only. Enough for a timeline, useless for a payload diff.
    case sizeOnly
    /// Keep up to `maxBytes`, flagging the record when it truncates.
    case bounded(maxBytes: Int)

    /// The default: enough of a payload to be useful in a HAR, capped so a long session stays small.
    public static let `default` = BodyCapturePolicy.bounded(maxBytes: 64 * 1024)

    /// Summarizes a body under this policy.
    public func summarize(_ data: Data?) -> BodySummary? {
        guard let data, self != .none else { return nil }

        switch self {
        case .none:
            return nil
        case .sizeOnly:
            return BodySummary(byteCount: data.count)
        case let .bounded(maxBytes):
            guard data.count > maxBytes else {
                return BodySummary(byteCount: data.count, captured: data)
            }
            return BodySummary(byteCount: data.count, captured: data.prefix(maxBytes), isTruncated: true)
        }
    }
}

/// Removes credentials before a record is retained.
///
/// Redaction runs as the record is built, not as it is exported: a diagnostics buffer that holds a
/// live token is one screenshot or one attached file away from leaking it.
public struct DiagnosticsRedaction: Sendable, Equatable {
    /// Header names whose values are replaced, compared case-insensitively.
    public var headerNames: Set<String>
    /// Query item names whose values are replaced.
    public var queryItemNames: Set<String>
    /// The text written in place of a redacted value.
    public var placeholder: String

    /// Creates a redaction policy.
    public init(
        headerNames: Set<String>,
        queryItemNames: Set<String> = [],
        placeholder: String = "<redacted>"
    ) {
        self.headerNames = headerNames
        self.queryItemNames = queryItemNames
        self.placeholder = placeholder
    }

    /// The headers that usually carry credentials.
    ///
    /// Deliberately the same set the cassette module redacts: two products that both write traffic
    /// to somewhere a human will look should not disagree about what a secret is.
    public static let `default` = DiagnosticsRedaction(
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
    public static let none = DiagnosticsRedaction(headerNames: [])

    /// Returns a copy that also redacts the named headers.
    public func redacting(headers names: String...) -> DiagnosticsRedaction {
        var copy = self
        copy.headerNames.formUnion(names)
        return copy
    }

    /// Returns a copy that also redacts the named query items.
    public func redacting(queryItems names: String...) -> DiagnosticsRedaction {
        var copy = self
        copy.queryItemNames.formUnion(names)
        return copy
    }

    /// Whether a header name is redacted by this policy.
    public func redactsHeader(named name: String) -> Bool {
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
}

/// How a ``DiagnosticsRecorder`` behaves.
public struct DiagnosticsOptions: Sendable, Equatable {
    /// How many records to keep. Oldest are dropped first.
    public var capacity: Int
    /// How much of each body to keep.
    public var bodyCapture: BodyCapturePolicy
    /// What is stripped before a record is retained.
    public var redaction: DiagnosticsRedaction
    /// Whether to emit `os_signpost` intervals for Instruments.
    public var emitsSignposts: Bool

    /// Creates recorder options.
    ///
    /// - Parameters:
    ///   - capacity: Maximum records retained. A bounded buffer is the point: an unbounded one is a
    ///     leak in any app that runs for a while.
    ///   - bodyCapture: How much of each body to keep.
    ///   - redaction: What is stripped before retention.
    ///   - emitsSignposts: Whether to mark request intervals for Instruments.
    public init(
        capacity: Int = 200,
        bodyCapture: BodyCapturePolicy = .default,
        redaction: DiagnosticsRedaction = .default,
        emitsSignposts: Bool = false
    ) {
        self.capacity = max(0, capacity)
        self.bodyCapture = bodyCapture
        self.redaction = redaction
        self.emitsSignposts = emitsSignposts
    }
}
