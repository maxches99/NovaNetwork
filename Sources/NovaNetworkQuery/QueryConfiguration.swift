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

    /// Creates a configuration.
    public init(staleTime: TimeInterval = 30, capacity: Int = 100) {
        self.staleTime = staleTime
        self.capacity = max(0, capacity)
    }
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
