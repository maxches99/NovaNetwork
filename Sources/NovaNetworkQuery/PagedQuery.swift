import Foundation

/// One page of a paged query.
public struct QueryPage<Element: Sendable, Cursor: Sendable>: Sendable {
    /// The elements on this page.
    public let elements: [Element]
    /// The cursor for the next page, or `nil` when this was the last one.
    public let nextCursor: Cursor?

    /// Creates a page.
    public init(elements: [Element], nextCursor: Cursor? = nil) {
        self.elements = elements
        self.nextCursor = nextCursor
    }
}

/// A query that accumulates pages, for infinite lists.
///
/// Pages are written into the ``QueryClient`` under the query's key as they arrive, so a screen can
/// subscribe to the accumulated elements the same way it subscribes to anything else and does not
/// need to know pagination is happening.
public actor PagedQuery<Element: Sendable, Cursor: Sendable> {
    /// The key the accumulated elements are cached under.
    public let key: QueryKey

    private let client: QueryClient
    private let fetchPage: @Sendable (Cursor?) async throws -> QueryPage<Element, Cursor>
    private var accumulated: [Element] = []
    private var cursor: Cursor?
    private var reachedEnd = false
    private var isLoading = false

    /// Creates a paged query.
    ///
    /// - Parameters:
    ///   - key: Where the accumulated elements are cached.
    ///   - client: The client holding the cache.
    ///   - fetchPage: Fetches one page. Receives `nil` for the first page, then each cursor.
    public init(
        key: QueryKey,
        client: QueryClient,
        fetchPage: @escaping @Sendable (Cursor?) async throws -> QueryPage<Element, Cursor>
    ) {
        self.key = key
        self.client = client
        self.fetchPage = fetchPage
    }

    /// Everything loaded so far, in page order.
    public var elements: [Element] {
        accumulated
    }

    /// Whether another page is known to exist.
    ///
    /// True before the first page is loaded, because nobody has said otherwise yet.
    public var hasNextPage: Bool {
        !reachedEnd
    }

    /// Whether a page is currently being fetched.
    public var isFetching: Bool {
        isLoading
    }

    /// Loads the next page and appends it.
    ///
    /// Returns the accumulated elements, not just the new page, because that is what a list renders.
    /// Calling it after the last page is a no-op rather than an error: a scroll handler firing once
    /// more at the bottom is normal.
    @discardableResult
    public func loadNextPage() async throws -> [Element] {
        guard !reachedEnd, !isLoading else { return accumulated }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetchPage(cursor)
        accumulated += page.elements
        cursor = page.nextCursor
        reachedEnd = page.nextCursor == nil

        await client.setValue(accumulated, for: key)
        return accumulated
    }

    /// Discards every page and starts again from the first.
    @discardableResult
    public func reload() async throws -> [Element] {
        accumulated = []
        cursor = nil
        reachedEnd = false
        return try await loadNextPage()
    }

    /// Forgets everything without fetching.
    public func reset() async {
        accumulated = []
        cursor = nil
        reachedEnd = false
        await client.remove(key)
    }
}
