import Foundation

/// How much of a URL a match rule compares.
public enum CassetteURLMatching: String, Sendable, Equatable, CaseIterable, Codable {
    /// Scheme, host, port, path, and query items. Query order does not matter.
    case full
    /// Path and query items only, ignoring scheme, host, and port.
    case pathAndQuery
    /// Path only.
    case path
    /// Nothing; the URL does not take part in matching.
    case none
}

/// Decides whether a live request is the one a recording captured.
///
/// The default — method plus full URL — is the identity a reader assumes from looking at a cassette.
/// Headers and bodies are available but off by default on purpose: matching on a header that
/// carries a nonce, a trace id, or a timestamp makes every replay fail for a reason that is
/// invisible in the file.
public struct CassetteMatchRule: Sendable, Equatable {
    /// Whether the HTTP method must be equal.
    public var method: Bool
    /// How much of the URL must be equal.
    public var url: CassetteURLMatching
    /// Whether request bodies must be byte-identical.
    public var body: Bool
    /// Header names that must match, compared case-insensitively.
    public var headerNames: Set<String>

    /// Creates a match rule.
    public init(
        method: Bool = true,
        url: CassetteURLMatching = .full,
        body: Bool = false,
        headerNames: Set<String> = []
    ) {
        self.method = method
        self.url = url
        self.body = body
        self.headerNames = headerNames
    }

    /// Method and full URL. The default.
    public static let `default` = CassetteMatchRule()

    /// Method and path, ignoring query items — useful when a query carries a cache buster.
    public static let methodAndPath = CassetteMatchRule(url: .path)

    /// Method, full URL, and body — the rule for APIs that vary a response by request payload.
    public static let includingBody = CassetteMatchRule(body: true)

    /// Returns a copy that also requires the named headers to match.
    public func matchingHeaders(_ names: String...) -> CassetteMatchRule {
        var copy = self
        copy.headerNames.formUnion(names)
        return copy
    }

    /// Whether `candidate` (a recording) is a match for `request` (a live request).
    public func matches(_ request: RecordedRequest, candidate: RecordedRequest) -> Bool {
        if method, request.method.uppercased() != candidate.method.uppercased() {
            return false
        }
        guard Self.urls(request.url, candidate.url, match: url) else {
            return false
        }
        if body, request.body?.data != candidate.body?.data {
            return false
        }
        for name in headerNames {
            guard Self.headerValue(named: name, in: request.headers) == Self.headerValue(named: name, in: candidate.headers) else {
                return false
            }
        }
        return true
    }

    /// Compares two URL strings at the requested granularity.
    ///
    /// Query items are compared as a multiset, so a client that reorders parameters still matches.
    static func urls(_ lhs: String, _ rhs: String, match granularity: CassetteURLMatching) -> Bool {
        switch granularity {
        case .none:
            return true
        case .full where lhs == rhs:
            return true
        default:
            break
        }

        guard let left = URLComponents(string: lhs), let right = URLComponents(string: rhs) else {
            return lhs == rhs
        }

        if granularity == .full {
            guard left.scheme == right.scheme, left.host == right.host, left.port == right.port else {
                return false
            }
        }
        guard left.path == right.path else { return false }
        guard granularity != .path else { return true }

        return normalizedQuery(left) == normalizedQuery(right)
    }

    private static func normalizedQuery(_ components: URLComponents) -> [String] {
        (components.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
    }

    /// Case-insensitive header lookup, matching how HTTP treats field names.
    static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
