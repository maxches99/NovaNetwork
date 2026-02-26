import Foundation
import Testing
@testable import RequestCoalescer

@Suite
struct CacheCoverageTests {
    @Test
    func memoryCacheEvictsAndRemovesByPredicate() async {
        let cache = MemoryResponseCache(maxEntries: 0)
        let first = CachedResponse(
            body: Data("1".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 1
        )
        let second = CachedResponse(
            body: Data("2".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 2
        )

        await cache.set(first, forKey: "first")
        await cache.set(second, forKey: "second")

        #expect(await cache.entry(forKey: "first") == nil)
        #expect(await cache.entry(forKey: "second") != nil)

        await cache.removeAll(where: { $0.hasPrefix("sec") })
        #expect(await cache.entry(forKey: "second") == nil)
    }

    @Test
    func diskCacheRemoveAndPredicateRemoval() async {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-Coverage-\(UUID().uuidString)")
        let cache = DiskResponseCache(directoryURL: baseURL)
        let entry = CachedResponse(
            body: Data("disk".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 1
        )

        await cache.set(entry, forKey: "keep")
        await cache.set(entry, forKey: "drop")
        await cache.removeAll(where: { $0 == "drop" })
        #expect(await cache.entry(forKey: "drop") == nil)
        #expect(await cache.entry(forKey: "keep") != nil)

        await cache.remove(key: "keep")
        #expect(await cache.entry(forKey: "keep") == nil)
        await cache.removeAll()
    }

    @Test
    func diskCacheCapacityEvictsLeastRecentlyUsedEntries() async {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-LRU-\(UUID().uuidString)")
        let cache = DiskResponseCache(directoryURL: baseURL, maxBytes: 8, evictionPolicy: .leastRecentlyUsed)
        let first = CachedResponse(
            body: Data("1111".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 1
        )
        let second = CachedResponse(
            body: Data("2222".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 2
        )
        let third = CachedResponse(
            body: Data("3333".utf8),
            statusCode: 200,
            headers: [:],
            etag: nil,
            storedAtNanoseconds: 3
        )

        await cache.set(first, forKey: "first")
        await cache.set(second, forKey: "second")
        _ = await cache.entry(forKey: "second")
        await cache.set(third, forKey: "third")

        #expect(await cache.entry(forKey: "first") == nil)
        #expect(await cache.entry(forKey: "second") != nil)
        #expect(await cache.entry(forKey: "third") != nil)
    }
}
