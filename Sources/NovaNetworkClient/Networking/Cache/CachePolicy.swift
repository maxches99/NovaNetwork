import NovaNetworkCore
import Foundation

/// How a load may use the response cache.
///
/// The three strategies decide *freshness*. What they never decide is whether an unsafe method may
/// take part at all: a `POST`, `PUT`, `PATCH`, or `DELETE` bypasses the cache under every strategy,
/// because reusing a stored answer to a request meant to change something is a silent failure —
/// the write never leaves, or the caller is handed a reply to an earlier one. Wrap a strategy in
/// ``includingUnsafeMethods(_:)`` to say otherwise, deliberately.
public enum CachePolicy: Sendable {
    /// Always go to the network, and never store the result.
    case networkOnly
    /// Serve a stored response younger than `maxAge`; otherwise revalidate.
    case cacheFirst(maxAge: TimeInterval)
    /// Serve a stored response younger than `maxAge`; up to `staleAge`, serve it and refresh behind it.
    case staleWhileRevalidate(maxAge: TimeInterval, staleAge: TimeInterval)
    /// Applies the wrapped strategy to unsafe methods too.
    ///
    /// Only reach for this when the server marks those responses cacheable and a repeat send is
    /// genuinely unwanted — a `POST` used as a read is the usual case. See
    /// <doc:ProductionChecklist>.
    indirect case includingUnsafeMethods(CachePolicy)

    /// Whether unsafe methods take part in the cache under this policy.
    public var includesUnsafeMethods: Bool {
        if case .includingUnsafeMethods = self { return true }
        return false
    }

    /// The freshness strategy alone, with any ``includingUnsafeMethods(_:)`` wrapper removed.
    public var strategy: CachePolicy {
        if case .includingUnsafeMethods(let wrapped) = self { return wrapped.strategy }
        return self
    }

    /// The freshness strategy in a form that cannot also be the wrapper.
    ///
    /// ``strategy`` says the same thing and reads better at a call site, but it is a `CachePolicy`,
    /// so switching over it still has to handle a case it can never be. This one is exhaustive.
    enum Freshness: Sendable {
        case networkOnly
        case cacheFirst(maxAge: TimeInterval)
        case staleWhileRevalidate(maxAge: TimeInterval, staleAge: TimeInterval)
    }

    var freshness: Freshness {
        switch self {
        case .networkOnly:
            return .networkOnly
        case .cacheFirst(let maxAge):
            return .cacheFirst(maxAge: maxAge)
        case .staleWhileRevalidate(let maxAge, let staleAge):
            return .staleWhileRevalidate(maxAge: maxAge, staleAge: staleAge)
        case .includingUnsafeMethods(let wrapped):
            return wrapped.freshness
        }
    }

    var normalized: CachePolicy {
        // Recursive rather than a single pass, so that nesting the wrapper — which reads as
        // emphasis and means nothing extra — collapses to one layer instead of reaching `load`.
        switch self {
        case .networkOnly:
            return .networkOnly
        case .cacheFirst(let maxAge):
            return .cacheFirst(maxAge: max(0, maxAge))
        case .staleWhileRevalidate(let maxAge, let staleAge):
            return .staleWhileRevalidate(
                maxAge: max(0, maxAge),
                staleAge: max(max(0, staleAge), max(0, maxAge))
            )
        case .includingUnsafeMethods(let wrapped):
            return .includingUnsafeMethods(wrapped.normalized.strategy)
        }
    }
}
