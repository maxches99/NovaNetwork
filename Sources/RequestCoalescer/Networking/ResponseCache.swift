import Foundation

public struct CachedResponse: Sendable {
    public let body: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let etag: String?
    public let storedAtNanoseconds: UInt64

    public init(
        body: Data,
        statusCode: Int,
        headers: [String: String],
        etag: String?,
        storedAtNanoseconds: UInt64
    ) {
        self.body = body
        self.statusCode = statusCode
        self.headers = headers
        self.etag = etag
        self.storedAtNanoseconds = storedAtNanoseconds
    }
}

public protocol ResponseCache: Sendable {
    func entry(forKey key: String) async -> CachedResponse?
    func set(_ response: CachedResponse, forKey key: String) async
    func remove(key: String) async
    func removeAll() async
    func removeAll(where shouldRemove: @escaping @Sendable (String) -> Bool) async
}
