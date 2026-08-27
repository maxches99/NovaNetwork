import Foundation

/// Holds server state for the screens that render it.
///
/// `NetworkClient` answers "perform this request". A screen asks something else: "what is the
/// current state of this resource, and tell me when it changes". This answers that — one entry per
/// key, one in-flight fetch per key, and every subscriber reading the same state, so two screens
/// showing the same list cannot disagree.
///
/// ```swift
/// let users: [User] = try await queries.value(for: "users") {
///     try await client.load(request: request, authScope: nil)
/// }
/// ```
///
/// A query wraps any async work, so this depends on nothing but Foundation: an HTTP call, a database
/// read, or a computation are all the same to it.
public actor QueryClient {
    /// Everything known about one key.
    private struct Entry {
        var value: (any Sendable)?
        var valueTypeName: String?
        var updatedAt: Date?
        var error: (any Error)?
        var isStale = false
        var isLoading = false
        var lastAccess: Date
        var task: Task<any Sendable, any Error>?
        var refetch: (@Sendable () async throws -> any Sendable)?
        var subscribers: [UUID: @Sendable (Snapshot) -> Void] = [:]
    }

    /// The type-erased state handed to subscribers, which each one casts to its own value type.
    private struct Snapshot: Sendable {
        let value: (any Sendable)?
        let error: (any Error)?
        let isStale: Bool
        let isLoading: Bool
    }

    /// Defaults for staleness and capacity.
    public let configuration: QueryConfiguration

    private var entries: [QueryKey: Entry] = [:]
    private let now: @Sendable () -> Date

    /// Creates a query client.
    ///
    /// - Parameters:
    ///   - configuration: Default stale time and cache capacity.
    ///   - now: Clock used for staleness. Injectable so tests do not sleep.
    public init(
        configuration: QueryConfiguration = QueryConfiguration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Reading

    /// The value for a key, fetching it when there is nothing fresh enough.
    ///
    /// A fresh value is returned without touching the network. A stale one is returned immediately
    /// and refreshed in the background, because blanking a screen to a spinner over a value four
    /// minutes old is the behavior this layer exists to remove. Concurrent callers share the fetch.
    ///
    /// - Parameters:
    ///   - key: What is being asked for.
    ///   - staleTime: How long a value counts as fresh. Defaults to the client's configuration.
    ///   - fetch: How to produce the value.
    @discardableResult
    public func value<Value: Sendable>(
        for key: QueryKey,
        staleTime: TimeInterval? = nil,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let window = staleTime ?? configuration.staleTime
        touch(key)
        entries[key, default: newEntry()].refetch = { try await fetch() }

        if let cached = try cachedValue(for: key, as: Value.self) {
            if isFresh(key, within: window) {
                return cached
            }
            markStale(key)
            startFetch(key, fetch: fetch)
            return cached
        }

        return try await awaitFetch(key, fetch: fetch)
    }

    /// The cached value for a key, without fetching anything.
    ///
    /// - Throws: ``QueryError/typeMismatch(key:cached:requested:)`` when the key holds another type.
    public func cachedValue<Value: Sendable>(for key: QueryKey, as type: Value.Type = Value.self) throws -> Value? {
        guard let stored = entries[key]?.value else { return nil }
        guard let typed = stored as? Value else {
            throw QueryError.typeMismatch(
                key: key.description,
                cached: entries[key]?.valueTypeName ?? String(describing: Swift.type(of: stored)),
                requested: String(describing: Value.self)
            )
        }
        return typed
    }

    /// Fetches a value and caches it, ignoring whatever was there.
    @discardableResult
    public func refetch<Value: Sendable>(
        _ key: QueryKey,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        entries[key, default: newEntry()].refetch = { try await fetch() }
        return try await awaitFetch(key, fetch: fetch)
    }

    /// Fetches a value into the cache without waiting for it, for warming a screen ahead of time.
    public func prefetch<Value: Sendable>(
        _ key: QueryKey,
        staleTime: TimeInterval? = nil,
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        guard !isFresh(key, within: staleTime ?? configuration.staleTime) else { return }
        entries[key, default: newEntry()].refetch = { try await fetch() }
        startFetch(key, fetch: fetch)
    }

    // MARK: - Observing

    /// State changes for a key, starting with whatever the state is now.
    ///
    /// The stream finishes when the caller stops iterating; a subscriber going away never cancels
    /// work another subscriber is waiting on.
    public func states<Value: Sendable>(for key: QueryKey, as type: Value.Type = Value.self) -> AsyncStream<QueryState<Value>> {
        AsyncStream { continuation in
            let id = UUID()
            let publish: @Sendable (Snapshot) -> Void = { snapshot in
                continuation.yield(Self.state(from: snapshot, as: Value.self))
            }

            entries[key, default: newEntry()].subscribers[id] = publish
            publish(snapshot(for: key))

            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id, from: key) }
            }
        }
    }

    /// How many subscribers a key currently has, which decides whether invalidation refetches it.
    public func subscriberCount(for key: QueryKey) -> Int {
        entries[key]?.subscribers.count ?? 0
    }

    // MARK: - Writing

    /// Writes a value directly, for an optimistic update or a value that arrived another way.
    public func setValue<Value: Sendable>(_ value: Value, for key: QueryKey) {
        var entry = entries[key] ?? newEntry()
        entry.value = value
        entry.valueTypeName = String(describing: Value.self)
        entry.updatedAt = now()
        entry.error = nil
        entry.isStale = false
        entry.lastAccess = now()
        entries[key] = entry
        publish(key)
        evictIfNeeded()
    }

    /// Removes a key's value, leaving any subscribers to see an empty state.
    public func remove(_ key: QueryKey) {
        guard var entry = entries[key] else { return }
        entry.value = nil
        entry.valueTypeName = nil
        entry.updatedAt = nil
        entry.error = nil
        entry.isStale = false
        entries[key] = entry
        publish(key)
    }

    /// Marks a key stale, refetching immediately when someone is watching it.
    ///
    /// An entry nobody is subscribed to is marked and left alone: refetching data no screen is
    /// showing spends the user's battery to fill a cache that may never be read.
    public func invalidate(_ key: QueryKey) {
        guard entries[key] != nil else { return }
        markStale(key)
        refetchIfObserved(key)
    }

    /// Marks every key under a prefix stale, refetching those with subscribers.
    public func invalidate(prefix: QueryKey) {
        for key in entries.keys where key.hasPrefix(prefix) {
            markStale(key)
            refetchIfObserved(key)
        }
    }

    /// Drops everything.
    public func removeAll() {
        for (key, entry) in entries {
            entry.task?.cancel()
            entries[key]?.value = nil
        }
        entries = entries.filter { !$0.value.subscribers.isEmpty }
        for key in entries.keys {
            publish(key)
        }
    }

    // MARK: - Mutations

    /// Runs a mutation, applying optimistic values first and rolling them back if it fails.
    ///
    /// Rollback restores the exact snapshot captured before the change rather than reversing a diff,
    /// which is the only approach that stays correct when two mutations race.
    ///
    /// - Parameters:
    ///   - optimistic: Values to apply immediately, by key.
    ///   - invalidating: Keys to invalidate once the mutation succeeds.
    ///   - perform: The work itself.
    @discardableResult
    public func mutate<Result: Sendable>(
        optimistic: [QueryKey: any Sendable] = [:],
        invalidating: [QueryKey] = [],
        perform: @Sendable () async throws -> Result
    ) async throws -> Result {
        var previous: [QueryKey: (value: (any Sendable)?, typeName: String?)] = [:]
        for (key, value) in optimistic {
            previous[key] = (entries[key]?.value, entries[key]?.valueTypeName)
            applyOptimistic(value, for: key)
        }

        do {
            let result = try await perform()
            for key in invalidating {
                invalidate(key)
            }
            return result
        } catch {
            for (key, snapshot) in previous {
                restore(snapshot.value, typeName: snapshot.typeName, for: key)
            }
            throw error
        }
    }

    /// Whether an entry is marked stale.
    ///
    /// Internal so tests can assert invalidation without a subscriber changing the behavior they are
    /// measuring.
    func staleFlagForTesting(_ key: QueryKey) -> Bool {
        entries[key]?.isStale ?? false
    }

    // MARK: - Fetching

    private func awaitFetch<Value: Sendable>(
        _ key: QueryKey,
        fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = startFetch(key, fetch: fetch)

        do {
            let value = try await task.value
            guard let typed = value as? Value else {
                throw QueryError.typeMismatch(
                    key: key.description,
                    cached: String(describing: Swift.type(of: value)),
                    requested: String(describing: Value.self)
                )
            }
            return typed
        } catch {
            throw error
        }
    }

    /// Starts a fetch, or returns the one already running for this key.
    @discardableResult
    private func startFetch<Value: Sendable>(
        _ key: QueryKey,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> Task<any Sendable, any Error> {
        if let existing = entries[key]?.task {
            return existing
        }

        entries[key, default: newEntry()].isLoading = true
        publish(key)

        let task = Task<any Sendable, any Error> { [weak self] in
            do {
                let value = try await fetch()
                await self?.finishFetch(key, value: value, typeName: String(describing: Value.self))
                return value
            } catch {
                await self?.failFetch(key, error: error)
                throw error
            }
        }

        entries[key]?.task = task
        return task
    }

    private func finishFetch(_ key: QueryKey, value: any Sendable, typeName: String) {
        guard var entry = entries[key] else { return }
        entry.value = value
        entry.valueTypeName = typeName
        entry.updatedAt = now()
        entry.error = nil
        entry.isStale = false
        entry.isLoading = false
        entry.task = nil
        entry.lastAccess = now()
        entries[key] = entry
        publish(key)
        evictIfNeeded()
    }

    private func failFetch(_ key: QueryKey, error: any Error) {
        guard var entry = entries[key] else { return }
        entry.error = error
        entry.isLoading = false
        entry.task = nil
        entries[key] = entry
        publish(key)
    }

    private func refetchIfObserved(_ key: QueryKey) {
        guard let entry = entries[key], !entry.subscribers.isEmpty, let refetch = entry.refetch else { return }
        guard entries[key]?.task == nil else { return }

        entries[key]?.isLoading = true
        publish(key)

        let task = Task<any Sendable, any Error> { [weak self] in
            do {
                let value = try await refetch()
                await self?.finishFetch(key, value: value, typeName: String(describing: Swift.type(of: value)))
                return value
            } catch {
                await self?.failFetch(key, error: error)
                throw error
            }
        }
        entries[key]?.task = task
    }

    // MARK: - Entry maintenance

    private func newEntry() -> Entry {
        Entry(lastAccess: now())
    }

    private func touch(_ key: QueryKey) {
        entries[key, default: newEntry()].lastAccess = now()
    }

    private func isFresh(_ key: QueryKey, within staleTime: TimeInterval) -> Bool {
        guard let entry = entries[key], entry.value != nil, !entry.isStale, let updatedAt = entry.updatedAt else {
            return false
        }
        return now().timeIntervalSince(updatedAt) < staleTime
    }

    private func markStale(_ key: QueryKey) {
        entries[key]?.isStale = true
        publish(key)
    }

    private func applyOptimistic(_ value: any Sendable, for key: QueryKey) {
        var entry = entries[key] ?? newEntry()
        entry.value = value
        entry.valueTypeName = String(describing: Swift.type(of: value))
        entry.updatedAt = now()
        entry.error = nil
        entries[key] = entry
        publish(key)
    }

    private func restore(_ value: (any Sendable)?, typeName: String?, for key: QueryKey) {
        guard var entry = entries[key] else { return }
        entry.value = value
        entry.valueTypeName = typeName
        entry.updatedAt = value == nil ? nil : entry.updatedAt
        entries[key] = entry
        publish(key)
    }

    private func removeSubscriber(_ id: UUID, from key: QueryKey) {
        entries[key]?.subscribers.removeValue(forKey: id)
    }

    private func snapshot(for key: QueryKey) -> Snapshot {
        let entry = entries[key]
        return Snapshot(
            value: entry?.value,
            error: entry?.error,
            isStale: entry?.isStale ?? false,
            isLoading: entry?.isLoading ?? false
        )
    }

    private func publish(_ key: QueryKey) {
        let current = snapshot(for: key)
        for publish in entries[key]?.subscribers.values ?? [:].values {
            publish(current)
        }
    }

    /// Turns the erased snapshot into the state a subscriber asked for.
    private static func state<Value: Sendable>(from snapshot: Snapshot, as type: Value.Type) -> QueryState<Value> {
        let value = snapshot.value as? Value

        if let error = snapshot.error {
            return .failure(error, previous: value)
        }
        if snapshot.isLoading {
            return .loading(previous: value)
        }
        guard let value else {
            return .idle
        }
        return .success(value, isStale: snapshot.isStale)
    }

    /// Evicts the least recently used entry nobody is watching, until the cache fits.
    private func evictIfNeeded() {
        guard entries.count > configuration.capacity else { return }

        let evictable = entries
            .filter { $0.value.subscribers.isEmpty && $0.value.task == nil }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }

        var remaining = entries.count - configuration.capacity
        for (key, _) in evictable where remaining > 0 {
            entries.removeValue(forKey: key)
            remaining -= 1
        }
    }
}
