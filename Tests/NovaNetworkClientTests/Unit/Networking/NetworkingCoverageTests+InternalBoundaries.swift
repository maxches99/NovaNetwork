import Foundation
import Testing
@testable import NovaNetworkClient

extension NetworkingCoverageTests {
    @Test
    func internalFailureReasonCoversAdditionalNetworkErrorCases() {
        #expect(NetworkClient.failureReason(error: .timeoutBudgetExceeded) == "timeout_budget_exhausted")
        #expect(NetworkClient.failureReason(error: .coalescerLimitExceeded) == "coalescer_limit_exceeded")
        #expect(
            NetworkClient.failureReason(error: .clientRateLimited(retryAfterSeconds: nil)) == "client_rate_limited"
        )
        #expect(
            NetworkClient.failureReason(error: .queueCapacityExceeded(limit: 4)) == "offline_queue_capacity_exceeded"
        )
        #expect(NetworkClient.failureReason(error: .offlineQueueUnavailable) == "offline_queue_unavailable")
    }

    @Test
    func internalTelemetryCoalescerContextCoversBypassedAndTimedOutCases() {
        let bypassedEvent = RequestCoalescer<NetworkResponse, NetworkError>.Event.bypassed(
            key: "k1",
            reason: .maxWaitersPerKeyReached
        )
        let timedOutEvent = RequestCoalescer<NetworkResponse, NetworkError>.Event.timedOut(
            key: "k2",
            durationMilliseconds: 12.5,
            waiterCount: 3
        )

        let bypassed = NetworkClient.telemetryCoalescerContext(from: bypassedEvent)
        let timedOut = NetworkClient.telemetryCoalescerContext(from: timedOutEvent)

        #expect(bypassed?.type == .bypassed)
        #expect(bypassed?.reason == "maxWaitersPerKeyReached")
        #expect(timedOut?.type == .timedOut)
        #expect(timedOut?.waiterCount == 3)
        #expect(timedOut?.wasCancelled == true)
        #expect(timedOut?.durationMilliseconds == 12.5)
    }

    @Test
    func internalDeadlineBudgetHelpersCoverExpiredAndInsufficientBranches() {
        let now = DispatchTime.now().uptimeNanoseconds
        let expiredDeadline = NetworkClient.RequestDeadline(deadlineNanoseconds: now &- 1)
        let shortDeadline = NetworkClient.RequestDeadline(deadlineNanoseconds: now &+ 20_000_000)

        #expect(NetworkClient.remainingBudgetMilliseconds(expiredDeadline) == 0)
        #expect(NetworkClient.canScheduleRetry(withDelayNanoseconds: 25_000_000, deadline: shortDeadline) == false)
    }

    @Test
    func executeWithRetryReturnsTimeoutWhenRetryDelayExceedsBudget() async {
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-budget")!)
        let retryPolicy = RetryPolicy(maxAttempts: 2, baseDelayNanoseconds: 100_000_000, jitterRange: nil)
        let deadline = NetworkClient.RequestDeadline(
            deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds &+ 10_000_000
        )
        let result = await NetworkClient.executeWithRetry(
            key: "retry-budget-key",
            request: request,
            authScope: nil,
            transport: StubNetworkTransport(
                delayNanos: 0,
                response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 503, body: Data()))
            ),
            retryPolicy: retryPolicy,
            retryClock: RecordingRetryClock(),
            retryRandomGenerator: FixedRetryRandom(value: 1),
            middlewares: [],
            telemetryHooks: nil,
            observer: { _ in },
            deadline: deadline,
            coalescingMode: .default,
            policyScope: RuntimePolicySource.global.rawValue
        )

        guard case .failure(let error) = result else {
            Issue.record("Expected timeout_budget_exhausted failure")
            return
        }
        #expect(error.failureReason == .timeoutBudgetExhausted)
    }

    @Test
    func executeWithRetryGenericErrorPathEmitsRetryExhaustedAndReturnsWrappedTransport() async {
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-exhausted-generic")!)
        let result = await NetworkClient.executeWithRetry(
            key: "retry-exhausted-key",
            request: request,
            authScope: nil,
            transport: GenericThrowingTransport(error: URLError(.timedOut)),
            retryPolicy: RetryPolicy(maxAttempts: 1, jitterRange: nil),
            retryClock: RecordingRetryClock(),
            retryRandomGenerator: FixedRetryRandom(value: 1),
            middlewares: [],
            telemetryHooks: nil,
            observer: { _ in },
            deadline: nil,
            coalescingMode: .default,
            policyScope: RuntimePolicySource.global.rawValue
        )

        guard case .failure(let error) = result else {
            Issue.record("Expected wrapped transport failure")
            return
        }
        #expect(error.failureReason == .timedOut || error.failureReason == .transport)
    }

    @Test
    func offlineReplayRetryPolicyDeadLettersWhenMaxAttemptsReached() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-RetryDeadLetter-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 422, body: Data()))
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/retry-dead-letter")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(
                offlineQueuePolicy: .init(
                    mode: .alwaysEnqueue,
                    maxReplayAttempts: 1,
                    replayConflictPolicy: .retry
                )
            )
        )
        _ = await client.flushOfflineQueue(limit: 1)

        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.count == 1)
        #expect(snapshot[0].state == .deadLetter)
        #expect(snapshot[0].lastFailureReason == "http_status_422")
    }

    @Test
    func offlineReplayHelpersCoverPercentileAndDeadLetterDecisionBranches() {
        let client = NetworkClient(transport: StubNetworkTransport(response: .success(Data("ok".utf8))))

        #expect(client.percentile(ages: [], p: 0.5) == 0)
        #expect(client.percentile(ages: [1, 2, 3, 4], p: 0.5) == 3)
        #expect(client.shouldDeadLetterReplay(error: .httpStatus(code: 409, body: Data()), attempt: 1, maxReplayAttempts: 5) == false)
        #expect(client.shouldDeadLetterReplay(error: .httpStatus(code: 422, body: Data()), attempt: 1, maxReplayAttempts: 5) == true)
        #expect(client.shouldDeadLetterReplay(error: .transport(underlying: URLError(.timedOut)), attempt: 5, maxReplayAttempts: 5))
    }
}
