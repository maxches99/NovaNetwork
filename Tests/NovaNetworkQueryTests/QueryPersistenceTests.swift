import Foundation
import Testing
@testable import NovaNetworkQuery

// Requirements: FR-QPERSIST-1…8, EC-QPERSIST-1…4, AR-QPERSIST-1…3
// (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §B). Tests: T-19.1…T-19.10.

private struct Feed: Codable, Sendable, Equatable {
    let items: [String]
}

private final class PersistenceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [QueryPersistenceEvent] = []

    func record(_ event: QueryPersistenceEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var all: [QueryPersistenceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A store that refuses every write.
private struct BrokenStore: QueryPersistenceStore {
    struct Refused: Error {}
    func record(for key: QueryKey) async throws -> PersistedQueryRecord? { throw Refused() }
    func save(_ record: PersistedQueryRecord, for key: QueryKey) async throws { throw Refused() }
    func remove(_ key: QueryKey) async throws { throw Refused() }
    func removeAll() async throws { throw Refused() }
}

/// A store that remembers the order of operations it saw.
private actor JournalingStore: QueryPersistenceStore {
    private(set) var journal: [String] = []
    private var records: [QueryKey: PersistedQueryRecord] = [:]

    func record(for key: QueryKey) -> PersistedQueryRecord? { records[key] }

    func save(_ record: PersistedQueryRecord, for key: QueryKey) async {
        // Yield so a write that was not ordered would be overtaken by the next one.
        await Task.yield()
        records[key] = record
        journal.append("save \(String(decoding: record.payload, as: UTF8.self))")
    }

    func remove(_ key: QueryKey) {
        records.removeValue(forKey: key)
        journal.append("remove \(key)")
    }

    func removeAll() {
        records.removeAll()
        journal.append("removeAll")
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("QueryPersistenceTests-\(UUID().uuidString)")
}

@Suite
struct QueryPersistenceRestoreTests {
    @Test // T-19.1
    func aValueFetchedInOneLaunchIsOnScreenAtTheStartOfTheNext() async throws {
        let store = InMemoryQueryPersistenceStore()
        let clock = TestClock()
        let firstLaunch = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        _ = try await firstLaunch.persistedValue(for: "feed") { Feed(items: ["a"]) }
        await firstLaunch.flushPersistence()

        clock.advance(5)
        let events = PersistenceEvents()
        let secondLaunch = QueryClient(
            configuration: QueryConfiguration(staleTime: 30),
            persistence: QueryPersistence(store: store, onEvent: { events.record($0) }),
            now: clock.now
        )
        let counter = FetchCounter()
        let restored = try await secondLaunch.persistedValue(for: "feed") {
            await counter.record()
            return Feed(items: ["b"])
        }

        // Five seconds old and the stale time is thirty: fresh, so nothing is fetched.
        #expect(restored == Feed(items: ["a"]))
        #expect(await counter.calls == 0)
        #expect(events.all == [.restored(key: "feed", age: 5)])
    }

    @Test // T-19.2
    func aStaleRestoredValueIsReturnedAtOnceAndRefreshedBehindIt() async throws {
        let store = InMemoryQueryPersistenceStore()
        let clock = TestClock()
        let firstLaunch = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        _ = try await firstLaunch.persistedValue(for: "feed") { Feed(items: ["old"]) }
        await firstLaunch.flushPersistence()

        clock.advance(3_600)
        let secondLaunch = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        let immediate = try await secondLaunch.persistedValue(for: "feed") { Feed(items: ["new"]) }

        #expect(immediate == Feed(items: ["old"]))
        try await waitUntil("the refresh lands") {
            (try? await secondLaunch.cachedValue(for: "feed", as: Feed.self)) == Feed(items: ["new"])
        }
        await secondLaunch.flushPersistence()
        let third = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        #expect(try await third.persistedValue(for: "feed") { Feed(items: ["unused"]) } == Feed(items: ["new"]))
    }

    @Test // T-19.3
    func aRecordThatCannotBeTrustedIsDiscardedAndRemoved() async throws {
        let clock = TestClock()
        let payload = try JSONEncoder().encode(Feed(items: ["stored"]))
        let feedType = String(reflecting: Feed.self)
        let cases: [(PersistedQueryRecord, QueryPersistenceEvent.DiscardReason)] = [
            (.init(key: ["feed"], typeName: feedType, version: 1, savedAt: clock.now(), payload: payload), .versionMismatch),
            (.init(key: ["feed"], typeName: "Other.Type", version: 2, savedAt: clock.now(), payload: payload), .typeMismatch),
            (.init(key: ["feed"], typeName: feedType, version: 2, savedAt: clock.now().addingTimeInterval(-120), payload: payload), .expired),
            (.init(key: ["feed"], typeName: feedType, version: 2, savedAt: clock.now(), payload: Data("{".utf8)), .unreadable),
        ]

        for (record, reason) in cases {
            let store = InMemoryQueryPersistenceStore()
            await store.save(record, for: "feed")
            let events = PersistenceEvents()
            let queries = QueryClient(
                persistence: QueryPersistence(store: store, version: 2, maximumAge: 60, onEvent: { events.record($0) }),
                now: clock.now
            )

            let value = try await queries.persistedValue(for: "feed") { Feed(items: ["fetched"]) }
            await queries.flushPersistence()

            #expect(value == Feed(items: ["fetched"]), "\(reason)")
            #expect(events.all == [.discarded(key: "feed", reason: reason)], "\(reason)")
            // The discarded record is gone, and the fetched value took its place.
            let stored = await store.record(for: "feed")
            #expect(stored?.version == 2, "\(reason)")
            #expect(stored.map { try? JSONDecoder().decode(Feed.self, from: $0.payload) } == Feed(items: ["fetched"]))
        }

        let events = PersistenceEvents()
        let unreadableStore = QueryClient(
            persistence: QueryPersistence(store: BrokenStore(), onEvent: { events.record($0) }),
            now: clock.now
        )
        _ = try await unreadableStore.persistedValue(for: "feed") { Feed(items: ["fetched"]) }
        #expect(events.all.first == .discarded(key: "feed", reason: .unreadable))
    }
}

@Suite
struct QueryPersistenceWriteTests {
    @Test // T-19.4
    func setValuesAreKeptButOptimisticGuessesAreNot() async throws {
        let store = InMemoryQueryPersistenceStore()
        let clock = TestClock()
        let queries = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        _ = try await queries.persistedValue(for: "feed") { Feed(items: ["a"]) }

        await queries.setValue(Feed(items: ["set"]), for: "feed")
        // A mutation that never finishes: the process dies with the optimistic value on screen.
        let mutation = Task {
            try await queries.mutate(optimistic: ["feed": Feed(items: ["guess"])]) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await waitUntil("the guess is applied") {
            (try? await queries.cachedValue(for: "feed", as: Feed.self)) == Feed(items: ["guess"])
        }
        await queries.flushPersistence()
        mutation.cancel()

        let nextLaunch = QueryClient(persistence: QueryPersistence(store: store), now: clock.now)
        #expect(try await nextLaunch.persistedValue(for: "feed") { Feed(items: ["unused"]) } == Feed(items: ["set"]))
    }

    @Test // T-19.5
    func removingAKeyOrEverythingRemovesItFromTheStore() async throws {
        let store = InMemoryQueryPersistenceStore()
        let queries = QueryClient(persistence: QueryPersistence(store: store), now: TestClock().now)
        _ = try await queries.persistedValue(for: "feed") { Feed(items: ["a"]) }
        _ = try await queries.persistedValue(for: "profile") { Feed(items: ["me"]) }
        await queries.flushPersistence()
        #expect(await store.count == 2)

        await queries.remove("feed")
        await queries.flushPersistence()
        #expect(await store.record(for: "feed") == nil)
        #expect(await store.count == 1)

        await queries.removeAll()
        await queries.flushPersistence()
        #expect(await store.count == 0)
    }

    @Test // T-19.7
    func writesReachTheStoreInTheOrderTheyWereMade() async throws {
        let store = JournalingStore()
        let queries = QueryClient(persistence: QueryPersistence(store: store), now: TestClock().now)
        _ = try await queries.persistedValue(for: "n") { 0 }

        for value in 1...5 {
            await queries.setValue(value, for: "n")
        }
        await queries.remove("n")
        await queries.removeAll()
        await queries.flushPersistence()

        #expect(await store.journal == ["save 0", "save 1", "save 2", "save 3", "save 4", "save 5", "remove n", "removeAll"])
    }

    @Test // T-19.8
    func aStoreThatRefusesWritesDoesNotBreakTheQuery() async throws {
        let events = PersistenceEvents()
        let queries = QueryClient(
            persistence: QueryPersistence(store: BrokenStore(), onEvent: { events.record($0) }),
            now: TestClock().now
        )

        let value = try await queries.persistedValue(for: "feed") { Feed(items: ["a"]) }
        await queries.flushPersistence()

        #expect(value == Feed(items: ["a"]))
        #expect(try await queries.cachedValue(for: "feed", as: Feed.self) == Feed(items: ["a"]))
        #expect(events.all.contains(.writeFailed(key: "feed")))
    }
}

@Suite
struct QueryPersistenceBoundaryTests {
    @Test // T-19.9
    func nothingStoredMeansAnOrdinaryFetchAndMemoryAlwaysWinsOverDisk() async throws {
        let store = InMemoryQueryPersistenceStore()
        let queries = QueryClient(persistence: QueryPersistence(store: store), now: TestClock().now)
        let counter = FetchCounter()

        let first = try await queries.persistedValue(for: "feed") { await counter.record(); return Feed(items: ["a"]) }
        #expect(first == Feed(items: ["a"]))
        #expect(await counter.calls == 1)

        // Something else wrote a different value to the store; the one in memory is what counts.
        let payload = try JSONEncoder().encode(Feed(items: ["disk"]))
        await store.save(
            PersistedQueryRecord(key: ["feed"], typeName: String(reflecting: Feed.self), version: 1, savedAt: Date(), payload: payload),
            for: "feed"
        )
        let second = try await queries.persistedValue(for: "feed") { Feed(items: ["unused"]) }
        #expect(second == Feed(items: ["a"]))
    }

    @Test // T-19.10
    func withoutPersistenceNothingIsReadOrWritten() async throws {
        let queries = QueryClient(now: TestClock().now)
        let value = try await queries.persistedValue(for: "feed") { Feed(items: ["a"]) }
        await queries.setValue(Feed(items: ["b"]), for: "feed")
        await queries.removeAll()
        await queries.flushPersistence()

        #expect(value == Feed(items: ["a"]))

        // A persisting client never writes keys read through plain `value(for:)`.
        let store = InMemoryQueryPersistenceStore()
        let persisting = QueryClient(persistence: QueryPersistence(store: store), now: TestClock().now)
        _ = try await persisting.value(for: "plain") { Feed(items: ["a"]) }
        await persisting.setValue(Feed(items: ["b"]), for: "plain")
        await persisting.flushPersistence()
        #expect(await store.count == 0)
    }
}

@Suite
struct FileQueryPersistenceStoreTests {
    @Test // T-19.6
    func recordsRoundTripThroughFilesAndACollidingFileIsTreatedAsAbsent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileQueryPersistenceStore(directory: directory)
        let record = PersistedQueryRecord(key: ["users", "1"], typeName: "T", version: 1, savedAt: Date(timeIntervalSince1970: 1), payload: Data("1".utf8))

        #expect(try store.record(for: QueryKey("users", 1)) == nil)
        try store.save(record, for: QueryKey("users", 1))
        #expect(try store.record(for: QueryKey("users", 1)) == record)

        // Force a "collision": a file at this key's name that belongs to another key.
        let other = PersistedQueryRecord(key: ["other"], typeName: "T", version: 1, savedAt: Date(), payload: Data())
        try JSONEncoder().encode(other).write(to: store.fileURL(for: "victim"))
        #expect(try store.record(for: "victim") == nil)

        try store.remove(QueryKey("users", 1))
        try store.remove(QueryKey("users", 1))
        #expect(try store.record(for: QueryKey("users", 1)) == nil)

        try store.save(record, for: "a")
        try store.save(record, for: "b")
        try store.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        // The name is stable and fixed-width, and differs between keys that join to the same text.
        #expect(FileQueryPersistenceStore.fileName(for: "feed") == FileQueryPersistenceStore.fileName(for: "feed"))
        #expect(FileQueryPersistenceStore.fileName(for: "feed").count == 21)
        #expect(FileQueryPersistenceStore.fileName(for: ["a/b"]) != FileQueryPersistenceStore.fileName(for: ["a", "b"]))
    }

    @Test // T-19.6
    func aQueryClientRestoresFromFilesAcrossInstances() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()

        let first = QueryClient(persistence: QueryPersistence(store: try FileQueryPersistenceStore(directory: directory)), now: clock.now)
        _ = try await first.persistedValue(for: "feed") { Feed(items: ["from disk"]) }
        await first.flushPersistence()

        let second = QueryClient(persistence: QueryPersistence(store: try FileQueryPersistenceStore(directory: directory)), now: clock.now)
        #expect(try await second.persistedValue(for: "feed") { Feed(items: ["unused"]) } == Feed(items: ["from disk"]))

        let caches = try FileQueryPersistenceStore.inCachesDirectory(named: "QueryPersistenceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches.directory) }
        #expect(FileManager.default.fileExists(atPath: caches.directory.path))
    }
}
