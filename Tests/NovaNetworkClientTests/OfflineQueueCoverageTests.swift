import Foundation
import Testing
@testable import NovaNetworkClient

@Suite
struct OfflineQueueCoverageTests {
    @Test
    func diskOfflineWriteStorePersistsAcrossRestart() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineStore-\(UUID().uuidString)")
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/items")!,
            headers: ["X-Test": "1"],
            body: Data("payload".utf8)
        )
        let now = Date(timeIntervalSince1970: 100)

        let first = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await first.enqueue(request: request, requestKey: "k1", now: now)

        let restored = DiskOfflineWriteStore(directoryURL: baseURL)
        let snapshot = await restored.snapshot(now: now)

        #expect(snapshot.count == 1)
        #expect(snapshot[0].request.method == .post)
        #expect(snapshot[0].request.url == request.url)
        #expect(snapshot[0].request.headers["X-Test"] == "1")
        #expect(snapshot[0].request.body == Data("payload".utf8))
    }

    @Test
    func diskOfflineWriteStoreSkipsMismatchedSchemaVersion() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineSchema-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/versioned")!)
        let now = Date(timeIntervalSince1970: 200)

        let writer = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 2)
        _ = try await writer.enqueue(request: request, requestKey: "k2", now: now)

        let reader = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 1)
        let snapshot = await reader.snapshot(now: now)
        #expect(snapshot.isEmpty)
    }

    @Test
    func diskOfflineWriteStoreTTLPrunesExpiredEntries() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineTTL-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/ttl")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, ttlSeconds: 2)

        _ = try await store.enqueue(
            request: request,
            requestKey: "k3",
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(await store.depth(now: Date(timeIntervalSince1970: 3)) == 0)
    }

    @Test
    func diskOfflineWriteStoreEvictsOldestWhenAtCapacity() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineCap-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/capacity")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, maxEntries: 2, overflowPolicy: .evictOldest)

        _ = try await store.enqueue(request: request, requestKey: "first", now: Date(timeIntervalSince1970: 1))
        _ = try await store.enqueue(request: request, requestKey: "second", now: Date(timeIntervalSince1970: 2))
        _ = try await store.enqueue(request: request, requestKey: "third", now: Date(timeIntervalSince1970: 3))

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 3))
        #expect(snapshot.count == 2)
        #expect(snapshot.contains(where: { $0.receipt.requestKey == "second" }))
        #expect(snapshot.contains(where: { $0.receipt.requestKey == "third" }))
    }

    @Test
    func diskOfflineWriteStoreRejectsWhenConfiguredToRejectNew() async {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineReject-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/reject")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, maxEntries: 1, overflowPolicy: .rejectNew)

        _ = try? await store.enqueue(request: request, requestKey: "first", now: Date(timeIntervalSince1970: 1))

        do {
            _ = try await store.enqueue(request: request, requestKey: "second", now: Date(timeIntervalSince1970: 2))
            Issue.record("Expected capacity error")
        } catch let error as OfflineWriteStoreError {
            #expect(error == .queueCapacityExceeded(limit: 1))
        } catch {
            Issue.record("Unexpected error")
        }
    }

    @Test
    func diskOfflineWriteStoreSkipsCorruptedEntryAndKeepsValidEntries() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineCorrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let corruptURL = baseURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: corruptURL, options: .atomic)

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/corrupt")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await store.enqueue(request: request, requestKey: "ok", now: Date(timeIntervalSince1970: 1))

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 1))
        #expect(snapshot.count == 1)
        #expect(snapshot[0].receipt.requestKey == "ok")
        #expect(FileManager.default.fileExists(atPath: corruptURL.path) == false)
    }

    @Test
    func diskOfflineWriteStoreNextBatchRespectsRetryScheduleAndOrder() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineBatch-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/batch")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let now = Date(timeIntervalSince1970: 10)

        let first = try await store.enqueue(request: request, requestKey: "first", now: now)
        let second = try await store.enqueue(request: request, requestKey: "second", now: now.addingTimeInterval(1))

        await store.markRetryWaiting(
            queueID: first.queueID,
            attempt: 1,
            reason: "network",
            nextRetryAt: now.addingTimeInterval(60),
            now: now
        )
        await store.markReplaying(queueID: second.queueID, attempt: 1, now: now)

        let beforeReady = await store.nextBatch(limit: 10, now: now.addingTimeInterval(5))
        #expect(beforeReady.isEmpty)

        await store.markSucceeded(queueID: second.queueID)
        let afterReady = await store.nextBatch(limit: 10, now: now.addingTimeInterval(120))
        #expect(afterReady.count == 1)
        #expect(afterReady[0].receipt.queueID == first.queueID)
    }
}
