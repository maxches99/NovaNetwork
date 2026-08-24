import Foundation
import NovaNetworkClient

/// A composable predicate over ``APIRequest``, for routing mock responses by request shape.
public struct RequestMatcher: Sendable {
    private let predicate: @Sendable (APIRequest) -> Bool

    /// Creates a matcher from an arbitrary predicate.
    public init(_ predicate: @escaping @Sendable (APIRequest) -> Bool) {
        self.predicate = predicate
    }

    /// Evaluates the matcher against `request`.
    public func matches(_ request: APIRequest) -> Bool {
        predicate(request)
    }

    /// Matches every request.
    public static let any = RequestMatcher { _ in true }

    /// Matches requests with the given HTTP method.
    public static func method(_ method: URLMethod) -> RequestMatcher {
        RequestMatcher { $0.method == method }
    }

    /// Matches requests whose URL path equals `path` exactly.
    public static func path(_ path: String) -> RequestMatcher {
        RequestMatcher { $0.url.path == path }
    }

    /// Matches requests whose URL path starts with `prefix`.
    public static func pathPrefix(_ prefix: String) -> RequestMatcher {
        RequestMatcher { $0.url.path.hasPrefix(prefix) }
    }

    /// Matches requests whose URL host equals `host` exactly.
    public static func host(_ host: String) -> RequestMatcher {
        RequestMatcher { $0.url.host == host }
    }

    /// Matches requests carrying a header named `name` with value `value` (case-insensitive
    /// name, exact value match).
    public static func header(_ name: String, _ value: String) -> RequestMatcher {
        RequestMatcher { request in
            request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value == value
        }
    }

    /// Matches requests whose body, decoded as UTF-8 text, contains `substring`.
    public static func bodyContains(_ substring: String) -> RequestMatcher {
        RequestMatcher { request in
            guard let body = request.body, let text = String(data: body, encoding: .utf8) else { return false }
            return text.contains(substring)
        }
    }

    /// Matches requests whose URL, including query items, equals `url` exactly.
    public static func url(_ url: URL) -> RequestMatcher {
        RequestMatcher { $0.urlRequest().url == url }
    }

    /// Combines two matchers, requiring both to match.
    public static func && (lhs: RequestMatcher, rhs: RequestMatcher) -> RequestMatcher {
        RequestMatcher { lhs.matches($0) && rhs.matches($0) }
    }

    /// Combines two matchers, requiring either to match.
    public static func || (lhs: RequestMatcher, rhs: RequestMatcher) -> RequestMatcher {
        RequestMatcher { lhs.matches($0) || rhs.matches($0) }
    }
}
