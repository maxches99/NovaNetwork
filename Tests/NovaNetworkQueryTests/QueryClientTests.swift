import Foundation
import Testing
@testable import NovaNetworkQuery

// Requirements: FR-1 (keys), FR-2 (dedup), FR-3/FR-4 (freshness and stale-while-revalidate),
// FR-5 (subscriptions), FR-6/FR-7 (invalidation and direct writes), FR-10 (capacity),
// FR-11 (errors as state). Tests: T-1.1, T-1.2, T-2.1, T-3.1, T-4.1, T-4.2, T-5.1, T-5.2, T-8.1, T-9.1.

/// A clock the test moves by hand, so staleness is decided rather than waited for.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Counts fetches and can be told to fail or to block.
actor FetchCounter {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var isGated = false

    func gateNextFetch() {
        isGated = true
    }

    func openGate() {
        isGated = false
        gate?.resume()
        gate = nil
    }

    func record() async {
        calls += 1
        if isGated {
            await withCheckedContinuation { continuation in
                if gate == nil, isGated {
                    gate = continuation
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func count() -> Int { calls }
}

struct FetchFailure: Error, Equatable {}

func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting until \(description)", sourceLocation: sourceLocation)
}

// MARK: - T-1.1 keys

@Suite
struct QueryKeyTests {
    @Test
    func keysCompareAndHashByTheirComponents() {
        #expect(QueryKey("users", 1) == QueryKey(["users", "1"]))
        #expect(QueryKey("users", 1) != QueryKey("users", 2))
        #expect(Set([QueryKey("users", 1), QueryKey(["users", "1"])]).count == 1)
    }

    @Test
    func literalsCoverTheCommonShapes() {
        let single: QueryKey = "users"
        let multiple: QueryKey = ["users", "1"]

        #expect(single.components == ["users"])
        #expect(multiple.components == ["users", "1"])
        #expect(multiple.description == "users/1")
    }

    @Test
    func aKeySitsUnderItsPrefixesAndUnderItself() {
        let key = QueryKey("users", 1, "posts")

        #expect(key.hasPrefix("users"))
        #expect(key.hasPrefix(QueryKey("users", 1)))
        #expect(key.hasPrefix(key), "invalidating an exact key must also match it")
        #expect(!key.hasPrefix(QueryKey("users", 2)))
        #expect(!QueryKey("users").hasPrefix(key), "a shorter key is not under a longer one")
    }

    @Test
    func appendingExtendsTheHierarchy() {
        #expect(QueryKey("users").appending(1) == QueryKey("users", 1))
    }
}

// MARK: - T-2.1, T-3.1 fetching

@Suite
struct QueryFetchingTests {
    @Test
    func twoScreensAskingAtOnceCauseOneFetch() async throws {
        let clock = TestClock()
        let counter = FetchCounter()
        let queries = QueryClient(now: clock.now)
        await counter.gateNextFetch()

        async let first: String = queries.value(for: "users") {
            await counter.record()
            return "ada"
        }
        async let second: String = queries.value(for: "users") {
            await counter.record()
            return "ada"
        }

        try await waitUntil("the first fetch has started") { await counter.count() >= 1 }
        await counter.openGate()
        let values = try await [first, second]

        #expect(values == ["ada", "ada"])
        #expect(await counter.count() == 1, "the second caller joined the in-flight fetch")
    }

    @Test
    func aFreshValueIsReturnedWithoutFetching() async throws {
        let clock = TestClock()
        let counter = FetchCounter()
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 30), now: clock.now)

        _ = try await queries.value(for: "users") { await counter.record(); return "ada" }
        clock.advance(10)
        let again: String = try await queries.value(for: "users") { await counter.record(); return "grace" }

        #expect(again == "ada")
        #expect(await counter.count() == 1)
    }

    @Test
    func aStaleValueIsShownImmediatelyAndRefreshedBehindIt() async throws {
        // Blanking a screen to a spinner over a value half a minute old is the behavior this layer
        // exists to remove.
        let clock = TestClock()
        let counter = FetchCounter()
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 30), now: clock.now)

        _ = try await queries.value(for: "users") { await counter.record(); return "ada" }
        clock.advance(31)

        let immediate: String = try await queries.value(for: "users") {
            await counter.record()
            return "grace"
        }
        #expect(immediate == "ada", "the caller gets the old value at once")

        try await waitUntil("the background refresh lands") {
            (try? await queries.cachedValue(for: "users", as: String.self)) == "grace"
        }
        #expect(await counter.count() == 2)
    }

    @Test
    func refetchIgnoresWhateverWasCached() async throws {
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: "users") { "ada" }

        #expect(try await queries.refetch("users") { "grace" } == "grace")
        #expect(try await queries.cachedValue(for: "users", as: String.self) == "grace")
    }

    @Test
    func prefetchFillsTheCacheWithoutBlocking() async throws {
        let queries = QueryClient(now: TestClock().now)

        await queries.prefetch("users") { "ada" }

        try await waitUntil("the prefetch lands") {
            (try? await queries.cachedValue(for: "users", as: String.self)) == "ada"
        }
    }

    @Test
    func prefetchingSomethingFreshDoesNothing() async throws {
        let counter = FetchCounter()
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 30), now: TestClock().now)
        _ = try await queries.value(for: "users") { await counter.record(); return "ada" }

        await queries.prefetch("users") { await counter.record(); return "grace" }

        #expect(await counter.count() == 1)
    }

    @Test
    func oneKeyHoldsOneValueTypeAndSaysSoWhenItDoesNot() async throws {
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: "users") { "ada" }

        await #expect(throws: QueryError.self) {
            _ = try await queries.cachedValue(for: "users", as: Int.self)
        }

        let error = QueryError.typeMismatch(key: "users", cached: "String", requested: "Int")
        #expect(error.errorDescription?.contains("one value type") == true)
    }
}

// MARK: - T-4.x subscriptions

@Suite
struct QuerySubscriptionTests {
    @Test
    func aSubscriberReceivesTheCurrentStateFirst() async throws {
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: "users") { "ada" }

        var iterator = await queries.states(for: "users", as: String.self).makeAsyncIterator()
        let first = await iterator.next()

        #expect(first?.value == "ada")
        #expect(first?.isStale == false)
    }

    @Test
    func aSubscriberSeesLaterChanges() async throws {
        let queries = QueryClient(now: TestClock().now)
        let states = await queries.states(for: "users", as: String.self)

        let collected = Task { () -> [String?] in
            var seen: [String?] = []
            for await state in states {
                seen.append(state.value)
                if seen.count == 2 { break }
            }
            return seen
        }

        try await waitUntil("the subscriber is registered") { await queries.subscriberCount(for: "users") == 1 }
        await queries.setValue("ada", for: "users")

        #expect(await collected.value == [nil, "ada"])
    }

    @Test
    func anIdleKeyReportsIdleRatherThanPretendingToLoad() async throws {
        let queries = QueryClient(now: TestClock().now)

        var iterator = await queries.states(for: "nothing", as: String.self).makeAsyncIterator()
        let state = await iterator.next()

        #expect(state?.value == nil)
        #expect(state?.isLoading == false)
    }

    @Test
    func oneSubscriberGoingAwayLeavesTheOthersAlone() async throws {
        let queries = QueryClient(now: TestClock().now)

        let leaving = Task {
            for await _ in await queries.states(for: "users", as: String.self) { break }
        }
        _ = await leaving.value

        let staying = Task { () -> String? in
            for await state in await queries.states(for: "users", as: String.self) where state.value != nil {
                return state.value
            }
            return nil
        }

        try await waitUntil("the remaining subscriber is registered") {
            await queries.subscriberCount(for: "users") >= 1
        }
        await queries.setValue("ada", for: "users")

        #expect(await staying.value == "ada")
    }
}

// MARK: - T-5.x invalidation and writes

@Suite
struct QueryInvalidationTests {
    @Test
    func invalidatingAWatchedKeyRefetchesIt() async throws {
        let counter = FetchCounter()
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: "users") { await counter.record(); return "ada" }

        // The subscriber has to stay subscribed: invalidation only refetches keys someone is
        // watching, so a task that breaks on the first state would be measuring the wrong thing.
        let watching = Task {
            for await _ in await queries.states(for: "users", as: String.self) {}
        }
        try await waitUntil("subscribed") { await queries.subscriberCount(for: "users") == 1 }

        await queries.invalidate("users")

        try await waitUntil("the refetch ran") { await counter.count() == 2 }
        watching.cancel()
    }

    @Test
    func invalidatingAKeyNobodyWatchesMarksItWithoutSpendingTheBattery() async throws {
        let counter = FetchCounter()
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: "users") { await counter.record(); return "ada" }

        await queries.invalidate("users")

        #expect(await counter.count() == 1, "refetching data no screen is showing wastes the user's battery")
        // The next read sees it as stale and refreshes.
        _ = try await queries.value(for: "users") { await counter.record(); return "grace" }
        try await waitUntil("the read triggered a refresh") { await counter.count() == 2 }
    }

    @Test
    func aPrefixInvalidatesTheWholeFamily() async throws {
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: QueryKey("users", 1)) { "ada" }
        _ = try await queries.value(for: QueryKey("users", 2)) { "grace" }
        _ = try await queries.value(for: "posts") { "post" }

        await queries.invalidate(prefix: "users")

        #expect(await queries.isStaleForTesting(QueryKey("users", 1)))
        #expect(await queries.isStaleForTesting(QueryKey("users", 2)))
        #expect(await queries.isStaleForTesting("posts") == false)
    }

    @Test
    func writingAValueDirectlyPublishesItToSubscribers() async throws {
        let queries = QueryClient(now: TestClock().now)

        let observed = Task { () -> String? in
            for await state in await queries.states(for: "users", as: String.self) where state.value != nil {
                return state.value
            }
            return nil
        }
        try await waitUntil("subscribed") { await queries.subscriberCount(for: "users") == 1 }

        await queries.setValue("ada", for: "users")

        #expect(await observed.value == "ada")
        #expect(try await queries.cachedValue(for: "users", as: String.self) == "ada")
    }

    @Test
    func removingAValueEmptiesTheEntry() async throws {
        let queries = QueryClient(now: TestClock().now)
        await queries.setValue("ada", for: "users")

        await queries.remove("users")

        #expect(try await queries.cachedValue(for: "users", as: String.self) == nil)
    }
}

// MARK: - T-8.1, T-9.1 capacity and errors

@Suite
struct QueryCacheBehaviorTests {
    @Test
    func theCacheIsBoundedAndEvictsWhatNobodyIsWatching() async throws {
        let clock = TestClock()
        let queries = QueryClient(configuration: QueryConfiguration(capacity: 2), now: clock.now)

        for index in 0..<4 {
            _ = try await queries.value(for: QueryKey("item", index)) { "value-\(index)" }
            clock.advance(1)
        }

        #expect(try await queries.cachedValue(for: QueryKey("item", 0), as: String.self) == nil)
        #expect(try await queries.cachedValue(for: QueryKey("item", 3), as: String.self) == "value-3")
    }

    @Test
    func aWatchedEntryIsNotEvictedOutFromUnderItsScreen() async throws {
        let clock = TestClock()
        let queries = QueryClient(configuration: QueryConfiguration(capacity: 1), now: clock.now)
        _ = try await queries.value(for: "watched") { "kept" }

        let watching = Task {
            for await state in await queries.states(for: "watched", as: String.self) where state.value == nil {
                break
            }
        }
        try await waitUntil("subscribed") { await queries.subscriberCount(for: "watched") == 1 }

        for index in 0..<3 {
            clock.advance(1)
            _ = try await queries.value(for: QueryKey("other", index)) { "value" }
        }

        #expect(try await queries.cachedValue(for: "watched", as: String.self) == "kept")
        watching.cancel()
    }

    @Test
    func aFailureKeepsTheValueTheScreenAlreadyHad() async throws {
        let clock = TestClock()
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 30), now: clock.now)
        _ = try await queries.value(for: "users") { "ada" }
        clock.advance(31)

        _ = try await queries.value(for: "users") { () throws -> String in throw FetchFailure() }

        try await waitUntil("the failed refresh is reflected") {
            var iterator = await queries.states(for: "users", as: String.self).makeAsyncIterator()
            return await iterator.next()?.error != nil
        }

        var iterator = await queries.states(for: "users", as: String.self).makeAsyncIterator()
        let state = await iterator.next()
        #expect(state?.error is FetchFailure)
        #expect(state?.value == "ada", "a failed refresh must not blank a working screen")
    }

    @Test
    func aFirstFetchThatFailsThrowsToTheCaller() async {
        let queries = QueryClient(now: TestClock().now)

        await #expect(throws: FetchFailure.self) {
            _ = try await queries.value(for: "users") { () throws -> String in throw FetchFailure() }
        }
    }

    @Test
    func removingEverythingClearsTheCache() async throws {
        let queries = QueryClient(now: TestClock().now)
        await queries.setValue("ada", for: "users")
        await queries.setValue("post", for: "posts")

        await queries.removeAll()

        #expect(try await queries.cachedValue(for: "users", as: String.self) == nil)
        #expect(try await queries.cachedValue(for: "posts", as: String.self) == nil)
    }
}

extension QueryClient {
    /// Whether an entry is marked stale. Test-only reach into the cache's bookkeeping.
    func isStaleForTesting(_ key: QueryKey) -> Bool {
        staleFlagForTesting(key)
    }
}
