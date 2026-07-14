import NovaNetworkCore
import Foundation

/// A cache entry containing response bytes, validators, and freshness metadata.
public struct CachedResponse: Sendable {
    /// Cached response body.
    public let body: Data
    /// Original HTTP status code.
    public let statusCode: Int
    /// Original HTTP response headers.
    public let headers: [String: String]
    /// Entity tag used for conditional revalidation.
    public let etag: String?
    /// Last-modified validator used when no entity tag is available.
    public let lastModified: String?
    /// Monotonic time at which the entry was stored.
    public let storedAtNanoseconds: UInt64
    /// Monotonic time at which the entry was most recently accessed.
    public let lastAccessedAtNanoseconds: UInt64
    /// Request header values captured for the response's `Vary` fields.
    public let varyRequestHeaders: [String: String]

    /// Creates a complete response cache entry.
    public init(
        body: Data,
        statusCode: Int,
        headers: [String: String],
        etag: String?,
        lastModified: String? = nil,
        storedAtNanoseconds: UInt64,
        lastAccessedAtNanoseconds: UInt64? = nil,
        varyRequestHeaders: [String: String] = [:]
    ) {
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
        self.etag = etag
        self.lastModified = lastModified
        self.storedAtNanoseconds = storedAtNanoseconds
        self.lastAccessedAtNanoseconds = lastAccessedAtNanoseconds ?? storedAtNanoseconds
        self.varyRequestHeaders = varyRequestHeaders
    }
}

/// Asynchronous storage contract used by `NetworkClient` response caching.
public protocol ResponseCache: Sendable {
    /// Returns the entry for a stable fingerprint key, if present.
    func entry(forKey key: String) async -> CachedResponse?
    /// Stores or replaces an entry for a stable fingerprint key.
    func set(_ response: CachedResponse, forKey key: String) async
    /// Removes one entry.
    func remove(key: String) async
    /// Removes every entry.
    func removeAll() async
    /// Removes entries whose keys satisfy the supplied predicate.
    func removeAll(where shouldRemove: @escaping @Sendable (String) -> Bool) async
}
