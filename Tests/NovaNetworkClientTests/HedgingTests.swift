import Foundation
import Testing
@testable import NovaNetworkClient
import NovaNetworkCore

// Requirements: FR-HEDGE-1…7, EC-HEDGE-1…4, AR-HEDGE-1…3 (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §A).
// Tests: T-18.1…T-18.10.

/// A clock whose sleeps end only when the test says so, and end early when cancelled.
private actor GateClock: RetryClock {
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var sleeps: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func fire() {
        let waiting = sleepers
        sleepers = [:]
        waiting.values.forEach { $0.resume() }
    }

    func sleeperCount() -> Int { sleepers.count }
}

/// A transport whose calls each wait until the test completes them.
private actor ParkedTransport: NetworkTransport {
    private var parked: [Int: CheckedContinuation<NetworkResponse, Error>] = [:]
    private var cancelledBeforeParking: Set<Int> = []
    private(set) var calls = 0
    private(set) var cancelled: Set<Int> = []

    nonisolated func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let index = await nextIndex()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NetworkResponse, Error>) in
                Task { await self.park(index, continuation) }
            }
        } onCancel: {
            Task { await self.cancel(index) }
        }
    }

    private func nextIndex() -> Int {
        calls += 1
        return calls
    }

    private func park(_ index: Int, _ continuation: CheckedContinuation<NetworkResponse, Error>) {
        if cancelledBeforeParking.contains(index) {
            continuation.resume(throwing: CancellationError())
        } else {
            parked[index] = continuation
        }
    }

    private func cancel(_ index: Int) {
        cancelled.insert(index)
        if let continuation = parked.removeValue(forKey: index) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeParking.insert(index)
        }
    }

    func isParked(_ index: Int) -> Bool { parked[index] != nil }

    func succeed(_ index: Int, body: String) {
        parked.removeValue(forKey: index)?.resume(
            returning: NetworkResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        )
    }

    func fail(_ index: Int, status: Int) {
        parked.removeValue(forKey: index)?.resume(
            throwing: NetworkError.httpStatus(code: status, headers: [:], body: Data())
        )
    }
}

private final class HedgeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TelemetryHedgeContext] = []

    func record(_ context: TelemetryHedgeContext) {
        lock.lock()
        recorded.append(context)
        lock.unlock()
    }

    var types: [TelemetryHedgeEventType] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.type)
    }

    var delays: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.delayMilliseconds)
    }
}

/// Polls with a short sleep until `condition` holds, failing the test after two seconds.
private func eventually(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting until \(description)", sourceLocation: sourceLocation)
}

private struct Harness {
    let transport = ParkedTransport()
    let clock = GateClock()
    let events = HedgeEvents()
    let client: NetworkClient

    init(
        hedging: HedgingPolicy? = HedgingPolicy(delay: .fixed(seconds: 0.5)),
        cancellationPolicy: CancellationPolicy = .keepRunning
    ) {
        let events = events
        client = NetworkClient(
            configuration: NetworkClientConfiguration(
                transport: transport,
                cancellationPolicy: cancellationPolicy,
                retryClock: clock,
                telemetryHooks: NetworkTelemetryHooks(onRequestHedged: { events.record($0) }),
                hedging: hedging
            )
        )
    }

    func load(_ request: APIRequest = Harness.get) -> Task<String, Error> {
        let client = client
        return Task { String(decoding: try await client.load(request: request, authScope: nil), as: UTF8.self) }
    }

    /// Starts a request and waits until its timer is running and the hedge has been sent.
    func loadAndHedge() async -> Task<String, Error> {
        let task = load()
        await eventually("the primary is parked") { await transport.isParked(1) }
        await eventually("the hedge timer is running") { await clock.sleeperCount() == 1 }
        await clock.fire()
        await eventually("the hedge is parked") { await transport.isParked(2) }
        return task
    }

    static let get = APIRequest(method: .get, url: URL(string: "https://api.example.com/items")!)
}

@Suite
struct HedgingRaceTests {
    @Test // T-18.1
    func aSlowRequestIsSentAgainAndTheFasterAnswerWins() async throws {
        let harness = Harness()
        let task = await harness.loadAndHedge()

        await harness.transport.succeed(2, body: "hedge")

        #expect(try await task.value == "hedge")
        await eventually("the primary is cancelled") { await harness.transport.cancelled.contains(1) }
        #expect(harness.events.types == [.fired, .won])
        #expect(harness.events.delays == [500, 500])
        #expect(await harness.clock.sleeps == [500_000_000])
    }

    @Test // T-18.2
    func whenThePrimaryAnswersFirstTheHedgeIsCancelledAndDoesNotCountAsAWin() async throws {
        let harness = Harness()
        let task = await harness.loadAndHedge()

        await harness.transport.succeed(1, body: "primary")

        #expect(try await task.value == "primary")
        await eventually("the hedge is cancelled") { await harness.transport.cancelled.contains(2) }
        #expect(harness.events.types == [.fired])
    }

    @Test // T-18.3
    func aFailureWaitsForTheOtherRequestAndTwoFailuresReturnThePrimarysError() async throws {
        let recovering = Harness()
        let recovered = await recovering.loadAndHedge()
        await recovering.transport.fail(2, status: 503)
        await recovering.transport.succeed(1, body: "primary")
        #expect(try await recovered.value == "primary")
        // The hedge failed, so it did not win anything.
        #expect(recovering.events.types == [.fired])

        let failing = Harness()
        let failed = await failing.loadAndHedge()
        await failing.transport.fail(2, status: 503)
        await failing.transport.fail(1, status: 500)
        await #expect {
            _ = try await failed.value
        } throws: { error in
            guard case NetworkError.httpStatus(let code, _, _) = error else { return false }
            return code == 500
        }
    }

    @Test // T-18.4
    func aRequestThatFailsBeforeTheDelayIsNotHedged() async throws {
        let harness = Harness()
        let task = harness.load()
        await eventually("the primary is parked") { await harness.transport.isParked(1) }

        await harness.transport.fail(1, status: 500)

        await #expect(throws: NetworkError.self) { _ = try await task.value }
        await eventually("the timer is cancelled") { await harness.clock.sleeperCount() == 0 }
        #expect(await harness.transport.calls == 1)
        #expect(harness.events.types.isEmpty)
    }

    @Test // T-18.6
    func aSpentBudgetSendsNothingAndSaysSo() async throws {
        let harness = Harness(hedging: HedgingPolicy(delay: .fixed(seconds: 0.5), maximumHedgeRatio: 0, burst: 0))
        let task = harness.load()
        await eventually("the primary is parked") { await harness.transport.isParked(1) }
        await eventually("the hedge timer is running") { await harness.clock.sleeperCount() == 1 }

        await harness.clock.fire()
        await eventually("the refusal is reported") { harness.events.types == [.budgetExhausted] }
        await harness.transport.succeed(1, body: "primary")

        #expect(try await task.value == "primary")
        #expect(await harness.transport.calls == 1)
    }

    @Test // T-18.8
    func cancellingTheCallerCancelsBothRequests() async throws {
        // Under `.keepRunning` the coalescer finishes the work for later callers on purpose; the
        // hedge follows whatever the work does.
        let harness = Harness(cancellationPolicy: .cancelWhenNoWaiters)
        let task = await harness.loadAndHedge()

        task.cancel()

        await #expect(throws: (any Error).self) { _ = try await task.value }
        await eventually("both are cancelled") { await harness.transport.cancelled == [1, 2] }
    }
}

@Suite
struct HedgingEligibilityTests {
    @Test // T-18.5
    func onlyRequestsThatAreSafeToRepeatAreHedged() async throws {
        let url = URL(string: "https://api.example.com/orders")!
        let eligible = HedgingPolicy.defaultEligibility

        #expect(eligible(APIRequest(method: .get, url: url)))
        #expect(eligible(APIRequest(method: .head, url: url)))
        #expect(eligible(APIRequest(method: .options, url: url)))
        #expect(!eligible(APIRequest(method: .post, url: url)))
        #expect(!eligible(APIRequest(method: .delete, url: url)))
        #expect(eligible(APIRequest(method: .post, url: url, headers: ["idempotency-key": "k1"])))

        // A write with no key goes out once, without a timer.
        let harness = Harness()
        let task = harness.load(APIRequest(method: .post, url: url, body: Data("{}".utf8)))
        await eventually("the write is parked") { await harness.transport.isParked(1) }
        await harness.transport.succeed(1, body: "created")

        #expect(try await task.value == "created")
        #expect(await harness.clock.sleeps.isEmpty)
        #expect(await harness.transport.calls == 1)
    }

    @Test // T-18.10
    func withoutAPolicyEveryRequestIsSentOnce() async throws {
        let harness = Harness(hedging: nil)
        let task = harness.load()
        await eventually("the request is parked") { await harness.transport.isParked(1) }
        await harness.transport.succeed(1, body: "only")

        #expect(try await task.value == "only")
        #expect(await harness.clock.sleeps.isEmpty)
        #expect(harness.events.types.isEmpty)
    }
}

@Suite
struct HedgingStateTests {
    @Test // T-18.6
    func theBudgetEarnsAShareOfAHedgePerRequestAndSavesUpToTheBurst() async {
        let state = HedgingState(policy: HedgingPolicy(maximumHedgeRatio: 0.5, burst: 1))

        #expect(await state.trySpendHedge())
        #expect(await !state.trySpendHedge())

        await state.recordEligibleRequest()
        #expect(await !state.trySpendHedge())
        await state.recordEligibleRequest()
        #expect(await state.trySpendHedge())

        // Saving stops at the burst.
        for _ in 0..<10 { await state.recordEligibleRequest() }
        #expect(await state.trySpendHedge())
        #expect(await !state.trySpendHedge())
    }

    @Test // T-18.7
    func theDelayIsAPercentileOfRecentLatenciesToTheSameHost() async {
        let state = HedgingState(
            policy: HedgingPolicy(delay: .percentile(0.9, minimumSamples: 3, fallbackSeconds: 1, floorSeconds: 0.05))
        )

        #expect(await state.delaySeconds(host: "a") == 1)
        for tenth in 1...10 {
            await state.recordLatency(seconds: Double(tenth) / 10, host: "a")
        }
        #expect(await state.delaySeconds(host: "a") == 0.9)
        // Another host has its own history.
        #expect(await state.delaySeconds(host: "b") == 1)

        for _ in 0..<5 { await state.recordLatency(seconds: 0.001, host: "fast") }
        #expect(await state.delaySeconds(host: "fast") == 0.05)

        // Only the most recent samples count.
        for _ in 0..<HedgingState.samplesPerHost { await state.recordLatency(seconds: 0.2, host: "a") }
        #expect(await state.delaySeconds(host: "a") == 0.2)

        let fixed = HedgingState(policy: HedgingPolicy(delay: .fixed(seconds: 0.3)))
        #expect(await fixed.delaySeconds(host: "a") == 0.3)
    }

    @Test // T-18.9
    func nonsensicalValuesAreClamped() {
        let policy = HedgingPolicy(
            delay: .percentile(3, minimumSamples: -1, fallbackSeconds: -2, floorSeconds: -3),
            maximumHedgeRatio: 7,
            burst: -4
        )

        #expect(policy.delay == .percentile(1, minimumSamples: 1, fallbackSeconds: 0, floorSeconds: 0))
        #expect(policy.maximumHedgeRatio == 1)
        #expect(policy.burst == 0)
        #expect(HedgingPolicy(delay: .fixed(seconds: -1)).delay == .fixed(seconds: 0))
        #expect(HedgingPolicy(maximumHedgeRatio: -1).maximumHedgeRatio == 0)
    }
}
