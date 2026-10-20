import Foundation

/// How a ``QueryClient`` behaves by default.
public struct QueryConfiguration: Sendable, Equatable {
    /// How long a value counts as fresh before a read triggers a background refresh.
    ///
    /// Thirty seconds: long enough that moving between two screens does not refetch, short enough
    /// that a value on screen is not obviously old.
    public var staleTime: TimeInterval
    /// How many entries the cache holds before evicting.
    ///
    /// Eviction takes the least recently used entry that nobody is subscribed to, so a screen's data
    /// cannot be evicted out from under it.
    public var capacity: Int
    /// How many ``QueryClient/prefetchWhileVisible(_:staleTime:fetch:)`` fetches run at once.
    ///
    /// Four: enough to keep ahead of a scrolling list, few enough that what is on screen now is not
    /// queued behind rows that may never be looked at. Values below 1 behave as 1.
    public var maximumConcurrentPrefetches: Int = 4

    /// Creates a configuration.
    public init(staleTime: TimeInterval = 30, capacity: Int = 100) {
        self.staleTime = staleTime
        self.capacity = max(0, capacity)
    }
}

/// What happened to one visibility-driven prefetch.
public enum QueryPrefetchEvent: Sendable, Equatable {
    /// The key is waiting for a prefetch slot.
    case queued(QueryKey)
    /// The prefetch started.
    case started(QueryKey)
    /// The prefetch stored a value.
    case completed(QueryKey)
    /// The prefetch's fetch threw.
    case failed(QueryKey)
    /// The key was fresh, so nothing was fetched.
    case skippedFresh(QueryKey)
    /// The prefetch was called off; `wasRunning` says whether its fetch had started.
    case cancelled(QueryKey, wasRunning: Bool)
    /// A read wanted the key, so it is no longer only a prefetch and will not be cancelled.
    case promoted(QueryKey)
}

/// A failure from the query layer itself, as opposed to from the work a query performs.
public enum QueryError: Error, Equatable, Sendable, LocalizedError {
    /// A key was read as one type after being written as another.
    case typeMismatch(key: String, cached: String, requested: String)

    /// A description naming the key and both types.
    public var errorDescription: String? {
        switch self {
        case let .typeMismatch(key, cached, requested):
            """
            The query '\(key)' holds a \(cached) but was read as a \(requested). One key means one \
            value type; use a different key for a different shape.
            """
        }
    }
}
