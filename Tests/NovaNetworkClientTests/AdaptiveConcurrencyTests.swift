import Foundation
import Testing
@testable import NovaNetworkClient
import NovaNetworkCore

// Requirements: FR-19 (additive increase under saturation), FR-20 (multiplicative decrease on
// congestion), FR-21 (latency degradation is a congestion signal), FR-22 (FIFO admission),
// FR-23 (cancellation and queue timeout), EC-17…EC-22.
// Tests: T-11.1…T-11.16.

@Suite
struct AdaptiveConcurrencyPolicyTests {
    @Test
    func nonsensicalBoundsAreClampedRatherThanTrusted() {
        let policy = AdaptiveConcurrencyPolicy(
            minimumLimit: -5,
            maximumLimit: 2,
            initialLimit: 100,
            backoffFactor: 4,
            latencyDegradationFactor: 0.1,
            queueTimeoutSeconds: -1
        )

        #expect(policy.minimumLimit == 1)
        #expect(policy.maximumLimit == 2)
        #expect(policy.initialLimit == 2)
        #expect(policy.backoffFactor == 0.95)
        // Below 1 every response, including the fastest ever seen, would read as congestion.
        #expect(policy.latencyDegradationFactor == 1)
        #expect(policy.queueTimeoutSeconds == nil)
    }

    @Test
    func aMaximumBelowTheMinimumIsRaisedToIt() {
        let policy = AdaptiveConcurrencyPolicy(minimumLimit: 8, maximumLimit: 2, initialLimit: 4)

        #expect(policy.minimumLimit == 8)
        #expect(policy.maximumLimit == 8)
        #expect(policy.initialLimit == 8)
    }
}

@Suite
struct AdaptiveConcurrencyStateTests {
    private func state(
        initial: Int = 8,
        minimum: Int = 1,
        maximum: Int = 32,
        backoff: Double = 0.5,
        degradation: Double = 2
    ) -> AdaptiveConcurrencyState {
        AdaptiveConcurrencyState(
            policy: AdaptiveConcurrencyPolicy(
                minimumLimit: minimum,
                maximumLimit: maximum,
                initialLimit: initial,
                backoffFactor: backoff,
                latencyDegradationFactor: degradation
            )
        )
    }

    // MARK: - Increase

    @Test
    func theLimitGrowsOnlyWhenItWasTheThingInTheWay() {
        var idle = state()
        // Slots to spare: a higher limit would not have helped, so there is no evidence for one.
        #expect(idle.record(.succeeded(latencyMilliseconds: 10), wasSaturated: false) == nil)
        #expect(idle.limit == 8)

        var busy = state()
        let change = busy.record(.succeeded(latencyMilliseconds: 10), wasSaturated: true)
        #expect(change == .init(from: 8, to: 9, reason: .headroom))
        #expect(busy.limit == 9)
    }

    @Test
    func growthStopsAtTheMaximum() {
        var subject = state(initial: 3, maximum: 4)

        #expect(subject.record(.succeeded(latencyMilliseconds: 5), wasSaturated: true)?.to == 4)
        #expect(subject.record(.succeeded(latencyMilliseconds: 5), wasSaturated: true) == nil)
        #expect(subject.limit == 4)
    }

    @Test
    func growthIsAdditiveRatherThanMultiplicative() {
        var subject = state(initial: 4)
        for expected in 5...9 {
            #expect(subject.record(.succeeded(latencyMilliseconds: 20), wasSaturated: true)?.to == expected)
        }
    }

    // MARK: - Decrease

    @Test
    func congestionCutsTheLimitMultiplicatively() {
        var subject = state(initial: 16, backoff: 0.5)

        #expect(subject.record(.congested, wasSaturated: true) == .init(from: 16, to: 8, reason: .congestion))
        #expect(subject.record(.congested, wasSaturated: false) == .init(from: 8, to: 4, reason: .congestion))
        // Backing off does not depend on saturation: a refusal is a refusal.
        #expect(subject.limit == 4)
    }

    @Test
    func theLimitNeverFallsBelowTheMinimum() {
        var subject = state(initial: 2, minimum: 2, backoff: 0.5)

        #expect(subject.record(.congested, wasSaturated: true) == nil)
        #expect(subject.limit == 2)
    }

    @Test
    func aResponseSlowerThanTheBestSeenIsTreatedAsCongestion() {
        var subject = state(initial: 10, backoff: 0.5, degradation: 2)

        // Establishes the yardstick, and grows because it was saturated.
        #expect(subject.record(.succeeded(latencyMilliseconds: 100), wasSaturated: true)?.to == 11)
        // Twice the best is not yet degradation; the factor is a strict threshold.
        #expect(subject.record(.succeeded(latencyMilliseconds: 200), wasSaturated: true)?.reason == .headroom)
        // Past it, the server is telling us it is struggling before it starts refusing.
        let change = subject.record(.succeeded(latencyMilliseconds: 500), wasSaturated: true)
        #expect(change?.reason == .latency)
        #expect(change?.to == 6)
    }

    @Test
    func theBestLatencyIsTheYardstickAndOnlyEverImproves() {
        var subject = state(initial: 4)

        _ = subject.record(.succeeded(latencyMilliseconds: 300), wasSaturated: false)
        #expect(subject.bestLatencyMilliseconds == 300)

        _ = subject.record(.succeeded(latencyMilliseconds: 120), wasSaturated: false)
        #expect(subject.bestLatencyMilliseconds == 120)

        _ = subject.record(.succeeded(latencyMilliseconds: 400), wasSaturated: false)
        #expect(subject.bestLatencyMilliseconds == 120)
    }

    @Test
    func theFirstSampleCannotBeSlowRelativeToItself() {
        // Comparing against the best *including* this sample would make every first response look
        // like exactly the threshold, and a degradation factor of 1 would then cut the limit on it.
        var subject = state(initial: 8, degradation: 1)

        let change = subject.record(.succeeded(latencyMilliseconds: 900), wasSaturated: true)

        #expect(change?.reason == .headroom)
        #expect(subject.limit == 9)
    }

    // MARK: - Signals that say nothing

    @Test
    func aFailureUnrelatedToCapacityMovesNothing() {
        var subject = state(initial: 8)

        #expect(subject.record(.inconclusive, wasSaturated: true) == nil)
        #expect(subject.limit == 8)
        #expect(subject.bestLatencyMilliseconds == nil)
    }

    @Test
    func anImpossibleLatencyIsIgnoredRatherThanBelieved() {
        var subject = state(initial: 8)

        #expect(subject.record(.succeeded(latencyMilliseconds: -1), wasSaturated: true) == nil)
        #expect(subject.record(.succeeded(latencyMilliseconds: .infinity), wasSaturated: true) == nil)
        #expect(subject.record(.succeeded(latencyMilliseconds: .nan), wasSaturated: true) == nil)
        #expect(subject.limit == 8)
        #expect(subject.bestLatencyMilliseconds == nil)
    }
}

@Suite
struct AdaptiveConcurrencyLimiterTests {
    @Test
    func requestsUpToTheLimitAreAdmittedWithoutWaiting() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 3))

        let first = try await limiter.acquire()
        _ = try await limiter.acquire()
        _ = try await limiter.acquire()

        let snapshot = await limiter.snapshot()
        #expect(snapshot.inFlight == 3)
        #expect(snapshot.waiting == 0)

        await limiter.release(first, signal: .succeeded(latencyMilliseconds: 5))
        #expect(await limiter.snapshot().inFlight == 2)
    }

    @Test
    func aCallerBeyondTheLimitWaitsRatherThanBeingRefused() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 1))
        let held = try await limiter.acquire()

        let waiting = Task { try await limiter.acquire() }
        await waitUntilLimiter(limiter) { $0.waiting == 1 }

        #expect(await limiter.snapshot().inFlight == 1)
        await limiter.release(held, signal: .succeeded(latencyMilliseconds: 5))

        _ = try await waiting.value
        let snapshot = await limiter.snapshot()
        #expect(snapshot.inFlight == 1)
        #expect(snapshot.waiting == 0)
    }

    @Test
    func waitersAreAdmittedInArrivalOrder() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 1))
        let held = try await limiter.acquire()

        actor Order {
            private(set) var admitted: [Int] = []
            func record(_ value: Int) { admitted.append(value) }
        }
        let order = Order()

        // Enqueued one at a time so arrival order is a fact rather than a race.
        var tasks: [Task<Void, Error>] = []
        for index in 1...3 {
            let task = Task {
                let permit = try await limiter.acquire()
                await order.record(index)
                // `.inconclusive` keeps the limit at 1 so admissions stay one at a time. A signal
                // that grew the limit would admit two waiters at once, and they would race to
                // record -- which would be a test of the growth rule, not of arrival order.
                await limiter.release(permit, signal: .inconclusive)
            }
            tasks.append(task)
            await waitUntilLimiter(limiter) { $0.waiting == index }
        }

        await limiter.release(held, signal: .inconclusive)
        for task in tasks { try await task.value }

        #expect(await order.admitted == [1, 2, 3])
    }

    @Test
    func aCancelledWaiterStopsWaitingAndLeavesTheQueueIntact() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 1))
        let held = try await limiter.acquire()

        let cancelled = Task { try await limiter.acquire() }
        await waitUntilLimiter(limiter) { $0.waiting == 1 }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            Issue.record("a cancelled waiter must not be admitted")
        } catch is CancellationError {
            // expected
        }

        await waitUntilLimiter(limiter) { $0.waiting == 0 }
        // The slot was never taken, so releasing the holder leaves the limiter idle rather than
        // leaking a permit that nobody holds.
        await limiter.release(held, signal: .succeeded(latencyMilliseconds: 1))
        #expect(await limiter.snapshot().inFlight == 0)
    }

    @Test
    func aTaskCancelledBeforeItEverWaitsIsStillCancelled() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 1))
        let held = try await limiter.acquire()

        let task = Task {
            // Cancelling before the first suspension is the race the actor's isolation has to close.
            try await limiter.acquire()
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("a cancelled task must not be admitted")
        } catch is CancellationError {
            // expected
        }

        await limiter.release(held, signal: .succeeded(latencyMilliseconds: 1))
        #expect(await limiter.snapshot().waiting == 0)
    }

    @Test
    func aWaiterGivesUpWhenTheQueueTimeoutElapses() async throws {
        let limiter = AdaptiveConcurrencyLimiter(
            policy: AdaptiveConcurrencyPolicy(initialLimit: 1, queueTimeoutSeconds: 0.05)
        )
        let held = try await limiter.acquire()

        do {
            _ = try await limiter.acquire()
            Issue.record("the waiter should have given up")
        } catch let error as NetworkError {
            guard case .timeoutBudgetExceeded = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }

        await limiter.release(held, signal: .succeeded(latencyMilliseconds: 1))
        #expect(await limiter.snapshot().inFlight == 0)
    }

    @Test
    func aLimitThatGrowsOpensASlotOfItsOwn() async throws {
        // One release admits two waiters, which can only happen because the limit itself moved:
        // the finished request freed one slot and the growth created the other.
        let limiter = AdaptiveConcurrencyLimiter(
            policy: AdaptiveConcurrencyPolicy(minimumLimit: 1, maximumLimit: 4, initialLimit: 1)
        )
        let holder = try await limiter.acquire()

        var queued: [Task<AdaptiveConcurrencyLimiter.Permit, Error>] = []
        for index in 1...3 {
            queued.append(Task { try await limiter.acquire() })
            await waitUntilLimiter(limiter) { $0.waiting == index }
        }

        // The holder never queued, so finishing it is not evidence that the limit was in the way.
        await limiter.release(holder, signal: .succeeded(latencyMilliseconds: 5))
        let first = try await queued[0].value
        #expect(await limiter.snapshot().limit == 1)

        // This one did queue, so its success raises the limit -- and the raise admits a second
        // waiter on top of the one the freed slot took.
        await limiter.release(first, signal: .succeeded(latencyMilliseconds: 5))

        let second = try await queued[1].value
        let third = try await queued[2].value
        let snapshot = await limiter.snapshot()
        #expect(snapshot.limit == 2)
        #expect(snapshot.inFlight == 2)
        #expect(snapshot.waiting == 0)

        await limiter.release(second, signal: .succeeded(latencyMilliseconds: 5))
        await limiter.release(third, signal: .succeeded(latencyMilliseconds: 5))
    }

    @Test
    func congestionShrinksTheLimitAndIsReported() async throws {
        let changes = ChangeLog()
        let limiter = AdaptiveConcurrencyLimiter(
            policy: AdaptiveConcurrencyPolicy(minimumLimit: 1, maximumLimit: 16, initialLimit: 8, backoffFactor: 0.5),
            onChange: { change in changes.append(change) }
        )

        let permit = try await limiter.acquire()
        await limiter.release(permit, signal: .congested)

        #expect(await limiter.snapshot().limit == 4)
        #expect(changes.all().map(\.to) == [4])
        #expect(changes.all().map(\.reason) == [.congestion])
    }

    @Test
    func releasingMoreThanWasAcquiredCannotDriveTheCountNegative() async throws {
        let limiter = AdaptiveConcurrencyLimiter(policy: AdaptiveConcurrencyPolicy(initialLimit: 2))
        let permit = try await limiter.acquire()

        await limiter.release(permit, signal: .succeeded(latencyMilliseconds: 1))
        await limiter.release(permit, signal: .succeeded(latencyMilliseconds: 1))

        #expect(await limiter.snapshot().inFlight == 0)
    }
}

// MARK: - Helpers

/// Waits on observable limiter state rather than guessing with a sleep.
private func waitUntilLimiter(
    _ limiter: AdaptiveConcurrencyLimiter,
    timeoutSeconds: Double = 5,
    _ condition: @escaping @Sendable (AdaptiveConcurrencyLimiter.Snapshot) -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition(await limiter.snapshot()) { return }
        await Task.yield()
    }
    Issue.record("the limiter never reached the expected state")
}

/// A thread-safe sink for the change callback, which is `@Sendable` and non-isolated.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [AdaptiveConcurrencyState.Change] = []

    func append(_ change: AdaptiveConcurrencyState.Change) {
        lock.lock()
        defer { lock.unlock() }
        changes.append(change)
    }

    func all() -> [AdaptiveConcurrencyState.Change] {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }
}

// MARK: - Through the client

/// Counts how many requests the transport is running at once.
private actor ConcurrencyWitness {
    private(set) var peak = 0
    private var current = 0

    func begin() { current += 1; peak = max(peak, current) }
    func end() { current -= 1 }
}

private struct WitnessTransport: NetworkTransport {
    let witness: ConcurrencyWitness
    let delayNanoseconds: UInt64

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        await witness.begin()
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        await witness.end()
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
    }
}

@Suite
struct AdaptiveConcurrencyClientTests {
    private func request(_ path: String) -> APIRequest {
        APIRequest(method: .get, url: URL(string: "https://api.example.com\(path)")!)
    }

    @Test
    func theClientRunsNoMoreThanTheLimitAtOnce() async throws {
        let witness = ConcurrencyWitness()
        var configuration = NetworkClientConfiguration()
        configuration.transport = WitnessTransport(witness: witness, delayNanoseconds: 30_000_000)
        // A maximum equal to the initial limit keeps the ceiling still while the test measures it.
        configuration.adaptiveConcurrency = AdaptiveConcurrencyPolicy(
            minimumLimit: 2,
            maximumLimit: 2,
            initialLimit: 2
        )
        let client = NetworkClient(configuration: configuration)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    // Distinct paths so the coalescer does not merge them into one request.
                    _ = try? await client.load(request: self.request("/item/\(index)"), authScope: nil)
                }
            }
        }

        #expect(await witness.peak <= 2)
        #expect(await witness.peak >= 1)
    }

    @Test
    func withoutAPolicyTheClientIsNotLimited() async throws {
        let witness = ConcurrencyWitness()
        var configuration = NetworkClientConfiguration()
        configuration.transport = WitnessTransport(witness: witness, delayNanoseconds: 30_000_000)
        let client = NetworkClient(configuration: configuration)

        #expect(await client.concurrencySnapshot() == nil)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    _ = try? await client.load(request: self.request("/item/\(index)"), authScope: nil)
                }
            }
        }

        #expect(await witness.peak > 2, "an unlimited client should overlap more than a limited one")
    }

    @Test
    func coalescedCallersDoNotEachTakeASlot() async throws {
        // Six callers, one URL: the coalescer merges them into one request, so one slot is enough
        // and none of them should be waiting on the limiter.
        let witness = ConcurrencyWitness()
        var configuration = NetworkClientConfiguration()
        configuration.transport = WitnessTransport(witness: witness, delayNanoseconds: 20_000_000)
        configuration.adaptiveConcurrency = AdaptiveConcurrencyPolicy(
            minimumLimit: 1,
            maximumLimit: 1,
            initialLimit: 1
        )
        let client = NetworkClient(configuration: configuration)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? await client.load(request: self.request("/profile"), authScope: nil)
                }
            }
        }

        #expect(await witness.peak == 1)
        let snapshot = try #require(await client.concurrencySnapshot())
        #expect(snapshot.inFlight == 0)
        #expect(snapshot.waiting == 0)
    }

    @Test
    func anHTTPErrorThatIsNotPressureDoesNotShrinkTheLimit() {
        let notFound = Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 404, body: Data()))
        let tooManyRequests = Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 429, body: Data()))
        let unavailable = Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 503, body: Data()))
        let cancelled = Result<NetworkResponse, NetworkError>.failure(.cancelled)

        #expect(NetworkClient.concurrencySignal(for: notFound, latencyMilliseconds: 5) == .inconclusive)
        #expect(NetworkClient.concurrencySignal(for: tooManyRequests, latencyMilliseconds: 5) == .congested)
        #expect(NetworkClient.concurrencySignal(for: unavailable, latencyMilliseconds: 5) == .congested)
        // The caller going away says nothing about the server's capacity.
        #expect(NetworkClient.concurrencySignal(for: cancelled, latencyMilliseconds: 5) == .inconclusive)

        let success = Result<NetworkResponse, NetworkError>.success(
            NetworkResponse(statusCode: 200, headers: [:], body: Data())
        )
        #expect(NetworkClient.concurrencySignal(for: success, latencyMilliseconds: 12) == .succeeded(latencyMilliseconds: 12))
    }

    @Test
    func aTimeoutIsPressureButAMalformedResponseIsNot() {
        let timedOut = Result<NetworkResponse, NetworkError>.failure(
            .transport(underlying: URLError(.timedOut))
        )
        let badHost = Result<NetworkResponse, NetworkError>.failure(
            .transport(underlying: URLError(.cannotFindHost))
        )
        let invalid = Result<NetworkResponse, NetworkError>.failure(.invalidResponse)

        #expect(NetworkClient.concurrencySignal(for: timedOut, latencyMilliseconds: 5) == .congested)
        // A hostname that does not resolve is not the server being busy.
        #expect(NetworkClient.concurrencySignal(for: badHost, latencyMilliseconds: 5) == .inconclusive)
        #expect(NetworkClient.concurrencySignal(for: invalid, latencyMilliseconds: 5) == .inconclusive)
    }
}
