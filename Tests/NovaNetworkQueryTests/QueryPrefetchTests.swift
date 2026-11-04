import Foundation
import Testing
@testable import NovaNetworkQuery

// Requirements: FR-PREFETCH-1…5, EC-PREFETCH-1…4, AR-PREFETCH-1…2
// (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §F). Tests: T-23.1…T-23.6.

/// Fetches that wait until the test lets them finish, and notice when they are cancelled.
private actor Fetches {
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private(set) var started: [String] = []
    private(set) var cancelled: [String] = []
    private var ignoresCancellation = false

    func ignoreCancellation() { ignoresCancellation = true }

    func run(_ name: String) async throws -> String {
        started.append(name)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting[name] = continuation
            }
        } onCancel: {
            Task { await self.cancel(name) }
        }
        return name
    }

    private func cancel(_ name: String) {
        cancelled.append(name)
        guard !ignoresCancellation else { return }
        waiting.removeValue(forKey: name)?.resume(throwing: CancellationError())
    }

    func finish(_ name: String) {
        waiting.removeValue(forKey: name)?.resume()
    }

    func fail(_ name: String) {
        waiting.removeValue(forKey: name)?.resume(throwing: FetchFailure())
    }

    func isWaiting(_ name: String) -> Bool { waiting[name] != nil }
}

/// Collects prefetch events from the moment it is created.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [QueryPrefetchEvent] = []
    private var task: Task<Void, Never>?

    init(_ queries: QueryClient) async {
        let stream = await queries.prefetchEvents()
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    private func append(_ event: QueryPrefetchEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var all: [QueryPrefetchEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func client(maximumConcurrent: Int = 4, clock: TestClock = TestClock()) -> QueryClient {
    var configuration = QueryConfiguration()
    configuration.maximumConcurrentPrefetches = maximumConcurrent
    return QueryClient(configuration: configuration, now: clock.now)
}

@Suite
struct QueryPrefetchTests {
    @Test // T-23.1
    func aRowComingIntoViewIsFetchedOnceAndAFreshOneNotAtAll() async throws {
        let queries = client()
        let fetches = Fetches()
        let log = await EventLog(queries)

        await queries.prefetchWhileVisible("row/1") { try await fetches.run("row/1") }
        await queries.prefetchWhileVisible("row/1") { try await fetches.run("row/1") }
        try await waitUntil("the fetch is running") { await fetches.isWaiting("row/1") }
        await fetches.finish("row/1")
        try await waitUntil("the value lands") { (try? await queries.cachedValue(for: "row/1", as: String.self)) == "row/1" }

        await queries.prefetchWhileVisible("row/1") { try await fetches.run("again") }

        #expect(await fetches.started == ["row/1"])
        try await waitUntil("events arrive") { log.all.count == 4 }
        #expect(log.all == [.queued("row/1"), .started("row/1"), .completed("row/1"), .skippedFresh("row/1")])
    }

    @Test // T-23.2
    func onlyTheLimitRunsAtOnceAndTheMostRecentRowGoesNext() async throws {
        let queries = client(maximumConcurrent: 2)
        let fetches = Fetches()

        for row in 1...5 {
            await queries.prefetchWhileVisible(QueryKey("row", row)) { try await fetches.run("row/\(row)") }
        }
        try await waitUntil("two are running") { await fetches.started.count == 2 }
        // The two run concurrently, so which one reaches its fetch first is not defined.
        #expect(Set(await fetches.started) == ["row/1", "row/2"])
        #expect(await queries.prefetchCounts() == (2, 3))

        await fetches.finish("row/1")
        try await waitUntil("the next starts") { await fetches.started.count == 3 }
        #expect(await fetches.started.last == "row/5")

        let one = client(maximumConcurrent: 0)
        for row in 1...3 {
            await one.prefetchWhileVisible(QueryKey("row", row)) { try await fetches.run("one/\(row)") }
        }
        #expect(await one.prefetchCounts() == (1, 2))
    }

    @Test // T-23.3
    func aRowThatLeavesTheScreenStopsBeingFetched() async throws {
        let queries = client(maximumConcurrent: 1)
        let fetches = Fetches()
        let log = await EventLog(queries)

        await queries.prefetchWhileVisible("a") { try await fetches.run("a") }
        await queries.prefetchWhileVisible("b") { try await fetches.run("b") }
        try await waitUntil("a is running") { await fetches.isWaiting("a") }

        await queries.cancelPrefetch("b")
        await queries.cancelPrefetch("a")
        try await waitUntil("a saw the cancellation") { await fetches.cancelled == ["a"] }

        #expect(await fetches.started == ["a"])
        #expect(await queries.prefetchCounts() == (0, 0))
        // The key is as it was: no value, no error, not loading.
        #expect(await queries.subscriberCount(for: "a") == 0)
        let state = await firstState(of: "a", in: queries)
        #expect(state.value == nil && state.error == nil && !state.isLoading)
        try await waitUntil("events arrive") { log.all.count == 5 }
        #expect(log.all == [.queued("a"), .started("a"), .queued("b"), .cancelled("b", wasRunning: false), .cancelled("a", wasRunning: true)])
    }

    @Test // T-23.4
    func aReadPromotesAPrefetchSoItIsNeverCancelledUnderIt() async throws {
        let queries = client(maximumConcurrent: 1)
        let fetches = Fetches()

        // Running, then read: the read waits on it, and cancelling no longer cancels it.
        await queries.prefetchWhileVisible("a") { try await fetches.run("a") }
        try await waitUntil("a is running") { await fetches.isWaiting("a") }
        let reader = Task { try await queries.value(for: "a") { try await fetches.run("a-read") } }
        try await waitUntil("the read is waiting") { await queries.prefetchCounts().running == 1 }
        try await Task.sleep(for: .milliseconds(10))
        await queries.cancelPrefetch("a")
        await fetches.finish("a")
        #expect(try await reader.value == "a")
        #expect(await fetches.cancelled.isEmpty)

        // Queued, then read: the read fetches it at once.
        await queries.prefetchWhileVisible("b") { try await fetches.run("b") }
        await queries.prefetchWhileVisible("c") { try await fetches.run("c") }
        try await waitUntil("c is queued behind b") { await queries.prefetchCounts() == (1, 1) }
        let direct = Task { try await queries.value(for: "c") { try await fetches.run("c-read") } }
        try await waitUntil("c is fetched by the read") { await fetches.isWaiting("c-read") }
        #expect(await queries.prefetchCounts() == (1, 0))
        await fetches.finish("c-read")
        #expect(try await direct.value == "c-read")

        // A subscriber also keeps a running prefetch alive.
        await fetches.finish("b")
        let subscribed = client(maximumConcurrent: 1)
        await subscribed.prefetchWhileVisible("d") { try await fetches.run("d") }
        let watcher = Task { for await _ in await subscribed.states(for: "d", as: String.self) {} }
        try await waitUntil("subscribed") { await subscribed.subscriberCount(for: "d") == 1 }
        await subscribed.cancelPrefetch("d")
        #expect(await subscribed.prefetchCounts().running == 1)
        watcher.cancel()
        await fetches.finish("d")
    }

    @Test // T-23.5
    func aCancelledPrefetchThatFinishesAnywayIsNotStored() async throws {
        let queries = client(maximumConcurrent: 1)
        let fetches = Fetches()
        await fetches.ignoreCancellation()
        let log = await EventLog(queries)

        await queries.prefetchWhileVisible("a") { try await fetches.run("a") }
        try await waitUntil("a is running") { await fetches.isWaiting("a") }
        await queries.cancelPrefetch("a")
        try await waitUntil("a saw the cancellation") { await fetches.cancelled == ["a"] }
        await fetches.finish("a")
        try await Task.sleep(for: .milliseconds(20))

        #expect(try await queries.cachedValue(for: "a", as: String.self) == nil)
        #expect(!log.all.contains(.completed("a")))
    }

    @Test // T-23.6
    func aFailedPrefetchFreesItsSlotAndCancellingNothingDoesNothing() async throws {
        let queries = client(maximumConcurrent: 1)
        let fetches = Fetches()
        let log = await EventLog(queries)

        await queries.cancelPrefetch("nothing")
        await queries.prefetchWhileVisible("a") { try await fetches.run("a") }
        await queries.prefetchWhileVisible("b") { try await fetches.run("b") }
        try await waitUntil("a is running") { await fetches.isWaiting("a") }
        await fetches.fail("a")
        try await waitUntil("b starts") { await fetches.isWaiting("b") }

        let state = await firstState(of: "a", in: queries)
        #expect(state.error is FetchFailure)
        #expect(log.all.contains(.failed("a")))

        // Removing everything frees the slots too.
        await queries.removeAll()
        #expect(await queries.prefetchCounts() == (0, 0))
        await queries.prefetchWhileVisible("c") { try await fetches.run("c") }
        try await waitUntil("c starts") { await fetches.isWaiting("c") }
        await fetches.finish("c")
    }
}

private func firstState(of key: QueryKey, in queries: QueryClient) async -> QueryState<String> {
    for await state in await queries.states(for: key, as: String.self) {
        return state
    }
    return .idle
}
